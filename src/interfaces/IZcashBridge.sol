// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {Order} from "../types/PhantomOrder.sol";
import {RelayParams} from "../types/ZcashTypes.sol";

interface IZcashBridge {
    struct SettlementRequest {
        bytes32 orderHash;
        euint256 encryptedAmountOut;
        bytes relayerData;
    }

    /// @notice Queues a settlement for a given order using shielded pool operations.
    function requestSettlement(Order calldata order, SettlementRequest calldata request) external;

    /// @notice Returns true if the settlement was completed (via relayer).
    function isSettled(bytes32 orderHash) external view returns (bool);

    /// @notice Called by authorized relayer to confirm shielded settlement.
    function confirmSettlement(bytes32 orderHash, bytes32 zcashTxId) external;

    event SettlementRequested(
        bytes32 indexed orderHash,
        bytes32 indexed operationId,
        address indexed relayer,
        bytes32 shieldedReceiver,
        euint256 encryptedAmount
    );

    event SettlementConfirmed(bytes32 indexed orderHash, bytes32 indexed operationId, bytes32 zcashTxId);

    event SettlementExpired(bytes32 indexed orderHash, bytes32 indexed operationId);
}

