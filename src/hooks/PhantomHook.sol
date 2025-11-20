// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {SwapContext} from "../types/SwapContext.sol";

/// @title PhantomHook
/// @notice Uniswap v4 hook enforcing PhantomSwap execution policies with encrypted swap context.
contract PhantomHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    address public immutable phantomSwap;

    error UnauthorizedSender(address sender);
    error InvalidAddress();
    error InvalidHookData();
    error DuplicateOrder(bytes32 orderHash);
    error DeadlineExpired(uint64 deadline);
    error AmountSpecifiedMismatch(uint256 expected, uint256 actual);
    error MinOutputNotSatisfied(uint256 expected, uint256 actual);
    error SlippageExceeded(uint256 amountIn, uint256 amountOut, uint16 slippageBps);
    error UnknownOrder(bytes32 orderHash);
    error CannotRevokePhantomSwap();

    event SwapScheduled(bytes32 indexed orderHash, address indexed payer, uint256 amountIn, uint256 minAmountOut);
    event SwapFinalized(bytes32 indexed orderHash, uint256 amountIn, uint256 amountOut);
    event AuthorizedSenderUpdated(address indexed sender, bool allowed);

    struct PendingSwap {
        uint256 amountIn;
        uint256 minAmountOut;
        uint16 slippageBps;
        bool zeroForOne;
        bool exactInput;
        address payer;
        uint64 deadline;
        uint64 createdAt;
    }

    mapping(bytes32 => PendingSwap) private _pendingSwaps;
    mapping(address => bool) private _authorizedSenders;

    modifier onlyPhantomSwap() {
        if (msg.sender != phantomSwap) revert UnauthorizedSender(msg.sender);
        _;
    }

    constructor(IPoolManager poolManager_, address phantomSwap_) BaseHook(poolManager_) {
        if (phantomSwap_ == address(0)) revert InvalidAddress();
        phantomSwap = phantomSwap_;
        _authorizedSenders[phantomSwap_] = true;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_authorizedSenders[sender]) revert UnauthorizedSender(sender);

        SwapContext memory ctx = _decodeContext(hookData);

        if (_pendingSwaps[ctx.orderHash].createdAt != 0) revert DuplicateOrder(ctx.orderHash);
        if (ctx.deadline != 0 && block.timestamp > ctx.deadline) revert DeadlineExpired(ctx.deadline);

        bool exactInput = params.amountSpecified < 0;
        if (ctx.exactInput != exactInput) revert AmountSpecifiedMismatch(ctx.exactInput ? 1 : 0, exactInput ? 1 : 0);

        uint256 specifiedAmount =
            exactInput ? uint256(uint256(-params.amountSpecified)) : uint256(uint256(params.amountSpecified));

        if (ctx.amountIn != 0 && exactInput && specifiedAmount != ctx.amountIn) {
            revert AmountSpecifiedMismatch(ctx.amountIn, specifiedAmount);
        }

        PendingSwap storage pending = _pendingSwaps[ctx.orderHash];
        pending.amountIn = ctx.amountIn;
        pending.minAmountOut = ctx.minAmountOut;
        pending.slippageBps = ctx.slippageBps;
        pending.zeroForOne = params.zeroForOne;
        pending.exactInput = exactInput;
        pending.payer = ctx.payer;
        pending.deadline = ctx.deadline;
        pending.createdAt = uint64(block.timestamp);

        emit SwapScheduled(ctx.orderHash, ctx.payer, ctx.amountIn, ctx.minAmountOut);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (!_authorizedSenders[sender]) revert UnauthorizedSender(sender);

        SwapContext memory ctx = _decodeContext(hookData);
        PendingSwap storage pending = _pendingSwaps[ctx.orderHash];
        if (pending.createdAt == 0) revert UnknownOrder(ctx.orderHash);

        (uint256 amountIn, uint256 amountOut) = _extractSwapDeltas(pending.zeroForOne, delta);

        if (pending.amountIn != 0 && amountIn > pending.amountIn) {
            revert AmountSpecifiedMismatch(pending.amountIn, amountIn);
        }

        uint256 minAcceptable = pending.minAmountOut;
        if (pending.amountIn != 0 && pending.slippageBps != 0) {
            uint256 slippageFloor = (pending.amountIn * (10_000 - pending.slippageBps)) / 10_000;
            if (slippageFloor > minAcceptable) {
                minAcceptable = slippageFloor;
            }
        }

        if (amountOut < minAcceptable) {
            if (pending.slippageBps != 0 && pending.amountIn != 0) {
                revert SlippageExceeded(pending.amountIn, amountOut, pending.slippageBps);
            }
            revert MinOutputNotSatisfied(minAcceptable, amountOut);
        }

        delete _pendingSwaps[ctx.orderHash];

        emit SwapFinalized(ctx.orderHash, amountIn, amountOut);
        return (BaseHook.afterSwap.selector, 0);
    }

    // Disable liquidity management via this hook for MVP.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (!_authorizedSenders[sender]) revert UnauthorizedSender(sender);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (!_authorizedSenders[sender]) revert UnauthorizedSender(sender);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function getPendingSwap(bytes32 orderHash) external view returns (PendingSwap memory) {
        return _pendingSwaps[orderHash];
    }

    function updateAuthorizedSender(address sender, bool allowed) external onlyPhantomSwap {
        if (sender == address(0)) revert InvalidAddress();
        if (sender == phantomSwap && !allowed) revert CannotRevokePhantomSwap();
        _authorizedSenders[sender] = allowed;
        emit AuthorizedSenderUpdated(sender, allowed);
    }

    function isAuthorizedSender(address sender) external view returns (bool) {
        return _authorizedSenders[sender];
    }

    function _decodeContext(bytes calldata hookData) internal pure returns (SwapContext memory ctx) {
        if (hookData.length == 0) revert InvalidHookData();
        ctx = abi.decode(hookData, (SwapContext));
    }

    function _extractSwapDeltas(bool zeroForOne, BalanceDelta delta)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOut)
    {
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();

        if (zeroForOne) {
            amountIn = _absNegative(amt0);
            amountOut = _absPositive(amt1);
        } else {
            amountIn = _absNegative(amt1);
            amountOut = _absPositive(amt0);
        }
    }

    function _absPositive(int128 value) private pure returns (uint256) {
        if (value <= 0) return 0;
        return uint256(uint128(uint256(int256(value))));
    }

    function _absNegative(int128 value) private pure returns (uint256) {
        if (value >= 0) return uint256(uint128(uint256(int256(value))));
        unchecked {
            return uint256(uint128(uint256(int256(-value))));
        }
    }
}

