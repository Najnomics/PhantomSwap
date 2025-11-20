// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FHE, euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {IPhantomAdapter} from "../interfaces/IPhantomAdapter.sol";
import {Order} from "../types/PhantomOrder.sol";
import {ICurveStableSwap} from "../interfaces/ICurveStableSwap.sol";
import {ICurveDecryptionOracle} from "../interfaces/ICurveDecryptionOracle.sol";

contract CurveStableAdapter is IPhantomAdapter {
    using SafeERC20 for IERC20;

    error UnauthorizedCaller(address caller);
    error UnsupportedCoinIndex(uint256 index);
    error InsufficientOutput(uint256 expectedMin, uint256 actual);
    error DecryptionNotReady(bytes32 orderHash);
    error DeadlineBreached(uint64 expected, uint64 provided);

    uint256 private constant BPS_DENOMINATOR = 10_000;

    address public immutable phantomSwap;
    ICurveStableSwap public immutable pool;
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;
    int128 public immutable tokenInIndex;
    int128 public immutable tokenOutIndex;
    ICurveDecryptionOracle public immutable oracle;

    mapping(address => bool) public authorizedQuoters;

    event QuoterAuthorizationUpdated(address indexed quoter, bool allowed);

    constructor(
        address phantomSwap_,
        address oracle_,
        address pool_,
        uint8 tokenInIndex_,
        uint8 tokenOutIndex_
    ) {
        if (phantomSwap_ == address(0) || pool_ == address(0) || oracle_ == address(0)) {
            revert UnauthorizedCaller(address(0));
        }

        phantomSwap = phantomSwap_;
        pool = ICurveStableSwap(pool_);
        oracle = ICurveDecryptionOracle(oracle_);

        address tokenInAddr = pool.coins(tokenInIndex_);
        address tokenOutAddr = pool.coins(tokenOutIndex_);
        if (tokenInAddr == address(0)) revert UnsupportedCoinIndex(tokenInIndex_);
        if (tokenOutAddr == address(0)) revert UnsupportedCoinIndex(tokenOutIndex_);

        tokenIn = IERC20(tokenInAddr);
        tokenOut = IERC20(tokenOutAddr);
        tokenInIndex = int128(uint128(tokenInIndex_));
        tokenOutIndex = int128(uint128(tokenOutIndex_));
    }

    modifier onlyPhantomSwap() {
        if (msg.sender != phantomSwap) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyAuthorizedQuoter() {
        if (msg.sender != phantomSwap && !authorizedQuoters[msg.sender]) revert UnauthorizedCaller(msg.sender);
        _;
    }

    /// @notice Allows PhantomSwap to delegate quoting permissions (e.g. to the route engine).
    function setAuthorizedQuoter(address quoter, bool allowed) external onlyPhantomSwap {
        authorizedQuoters[quoter] = allowed;
        emit QuoterAuthorizationUpdated(quoter, allowed);
    }

    /// @inheritdoc IPhantomAdapter
    function requestQuote(bytes32 orderHash, Order calldata /*order*/, bytes calldata)
        external
        override
        onlyAuthorizedQuoter
        returns (Quote memory quote)
    {
        (ICurveDecryptionOracle.DecryptedOrder memory plain, bool ready) = oracle.peek(orderHash);
        if (!ready) revert DecryptionNotReady(orderHash);

        if (plain.amountIn == 0) {
            quote.routeId = keccak256(abi.encode(orderHash, address(pool)));
            quote.encryptedAmountOut = FHE.asEuint256(0);
            quote.adapterData = bytes("");
            FHE.allow(quote.encryptedAmountOut, msg.sender);
            FHE.allow(quote.encryptedAmountOut, phantomSwap);
            FHE.allowThis(quote.encryptedAmountOut);
            return quote;
        }

        uint256 dy = pool.get_dy(tokenInIndex, tokenOutIndex, plain.amountIn);

        euint256 encryptedDy = FHE.asEuint256(dy);
        FHE.allow(encryptedDy, msg.sender);
        FHE.allow(encryptedDy, phantomSwap);
        FHE.allowThis(encryptedDy);

        quote.routeId = keccak256(abi.encode(orderHash, address(pool)));
        quote.encryptedAmountOut = encryptedDy;
        quote.adapterData = abi.encode(dy);
    }

    /// @inheritdoc IPhantomAdapter
    function executeSwap(bytes32 orderHash, Order calldata order, bytes calldata)
        external
        override
        onlyPhantomSwap
        returns (ExecutionResponse memory response)
    {
        ICurveDecryptionOracle.DecryptedOrder memory plain = oracle.consume(orderHash);

        if (plain.deadline != order.deadline || plain.deadline < block.timestamp) {
            revert DeadlineBreached(order.deadline, plain.deadline);
        }

        uint256 amountInPlain = plain.amountIn;
        uint256 minAmountOutPlain = plain.minAmountOut;
        uint16 slippageBps = plain.slippageBps;

        uint256 slippageFloor = amountInPlain * (BPS_DENOMINATOR - slippageBps) / BPS_DENOMINATOR;
        uint256 minAcceptable = slippageFloor > minAmountOutPlain ? slippageFloor : minAmountOutPlain;

        tokenIn.safeTransferFrom(msg.sender, address(this), amountInPlain);
        tokenIn.safeIncreaseAllowance(address(pool), amountInPlain);

        uint256 balanceBefore = tokenOut.balanceOf(address(this));
        uint256 dy = pool.exchange(tokenInIndex, tokenOutIndex, amountInPlain, minAcceptable);
        uint256 balanceAfter = tokenOut.balanceOf(address(this));

        uint256 amountOutPlain = balanceAfter - balanceBefore;
        if (amountOutPlain < minAcceptable) revert InsufficientOutput(minAcceptable, amountOutPlain);

        tokenOut.safeTransfer(msg.sender, amountOutPlain);
        SafeERC20.forceApprove(tokenIn, address(pool), 0);

        euint256 encryptedAmountOut = FHE.asEuint256(amountOutPlain);
        FHE.allow(encryptedAmountOut, msg.sender);
        FHE.allow(encryptedAmountOut, phantomSwap);
        FHE.allowThis(encryptedAmountOut);

        response = ExecutionResponse({
            encryptedAmountOut: encryptedAmountOut,
            settlementData: bytes(""),
            telemetry: abi.encode(dy, amountOutPlain)
        });
    }
}

