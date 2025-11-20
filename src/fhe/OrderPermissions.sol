// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FHE} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {Order} from "../types/PhantomOrder.sol";

library OrderPermissions {
    /// @notice Grants permissions required upon submission for owner and this contract.
    function grantOnSubmission(Order memory order, address owner) internal {
        FHE.allow(order.amountIn, owner);
        FHE.allow(order.minAmountOut, owner);
        FHE.allow(order.slippageBps, owner);

        FHE.allowThis(order.amountIn);
        FHE.allowThis(order.minAmountOut);
        FHE.allowThis(order.slippageBps);
    }

    /// @notice Grants temporary permissions for the executor and adapter ahead of execution.
    function grantForExecution(Order storage order, address executor, address adapter) internal {
        if (executor != address(0)) {
            FHE.allow(order.amountIn, executor);
            FHE.allow(order.minAmountOut, executor);
            FHE.allow(order.slippageBps, executor);
        }

        if (adapter != address(0)) {
            FHE.allow(order.amountIn, adapter);
            FHE.allow(order.minAmountOut, adapter);
            FHE.allow(order.slippageBps, adapter);
        }
    }
}

