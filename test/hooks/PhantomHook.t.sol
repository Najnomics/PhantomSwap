// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PhantomHook} from "../../src/hooks/PhantomHook.sol";
import {SwapContext} from "../../src/types/SwapContext.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract PhantomHookHarness is PhantomHook {
    constructor(address phantomSwap_) PhantomHook(IPoolManager(address(0)), phantomSwap_) {}

    function callBeforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, data);
    }

    function callAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, data);
    }
}

contract PhantomHookTest is Test {
    PhantomHookHarness internal hook;
    address internal phantomSwap = address(this);

    function setUp() public {
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        bytes memory constructorArgs = abi.encode(phantomSwap);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PhantomHookHarness).creationCode, constructorArgs);
        hook = new PhantomHookHarness{salt: salt}(phantomSwap);
        require(address(hook) == expectedHook, "Hook address mismatch");
    }

    function testBeforeSwapStoresContext() public {
        SwapContext memory ctx = _defaultContext();
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));

        (bytes4 selector,,) = hook.callBeforeSwap(phantomSwap, key, params, hookData);
        assertEq(selector, BaseHook.beforeSwap.selector, "selector");

        PhantomHook.PendingSwap memory pending = hook.getPendingSwap(ctx.orderHash);
        assertEq(pending.amountIn, ctx.amountIn, "amountIn");
        assertEq(pending.minAmountOut, ctx.minAmountOut, "minOut");
        assertEq(pending.slippageBps, ctx.slippageBps, "slippage");
        assertTrue(pending.zeroForOne, "direction");
        assertTrue(pending.exactInput, "exact input");
        assertEq(pending.payer, ctx.payer, "payer");
        assertEq(pending.deadline, ctx.deadline, "deadline");
    }

    function testAfterSwapValidatesAndClearsState() public {
        SwapContext memory ctx = _defaultContext();
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));
        hook.callBeforeSwap(phantomSwap, key, params, hookData);

        BalanceDelta delta =
            toBalanceDelta(-int128(int256(ctx.amountIn)), int128(int256(ctx.minAmountOut + 0.05 ether)));
        (bytes4 selector, int128 deltaAdjustment) = hook.callAfterSwap(phantomSwap, key, params, delta, hookData);
        assertEq(selector, BaseHook.afterSwap.selector, "selector");
        assertEq(deltaAdjustment, 0, "delta adjustment");

        PhantomHook.PendingSwap memory pendingAfter = hook.getPendingSwap(ctx.orderHash);
        assertEq(pendingAfter.createdAt, 0, "state cleared");
    }

    function testBeforeSwapRejectsUnauthorizedSender() public {
        SwapContext memory ctx = _defaultContext();
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));

        vm.expectRevert(abi.encodeWithSelector(PhantomHook.UnauthorizedSender.selector, address(0x1234)));
        hook.callBeforeSwap(address(0x1234), key, params, hookData);
    }

    function testAfterSwapRejectsInsufficientOutput() public {
        SwapContext memory ctx = _defaultContext();
        ctx.slippageBps = 0;
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));
        hook.callBeforeSwap(phantomSwap, key, params, hookData);

        uint256 insufficient = ctx.minAmountOut - 1;
        BalanceDelta delta = toBalanceDelta(-int128(int256(ctx.amountIn)), int128(int256(insufficient)));
        vm.expectRevert(
            abi.encodeWithSelector(PhantomHook.MinOutputNotSatisfied.selector, ctx.minAmountOut, insufficient)
        );
        hook.callAfterSwap(phantomSwap, key, params, delta, hookData);
    }

    function testAfterSwapRejectsSlippageExceeded() public {
        SwapContext memory ctx = _defaultContext();
        ctx.slippageBps = 100; // 1%
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));
        hook.callBeforeSwap(phantomSwap, key, params, hookData);

        uint256 acceptable = (ctx.amountIn * (10_000 - ctx.slippageBps)) / 10_000;
        BalanceDelta delta = toBalanceDelta(-int128(int256(ctx.amountIn)), int128(int256(acceptable - 1)));
        vm.expectRevert();
        hook.callAfterSwap(phantomSwap, key, params, delta, hookData);
    }

    function testBeforeSwapRejectsExpiredDeadline() public {
        vm.warp(1 days);
        SwapContext memory ctx = _defaultContext();
        ctx.deadline = uint64(block.timestamp) - 1;
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));

        vm.expectRevert(abi.encodeWithSelector(PhantomHook.DeadlineExpired.selector, ctx.deadline));
        hook.callBeforeSwap(phantomSwap, key, params, hookData);
    }

    function testAuthorizedAdapterCanInvokeOnceGranted() public {
        address adapter = address(0xADAD);
        hook.updateAuthorizedSender(adapter, true);

        SwapContext memory ctx = _defaultContext();
        SwapParams memory params = _defaultParams(int256(ctx.amountIn), true);
        bytes memory hookData = abi.encode(ctx);
        PoolKey memory key = _poolKey(address(hook));

        (bytes4 selector,,) = hook.callBeforeSwap(adapter, key, params, hookData);
        assertEq(selector, BaseHook.beforeSwap.selector, "selector");

        hook.callAfterSwap(
            adapter,
            key,
            params,
            toBalanceDelta(-int128(int256(ctx.amountIn)), int128(int256(ctx.amountIn))),
            hookData
        );

        hook.updateAuthorizedSender(adapter, false);
        vm.expectRevert(abi.encodeWithSelector(PhantomHook.UnauthorizedSender.selector, adapter));
        hook.callBeforeSwap(adapter, key, params, hookData);
    }

    function testCannotRevokePhantomSwapAuthorization() public {
        vm.expectRevert(PhantomHook.CannotRevokePhantomSwap.selector);
        hook.updateAuthorizedSender(phantomSwap, false);
    }

    function _defaultContext() internal view returns (SwapContext memory ctx) {
        ctx = SwapContext({
            orderHash: keccak256(abi.encodePacked(block.number, address(this))),
            payer: address(0xCAFE),
            amountIn: 1 ether,
            minAmountOut: 0.95 ether,
            slippageBps: 50,
            deadline: uint64(block.timestamp + 1 hours),
            exactInput: true
        });
    }

    function _defaultParams(int256 amountSpecified, bool zeroForOne) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: -amountSpecified, sqrtPriceLimitX96: 0});
    }

    function _poolKey(address hookAddress) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0xA11CE)),
            currency1: Currency.wrap(address(0xB0B)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
    }
}
