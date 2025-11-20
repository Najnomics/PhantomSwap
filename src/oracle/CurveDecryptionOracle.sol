// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICurveDecryptionOracle} from "../interfaces/ICurveDecryptionOracle.sol";

/// @title CurveDecryptionOracle
/// @notice Stores decrypted order parameters supplied by authorized relayers.
contract CurveDecryptionOracle is Ownable, ICurveDecryptionOracle {
    error NotAuthorized(address sender);
    error OrderNotReady(bytes32 orderHash);

    event RelayerUpdated(address indexed relayer, bool allowed);
    event OrderSubmitted(bytes32 indexed orderHash);
    event OrderConsumed(bytes32 indexed orderHash);

    mapping(bytes32 => DecryptedOrder) private _orders;
    mapping(bytes32 => bool) private _ready;
    mapping(address => bool) public relayers;

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyRelayer() {
        if (!relayers[msg.sender]) revert NotAuthorized(msg.sender);
        _;
    }

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        relayers[relayer] = allowed;
        emit RelayerUpdated(relayer, allowed);
    }

    function submitDecryption(bytes32 orderHash, DecryptedOrder calldata data) external onlyRelayer {
        _orders[orderHash] = data;
        _ready[orderHash] = true;
        emit OrderSubmitted(orderHash);
    }

    function peek(bytes32 orderHash) external view override returns (DecryptedOrder memory data, bool ready) {
        data = _orders[orderHash];
        ready = _ready[orderHash];
    }

    function consume(bytes32 orderHash) external override returns (DecryptedOrder memory data) {
        if (!_ready[orderHash]) revert OrderNotReady(orderHash);

        data = _orders[orderHash];
        delete _orders[orderHash];
        delete _ready[orderHash];

        emit OrderConsumed(orderHash);
    }
}


