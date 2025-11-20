// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
    bytes amountIn; // FHE ciphertext of amountIn produced via Fhenix SDK.
    bytes minAmountOut; // FHE ciphertext of minAmountOut.
    bytes slippageBps; // FHE ciphertext of acceptable slippage in basis points.
    uint64 deadline; // Unix timestamp after which the order is invalid.
    bytes32 salt; // Client-provided randomness to guarantee unique hashes.
    bytes metadata; // Optional opaque payload (e.g. route hints, analytics tags).
}

/// @notice Canonical representation of an encrypted order stored on-chain.
struct Order {
    address owner;
    address tokenIn;
    address tokenOut;
    bytes amountIn;
    bytes minAmountOut;
    bytes slippageBps;
    uint64 deadline;
    bytes32 salt;
    bytes metadata;
    OrderStatus status;
}

