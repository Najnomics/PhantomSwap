// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Context passed from PhantomSwap to PhantomHook for validating swaps.
struct SwapContext {
    bytes32 orderHash;
    address payer;
    uint256 amountIn;
    uint256 minAmountOut;
    uint16 slippageBps;
    uint64 deadline;
    bool exactInput;
}

