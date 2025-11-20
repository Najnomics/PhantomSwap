// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {OrderStatus, OrderParams, Order} from "../types/PhantomOrder.sol";
import {OrderLib} from "../libraries/OrderLib.sol";
import {OrderPermissions} from "../fhe/OrderPermissions.sol";
import {IPhantomAdapter} from "../interfaces/IPhantomAdapter.sol";
import {IRouteEngine} from "../interfaces/IRouteEngine.sol";
import {IZcashBridge} from "../interfaces/IZcashBridge.sol";
import {IPhantomHook} from "../interfaces/IPhantomHook.sol";

/// @title PhantomSwap
/// @notice Core coordinator for encrypted swap orders leveraging Fhenix CoFHE and Zcash settlement.
contract PhantomSwap is Ownable, ReentrancyGuard {
    using OrderLib for OrderParams;

    /// @notice Container for executor-provided execution instructions.
    struct ExecutionPlan {
        address adapter;
        bytes adapterData;
        bytes settlementData;
        bytes32 routeId;
        euint256 encryptedQuote; // ciphertext chosen via CoFHE.
    }

    /// @notice Custom errors.
    error InvalidDeadline();
    error OrderAlreadyExists(bytes32 orderHash);
    error OrderNotFound(bytes32 orderHash);
    error OrderNotPending(bytes32 orderHash);
    error OrderExpired(bytes32 orderHash);
    error UnauthorizedExecutor(address caller);
    error AdapterNotAllowed(address adapter);
    error UnauthorizedCancel(address caller);
    error InvalidAddress();

    /// @notice Emitted when a new order is created.
    event OrderSubmitted(
        bytes32 indexed orderHash, address indexed owner, address indexed tokenIn, address tokenOut, uint64 deadline
    );

    /// @notice Emitted when an order is executed by an authorized executor.
    event OrderExecuted(
        bytes32 indexed orderHash,
        address indexed executor,
        address indexed adapter,
        bytes32 routeId,
        uint256 encryptedAmountOut
    );

    /// @notice Emitted when an order is cancelled.
    event OrderCancelled(bytes32 indexed orderHash, address indexed caller);

    /// @notice Emitted when settlement is forwarded to the Zcash bridge.
    event SettlementForwarded(bytes32 indexed orderHash, bytes relayerData);

    /// @notice Administrative event emitters.
    event ExecutorUpdated(address indexed executor, bool allowed);
    event AdapterUpdated(address indexed adapter, bool allowed);
    event RouteEngineUpdated(address indexed routeEngine);
    event ZcashBridgeUpdated(address indexed bridge);
    event PhantomHookUpdated(address indexed hook);

    mapping(bytes32 => Order) private _orders;
    mapping(address => bool) public executors;
    mapping(address => bool) public adapters;

    IRouteEngine public routeEngine;
    IZcashBridge public zcashBridge;
    IPhantomHook public phantomHook;

    modifier onlyExecutor() {
        if (!executors[msg.sender]) revert UnauthorizedExecutor(msg.sender);
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------------
    // Order lifecycle
    // ---------------------------------------------------------------------

    function submitOrder(OrderParams calldata params) external nonReentrant returns (bytes32 orderHash) {
        if (params.tokenIn == address(0) || params.tokenOut == address(0)) revert InvalidAddress();
        if (params.deadline <= block.timestamp) revert InvalidDeadline();

        orderHash = params.computeOrderHash(msg.sender);

        Order storage existing = _orders[orderHash];
        if (existing.status != OrderStatus.None) revert OrderAlreadyExists(orderHash);

        Order memory orderData = params.toOrder(msg.sender);
        OrderPermissions.grantOnSubmission(orderData, msg.sender);
        _orders[orderHash] = orderData;
        if (address(routeEngine) != address(0)) {
            OrderPermissions.grantForRouting(_orders[orderHash], address(routeEngine));
        }

        emit OrderSubmitted(orderHash, msg.sender, params.tokenIn, params.tokenOut, params.deadline);
    }

    function executeOrder(bytes32 orderHash, bytes calldata executionPayload)
        external
        nonReentrant
        onlyExecutor
        returns (euint256 encryptedAmountOut)
    {
        Order storage orderSlot = _orders[orderHash];
        if (orderSlot.status == OrderStatus.None) revert OrderNotFound(orderHash);
        if (orderSlot.status != OrderStatus.Submitted) revert OrderNotPending(orderHash);
        if (orderSlot.deadline < block.timestamp) revert OrderExpired(orderHash);

        Order memory orderMem = _copyOrder(orderSlot);
        ExecutionPlan memory plan = _resolveExecutionPlan(orderHash, orderMem, executionPayload);

        if (!adapters[plan.adapter]) revert AdapterNotAllowed(plan.adapter);

        OrderPermissions.grantForExecution(orderSlot, msg.sender, plan.adapter);

        IPhantomAdapter.ExecutionResponse memory response =
            IPhantomAdapter(plan.adapter).executeSwap(orderHash, orderMem, plan.adapterData);

        orderSlot.status = OrderStatus.Executed;

        encryptedAmountOut = response.encryptedAmountOut;

        emit OrderExecuted(orderHash, msg.sender, plan.adapter, plan.routeId, euint256.unwrap(encryptedAmountOut));

        bytes memory settlementBlob =
            response.settlementData.length != 0 ? response.settlementData : plan.settlementData;

        if (
            address(zcashBridge) != address(0) && euint256.unwrap(encryptedAmountOut) != 0 && settlementBlob.length != 0
        ) {
            IZcashBridge.SettlementRequest memory request = IZcashBridge.SettlementRequest({
                orderHash: orderHash, encryptedAmountOut: encryptedAmountOut, relayerData: settlementBlob
            });
            zcashBridge.requestSettlement(orderMem, request);
            emit SettlementForwarded(orderHash, settlementBlob);
        }
    }

    function cancelOrder(bytes32 orderHash) external nonReentrant {
        Order storage orderSlot = _orders[orderHash];
        if (orderSlot.status == OrderStatus.None) revert OrderNotFound(orderHash);
        if (orderSlot.status != OrderStatus.Submitted) revert OrderNotPending(orderHash);

        bool isOwner = msg.sender == orderSlot.owner;
        bool isAdmin = msg.sender == owner();

        if (!isOwner && !isAdmin) revert UnauthorizedCancel(msg.sender);

        orderSlot.status = OrderStatus.Cancelled;

        emit OrderCancelled(orderHash, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Admin controls
    // ---------------------------------------------------------------------

    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert InvalidAddress();
        executors[executor] = allowed;
        emit ExecutorUpdated(executor, allowed);
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert InvalidAddress();
        adapters[adapter] = allowed;
        if (address(phantomHook) != address(0)) {
            phantomHook.updateAuthorizedSender(adapter, allowed);
        }
        emit AdapterUpdated(adapter, allowed);
    }

    function setRouteEngine(IRouteEngine newEngine) external onlyOwner {
        routeEngine = newEngine;
        emit RouteEngineUpdated(address(newEngine));
    }

    function setZcashBridge(IZcashBridge newBridge) external onlyOwner {
        zcashBridge = newBridge;
        emit ZcashBridgeUpdated(address(newBridge));
    }

    function setPhantomHook(IPhantomHook newHook) external onlyOwner {
        phantomHook = newHook;
        emit PhantomHookUpdated(address(newHook));
    }

    // ---------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------

    function getOrder(bytes32 orderHash) external view returns (Order memory order) {
        Order storage orderSlot = _orders[orderHash];
        if (orderSlot.status == OrderStatus.None) revert OrderNotFound(orderHash);
        order = _copyOrder(orderSlot);
    }

    function getOrderStatus(bytes32 orderHash) external view returns (OrderStatus) {
        return _orders[orderHash].status;
    }

    function computeOrderHash(OrderParams calldata params, address ownerAddress) external pure returns (bytes32) {
        return OrderLib.computeOrderHash(params, ownerAddress);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _resolveExecutionPlan(bytes32 orderHash, Order memory orderMem, bytes calldata executionPayload)
        internal
        returns (ExecutionPlan memory plan)
    {
        if (address(routeEngine) != address(0)) {
            IRouteEngine.RouteSelection memory selection =
                routeEngine.selectBestRoute(orderHash, orderMem, executionPayload);
            plan.adapter = selection.adapter;
            plan.adapterData = selection.adapterData.length != 0 ? selection.adapterData : selection.quote.adapterData;
            plan.settlementData = selection.settlementData;
            plan.routeId = selection.quote.routeId;
            plan.encryptedQuote = euint256.unwrap(selection.encryptedQuote) != 0
                ? selection.encryptedQuote
                : selection.quote.encryptedAmountOut;
        } else {
            plan = abi.decode(executionPayload, (ExecutionPlan));
        }
    }

    function _copyOrder(Order storage orderSlot) internal view returns (Order memory order) {
        order = Order({
            owner: orderSlot.owner,
            tokenIn: orderSlot.tokenIn,
            tokenOut: orderSlot.tokenOut,
            amountIn: orderSlot.amountIn,
            minAmountOut: orderSlot.minAmountOut,
            slippageBps: orderSlot.slippageBps,
            deadline: orderSlot.deadline,
            salt: orderSlot.salt,
            metadata: orderSlot.metadata,
            status: orderSlot.status
        });
    }
}

