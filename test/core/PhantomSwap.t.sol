// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";
import {FHE, InEuint256, InEuint16, euint256, euint16} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {PhantomSwap} from "../../src/core/PhantomSwap.sol";
import {RouteEngine} from "../../src/fhe/RouteEngine.sol";
import {OrderParams, OrderStatus, Order} from "../../src/types/PhantomOrder.sol";
import {IPhantomAdapter} from "../../src/interfaces/IPhantomAdapter.sol";
import {IZcashBridge} from "../../src/interfaces/IZcashBridge.sol";

contract PhantomSwapTest is BaseTest, CoFheTest {
    PhantomSwap internal phantomSwap;
    MockAdapter internal adapter;
    MockZcashBridge internal bridge;

    address internal executor = address(0xBEEF);

    function setUp() public {
        deployArtifactsAndLabel();

        vm.prank(TM_ADMIN);
        taskManager.setVerifierSigner(address(0));

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

        adapter.setExecution(_adapterCipher(adapter, 123 ether), bytes(""));

        PhantomSwap.ExecutionPlan memory plan = PhantomSwap.ExecutionPlan({
            adapter: address(adapter),
            adapterData: abi.encodePacked(bytes32("adapter-data")),
            settlementData: bytes(""),
            routeId: bytes32("route-1"),
            encryptedQuote: _asCipher(456 ether)
        });

        vm.prank(executor);
        euint256 encryptedAmountOut = phantomSwap.executeOrder(orderHash, abi.encode(plan));

        assertEq(
            euint256.unwrap(encryptedAmountOut),
            euint256.unwrap(adapter.configuredAmountOut()),
            "encrypted amount mismatch"
        );
        assertEq(uint8(phantomSwap.getOrderStatus(orderHash)), uint8(OrderStatus.Executed));
        assertEq(adapter.lastOrderHash(), orderHash);
        assertEq(adapter.lastAdapterData(), plan.adapterData);
        assertEq(adapter.lastCaller(), address(phantomSwap));
    }

    function testExecuteTriggersZcashSettlement() public {
        bytes32 orderHash = phantomSwap.submitOrder(_defaultOrderParams());

        adapter.setExecution(_adapterCipher(adapter, 321 ether), bytes("bridge-data"));
        phantomSwap.setZcashBridge(bridge);

        PhantomSwap.ExecutionPlan memory plan = PhantomSwap.ExecutionPlan({
            adapter: address(adapter),
            adapterData: bytes("adapter"),
            settlementData: bytes(""),
            routeId: bytes32("route-1"),
            encryptedQuote: _asCipher(654 ether)
        });

        vm.prank(executor);
        phantomSwap.executeOrder(orderHash, abi.encode(plan));

        assertTrue(bridge.lastCalled());
        assertEq(bridge.lastOrderHash(), orderHash);
        assertEq(bridge.lastRelayerData(), bytes("bridge-data"));
        assertEq(
            euint256.unwrap(bridge.lastEncryptedAmount()),
            euint256.unwrap(adapter.configuredAmountOut()),
            "bridge amount mismatch"
        );
    }

    function testExecuteOrderViaRouteEngineSelectsBestAdapter() public {
        MockAdapter secondary = new MockAdapter();
        phantomSwap.setAdapter(address(secondary), true);

        RouteEngine engine = new RouteEngine(address(this));
        engine.registerAdapter(address(adapter));
        engine.registerAdapter(address(secondary));
        phantomSwap.setRouteEngine(engine);

        adapter.setQuoteCipher(_adapterCipher(adapter, 80 ether), bytes32("route-a"), bytes("data-a"));
        adapter.setExecution(_adapterCipher(adapter, 90 ether), bytes(""));

        secondary.setQuoteCipher(_adapterCipher(secondary, 120 ether), bytes32("route-b"), bytes("data-b"));
        secondary.setExecution(_adapterCipher(secondary, 130 ether), bytes(""));

        bytes32 orderHash = phantomSwap.submitOrder(_defaultOrderParams());

        RouteEngine.AdapterHint[] memory hints = new RouteEngine.AdapterHint[](2);
        hints[0] = RouteEngine.AdapterHint({adapter: address(adapter), data: bytes("data-a"), plaintextScore: 80 ether});
        hints[1] =
            RouteEngine.AdapterHint({adapter: address(secondary), data: bytes("data-b"), plaintextScore: 120 ether});

        vm.prank(executor);
        euint256 amountOut = phantomSwap.executeOrder(orderHash, abi.encode(hints));

        assertEq(uint8(phantomSwap.getOrderStatus(orderHash)), uint8(OrderStatus.Executed));
        assertEq(secondary.lastCaller(), address(phantomSwap), "secondary adapter not called");
        assertEq(secondary.lastOrderHash(), orderHash, "secondary adapter order mismatch");
        assertEq(
            euint256.unwrap(amountOut),
            euint256.unwrap(secondary.configuredAmountOut()),
            "route engine selected wrong amount"
        );
    }

    function _defaultOrderParams() internal returns (OrderParams memory params) {
        params = OrderParams({
            tokenIn: address(0x1111),
            tokenOut: address(0x2222),
            amountIn: createInEuint256(100 ether, address(phantomSwap)),
            minAmountOut: createInEuint256(95 ether, address(phantomSwap)),
            slippageBps: createInEuint16(100, address(phantomSwap)),
            deadline: uint64(block.timestamp + 1 hours),
            salt: bytes32("salt"),
            metadata: bytes("meta")
        });
    }

    function _asCipher(uint256 plaintext) internal returns (euint256) {
        InEuint256 memory enc = createInEuint256(plaintext, address(this));
        return FHE.asEuint256(enc);
    }

    function _adapterCipher(MockAdapter target, uint256 value) internal returns (InEuint256 memory) {
        return createInEuint256(value, address(target));
    }
}

