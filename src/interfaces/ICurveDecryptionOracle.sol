// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICurveDecryptionOracle {
    struct DecryptedOrder {
        uint256 amountIn;
        uint256 minAmountOut;
        uint16 slippageBps;
        uint64 deadline;
    }

    function peek(bytes32 orderHash) external view returns (DecryptedOrder memory data, bool ready);

    function consume(bytes32 orderHash) external returns (DecryptedOrder memory data);
}


