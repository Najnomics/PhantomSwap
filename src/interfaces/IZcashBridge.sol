// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order} from "../types/PhantomOrder.sol";

interface IZcashBridge {
    struct SettlementRequest {
        bytes32 orderHash;
        bytes encryptedAmountOut;
        bytes relayerData;
    }

    /// @notice Queues a settlement for a given order using shielded pool operations.
    function requestSettlement(Order calldata order, SettlementRequest calldata request) external;

    /// @notice Returns true if the settlement was completed (via relayer).
    function isSettled(bytes32 orderHash) external view returns (bool);
}

