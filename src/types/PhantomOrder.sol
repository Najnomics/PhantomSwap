// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InEuint256, InEuint16, euint256, euint16} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @notice Order lifecycle states within PhantomSwap.
enum OrderStatus {
    None,
    Submitted,
    Executed,
    Cancelled
}

/// @notice User supplied parameters for submitting a new encrypted order.
struct OrderParams {
    address tokenIn;
    address tokenOut;
    InEuint256 amountIn; // Ciphertext of amountIn produced via Fhenix SDK.
    InEuint256 minAmountOut; // Ciphertext of minAmountOut.
    InEuint16 slippageBps; // Ciphertext of acceptable slippage in basis points.
    uint64 deadline; // Unix timestamp after which the order is invalid.
    bytes32 salt; // Client-provided randomness to guarantee unique hashes.
    bytes metadata; // Optional opaque payload (e.g. route hints, analytics tags).
}

/// @notice Canonical representation of an encrypted order stored on-chain.
struct Order {
    address owner;
    address tokenIn;
    address tokenOut;
    euint256 amountIn;
    euint256 minAmountOut;
    euint16 slippageBps;
    uint64 deadline;
    bytes32 salt;
    bytes metadata;
    OrderStatus status;
}

