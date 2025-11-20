// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct RelayParams {
    address relayer;
    bytes32 shieldedReceiver;
    uint32 minConfirmations;
    uint64 expiry;
}

