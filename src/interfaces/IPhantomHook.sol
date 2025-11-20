// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPhantomHook {
    function updateAuthorizedSender(address sender, bool allowed) external;
}


