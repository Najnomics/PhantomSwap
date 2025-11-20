// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FHE} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {OrderStatus, OrderParams, Order} from "../types/PhantomOrder.sol";

library OrderLib {
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(
        "Order(address owner,address tokenIn,address tokenOut,uint256 amountInHash,uint256 minAmountOutHash,uint256 slippageBpsHash,uint64 deadline,bytes32 salt,bytes32 metadataHash)"
    );

    /// @notice Derives a deterministic hash for the provided order params and owner.
    function computeOrderHash(OrderParams memory params, address owner) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                owner,
                params.tokenIn,
                params.tokenOut,
                params.amountIn.ctHash,
                params.minAmountOut.ctHash,
                params.slippageBps.ctHash,
                params.deadline,
                params.salt,
                keccak256(params.metadata)
            )
        );
    }

    /// @notice Casts `OrderParams` into storage-ready `Order`.
    function toOrder(OrderParams memory params, address owner) internal returns (Order memory order) {
        order = Order({
            owner: owner,
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            amountIn: FHE.asEuint256(params.amountIn),
            minAmountOut: FHE.asEuint256(params.minAmountOut),
            slippageBps: FHE.asEuint16(params.slippageBps),
            deadline: params.deadline,
            salt: params.salt,
            metadata: params.metadata,
            status: OrderStatus.Submitted
        });
    }
}

