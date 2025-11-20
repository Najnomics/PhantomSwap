// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PhantomSwap} from "../../src/core/PhantomSwap.sol";
import {OrderParams, OrderStatus, Order} from "../../src/types/PhantomOrder.sol";
import {IPhantomAdapter} from "../../src/interfaces/IPhantomAdapter.sol";
import {IZcashBridge} from "../../src/interfaces/IZcashBridge.sol";

contract PhantomSwapTest is BaseTest {
    PhantomSwap internal phantomSwap;
    MockAdapter internal adapter;
    MockZcashBridge internal bridge;

    address internal executor = address(0xBEEF);

    function setUp() public {
        deployArtifactsAndLabel();

        phantomSwap = new PhantomSwap(address(this));
        adapter = new MockAdapter();
        bridge = new MockZcashBridge();

        phantomSwap.setExecutor(executor, true);
        phantomSwap.setAdapter(address(adapter), true);
    }

    function testSubmitOrderStoresCiphertexts() public {
        OrderParams memory params = _defaultOrderParams();

        bytes32 orderHash = phantomSwap.submitOrder(params);

        assertEq(uint8(phantomSwap.getOrderStatus(orderHash)), uint8(OrderStatus.Submitted));

        bytes32 expectedHash = phantomSwap.computeOrderHash(params, address(this));
        assertEq(orderHash, expectedHash);
    }

    function testCancelOrderByOwner() public {
        bytes32 orderHash = phantomSwap.submitOrder(_defaultOrderParams());

        phantomSwap.cancelOrder(orderHash);

        assertEq(uint8(phantomSwap.getOrderStatus(orderHash)), uint8(OrderStatus.Cancelled));
    }

    function testExecuteOrderWithManualPlan() public {
        bytes32 orderHash = phantomSwap.submitOrder(_defaultOrderParams());

        adapter.setExecution(bytes("cipher_out"), bytes(""));

        PhantomSwap.ExecutionPlan memory plan = PhantomSwap.ExecutionPlan({
            adapter: address(adapter),
            adapterData: abi.encodePacked(bytes32("adapter-data")),
            settlementData: bytes(""),
            routeId: bytes32("route-1"),
            encryptedQuote: bytes("quote")
        });

        vm.prank(executor);
        bytes memory encryptedAmountOut = phantomSwap.executeOrder(orderHash, abi.encode(plan));

        assertEq(encryptedAmountOut, bytes("cipher_out"));
        assertEq(uint8(phantomSwap.getOrderStatus(orderHash)), uint8(OrderStatus.Executed));
        assertEq(adapter.lastOrderHash(), orderHash);
        assertEq(adapter.lastAdapterData(), plan.adapterData);
        assertEq(adapter.lastCaller(), address(phantomSwap));
    }

    function testExecuteTriggersZcashSettlement() public {
        bytes32 orderHash = phantomSwap.submitOrder(_defaultOrderParams());

        adapter.setExecution(bytes("cipher_out"), bytes("bridge-data"));
        phantomSwap.setZcashBridge(bridge);

        PhantomSwap.ExecutionPlan memory plan = PhantomSwap.ExecutionPlan({
            adapter: address(adapter),
            adapterData: bytes("adapter"),
            settlementData: bytes(""),
            routeId: bytes32("route-1"),
            encryptedQuote: bytes("quote")
        });

        vm.prank(executor);
        phantomSwap.executeOrder(orderHash, abi.encode(plan));

        assertTrue(bridge.lastCalled());
        assertEq(bridge.lastOrderHash(), orderHash);
        assertEq(bridge.lastRelayerData(), bytes("bridge-data"));
    }

    function _defaultOrderParams() internal view returns (OrderParams memory params) {
        params = OrderParams({
            tokenIn: address(0x1111),
            tokenOut: address(0x2222),
            amountIn: bytes("cipher-in"),
            minAmountOut: bytes("cipher-min"),
            slippageBps: bytes("cipher-slip"),
            deadline: uint64(block.timestamp + 1 hours),
            salt: bytes32("salt"),
            metadata: bytes("meta")
        });
    }
}

contract MockAdapter is IPhantomAdapter {
    bytes private _encryptedAmountOut;
    bytes private _settlementData;

    bytes32 private _lastOrderHash;
    bytes private _lastAdapterData;
    address private _lastCaller;

    function setExecution(bytes memory encryptedAmountOut, bytes memory settlementData) external {
        _encryptedAmountOut = encryptedAmountOut;
        _settlementData = settlementData;
    }

    function requestQuote(bytes32, Order calldata, bytes calldata) external pure returns (Quote memory) {
        revert("MockAdapter: quotes not implemented");
    }

    function executeSwap(bytes32 orderHash, Order calldata, bytes calldata adapterData)
        external
        returns (ExecutionResponse memory response)
    {
        _lastCaller = msg.sender;
        _lastOrderHash = orderHash;
        _lastAdapterData = adapterData;

        response = ExecutionResponse({
            encryptedAmountOut: _encryptedAmountOut, settlementData: _settlementData, telemetry: bytes("")
        });
    }

    function lastOrderHash() external view returns (bytes32) {
        return _lastOrderHash;
    }

    function lastAdapterData() external view returns (bytes memory) {
        return _lastAdapterData;
    }

    function lastCaller() external view returns (address) {
        return _lastCaller;
    }
}

contract MockZcashBridge is IZcashBridge {
    bool private _called;
    bytes32 private _orderHash;
    bytes private _relayerData;

    function requestSettlement(Order calldata, SettlementRequest calldata request) external override {
        _called = true;
        _orderHash = request.orderHash;
        _relayerData = request.relayerData;
    }

    function isSettled(bytes32) external pure returns (bool) {
        return false;
    }

    function lastCalled() external view returns (bool) {
        return _called;
    }

    function lastOrderHash() external view returns (bytes32) {
        return _orderHash;
    }

    function lastRelayerData() external view returns (bytes memory) {
        return _relayerData;
    }
}

