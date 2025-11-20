// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Order} from "../types/PhantomOrder.sol";
import {RelayParams} from "../types/ZcashTypes.sol";
import {IZcashBridge} from "../interfaces/IZcashBridge.sol";
import {FHE, euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title ZcashBridge
/// @notice Coordinates settlement of PhantomSwap orders into Zcash shielded pools via authorized relayers.
contract ZcashBridge is IZcashBridge, Ownable, Pausable {
    struct SettlementOperation {
        bytes32 orderHash;
        bytes32 operationId;
        euint256 encryptedAmount;
        address relayer;
        bytes32 shieldedReceiver;
        uint32 minConfirmations;
        uint64 expiry;
        uint64 requestedAt;
        bool completed;
        bytes32 zcashTxId;
    }

    mapping(bytes32 orderHash => SettlementOperation) private _operations;
    mapping(address => bool) public relayers;

    event RelayerUpdated(address indexed relayer, bool allowed);

    error UnknownOrder(bytes32 orderHash);
    error OperationAlreadyExists(bytes32 orderHash);
    error NotAuthorizedRelayer(address relayer);
    error OperationExpired(bytes32 orderHash);
    error OperationNotPending(bytes32 orderHash);
    error DeadlineTooSoon();

    uint64 public constant MIN_EXPIRY_DELAY = 5 minutes;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Registers or revokes a relayer.
    function setRelayer(address relayer, bool allowed) external onlyOwner {
        relayers[relayer] = allowed;
        emit RelayerUpdated(relayer, allowed);
    }

    /// @inheritdoc IZcashBridge
    function requestSettlement(Order calldata, SettlementRequest calldata request) external override whenNotPaused {
        if (_operations[request.orderHash].orderHash != 0) revert OperationAlreadyExists(request.orderHash);

        RelayParams memory params = _decodeRelayParams(request.relayerData);
        if (!relayers[params.relayer]) revert NotAuthorizedRelayer(params.relayer);
        if (params.expiry < block.timestamp + MIN_EXPIRY_DELAY) revert DeadlineTooSoon();

        SettlementOperation memory op;
        op.orderHash = request.orderHash;
        op.operationId = keccak256(abi.encodePacked(request.orderHash, block.number, params.relayer));
        op.encryptedAmount = request.encryptedAmountOut;
        op.relayer = params.relayer;
        op.shieldedReceiver = params.shieldedReceiver;
        op.minConfirmations = params.minConfirmations;
        op.expiry = params.expiry;
        op.requestedAt = uint64(block.timestamp);

        _operations[request.orderHash] = op;

        emit SettlementRequested(
            request.orderHash, op.operationId, params.relayer, params.shieldedReceiver, request.encryptedAmountOut
        );
    }

    /// @inheritdoc IZcashBridge
    function isSettled(bytes32 orderHash) external view override returns (bool) {
        return _operations[orderHash].completed;
    }

    /// @inheritdoc IZcashBridge
    function confirmSettlement(bytes32 orderHash, bytes32 zcashTxId) external override whenNotPaused {
        SettlementOperation storage op = _operations[orderHash];
        if (op.orderHash == 0) revert UnknownOrder(orderHash);
        if (op.completed) revert OperationNotPending(orderHash);
        if (!relayers[msg.sender] || msg.sender != op.relayer) revert NotAuthorizedRelayer(msg.sender);
        if (block.timestamp > op.expiry) revert OperationExpired(orderHash);

        op.completed = true;
        op.zcashTxId = zcashTxId;

        emit SettlementConfirmed(orderHash, op.operationId, zcashTxId);
    }

    /// @notice Allows the owner to expire a pending operation after the deadline.
    function expireSettlement(bytes32 orderHash) external onlyOwner {
        SettlementOperation storage op = _operations[orderHash];
        if (op.orderHash == 0) revert UnknownOrder(orderHash);
        if (op.completed) revert OperationNotPending(orderHash);
        if (block.timestamp <= op.expiry) revert OperationExpired(orderHash);

        delete _operations[orderHash];
        emit SettlementExpired(orderHash, op.operationId);
    }

    /// @notice Retrieves details for a settlement operation.
    function getOperation(bytes32 orderHash) external view returns (SettlementOperation memory) {
        SettlementOperation memory op = _operations[orderHash];
        if (op.orderHash == 0) revert UnknownOrder(orderHash);
        return op;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _decodeRelayParams(bytes calldata relayerData) internal pure returns (RelayParams memory params) {
        if (relayerData.length == 0) {
            revert("ZcashBridge: missing relay data");
        }
        params = abi.decode(relayerData, (RelayParams));
    }
}

