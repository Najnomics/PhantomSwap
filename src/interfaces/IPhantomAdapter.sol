// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {Order} from "../types/PhantomOrder.sol";

interface IPhantomAdapter {
    struct Quote {
        bytes32 routeId;
        euint256 encryptedAmountOut;
        bytes adapterData;
    }

    struct ExecutionResponse {
        euint256 encryptedAmountOut;
        bytes settlementData;
        bytes telemetry; // optional analytics payload.
    }

    /// @notice Returns an encrypted quote for the provided order.
    /// @dev Implementations MUST follow Fhenix CoFHE patterns (no plaintext leakage).
    function requestQuote(bytes32 orderHash, Order calldata order, bytes calldata extraData)
        external
        returns (Quote memory);

    /// @notice Executes the swap for the provided order using adapter-specific logic.
    /// @param orderHash Hash of the associated order.
    /// @param order Order data (ciphertexts, metadata) copied to memory.
    /// @param adapterData Adapter-specific execution payload (e.g., pool keys, proof blobs).
    /// @return response Adapter execution result including encrypted settlement data.
    function executeSwap(bytes32 orderHash, Order calldata order, bytes calldata adapterData)
        external
        returns (ExecutionResponse memory response);
}

