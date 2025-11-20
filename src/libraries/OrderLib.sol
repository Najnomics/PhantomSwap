// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderStatus, OrderParams, Order} from "../types/PhantomOrder.sol";

library OrderLib {
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(
        "Order(address owner,address tokenIn,address tokenOut,bytes32 amountInHash,bytes32 minAmountOutHash,bytes32 slippageBpsHash,uint64 deadline,bytes32 salt,bytes32 metadataHash)"
    );

    /// @notice Derives a deterministic hash for the provided order params and owner.
    function computeOrderHash(OrderParams memory params, address owner) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                owner,
                params.tokenIn,
                params.tokenOut,
                keccak256(params.amountIn),
                keccak256(params.minAmountOut),
                keccak256(params.slippageBps),
                params.deadline,
                params.salt,
                keccak256(params.metadata)
            )
        );
    }

    /// @notice Casts `OrderParams` into storage-ready `Order`.
    function toOrder(OrderParams memory params, address owner) internal pure returns (Order memory order) {
        order = Order({
            owner: owner,
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            amountIn: params.amountIn,
            minAmountOut: params.minAmountOut,
            slippageBps: params.slippageBps,
            deadline: params.deadline,
            salt: params.salt,
            metadata: params.metadata,
            status: OrderStatus.Submitted
        });
    }
}