contract MockAdapter is IPhantomAdapter {
    euint256 private _encryptedAmountOut;
    bytes private _settlementData;

    euint256 private _quoteAmountOut;
    bytes32 private _quoteRouteId;
    bytes private _quoteAdapterData;

    bytes32 private _lastOrderHash;
    bytes private _lastAdapterData;
    address private _lastCaller;

    function setExecution(InEuint256 calldata encryptedAmountOut, bytes memory settlementData) external {
        _encryptedAmountOut = FHE.asEuint256(encryptedAmountOut);
        _settlementData = settlementData;
    }

    function setQuoteCipher(InEuint256 calldata quote, bytes32 routeId, bytes memory adapterData) external {
        _quoteAmountOut = FHE.asEuint256(quote);
        _quoteRouteId = routeId;
        _quoteAdapterData = adapterData;
    }

    function requestQuote(bytes32 orderHash, Order calldata, bytes calldata) external returns (Quote memory quote) {
        _lastOrderHash = orderHash;
        FHE.allow(_quoteAmountOut, msg.sender);
        FHE.allowThis(_quoteAmountOut);
        quote = Quote({routeId: _quoteRouteId, encryptedAmountOut: _quoteAmountOut, adapterData: _quoteAdapterData});
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

    function configuredAmountOut() external view returns (euint256) {
        return _encryptedAmountOut;
    }
}

contract MockZcashBridge is IZcashBridge {
    bool private _called;
    bytes32 private _orderHash;
    bytes private _relayerData;
    euint256 private _amount;

    function requestSettlement(Order calldata, SettlementRequest calldata request) external override {
        _called = true;
        _orderHash = request.orderHash;
        _relayerData = request.relayerData;
        _amount = request.encryptedAmountOut;
    }

    function isSettled(bytes32) external pure returns (bool) {
        return false;
    }

    function confirmSettlement(bytes32, bytes32) external override {}

    function lastCalled() external view returns (bool) {
        return _called;
    }

    function lastOrderHash() external view returns (bytes32) {
        return _orderHash;
    }

    function lastRelayerData() external view returns (bytes memory) {
        return _relayerData;
    }

    function lastEncryptedAmount() external view returns (euint256) {
        return _amount;
    }
}

