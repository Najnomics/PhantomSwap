// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order} from "../types/PhantomOrder.sol";
import {IPhantomAdapter} from "./IPhantomAdapter.sol";

interface IRouteEngine {
    struct RouteSelection {
        address adapter;
        IPhantomAdapter.Quote quote;
        bytes adapterData;
        bytes settlementData;
    }

    /// @notice Performs CoFHE-based route selection and returns the winning adapter details.
    /// @param orderHash Hash identifying the order.
    /// @param order Order metadata and ciphertexts.
    /// @param extraData Optional payload (e.g., registered adapters, FHE circuit hints).
    /// @return selection FHE evaluated winning route (adapter + encrypted quote).
    function selectBestRoute(bytes32 orderHash, Order calldata order, bytes calldata extraData)
        external
        returns (RouteSelection memory selection);
}

