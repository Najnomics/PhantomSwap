// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";
import {FHE, InEuint256, InEuint16, euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {ZcashBridge} from "../../src/bridge/ZcashBridge.sol";
import {RelayParams} from "../../src/types/ZcashTypes.sol";
import {IZcashBridge} from "../../src/interfaces/IZcashBridge.sol";
import {Order, OrderStatus} from "../../src/types/PhantomOrder.sol";

contract ZcashBridgeTest is Test, CoFheTest {
    ZcashBridge internal bridge;
    address internal relayer = address(0xBEEF);
    bytes32 internal constant SHIELDED_RECEIVER = bytes32(uint256(0x1234));
    Order internal dummyOrder;

    function setUp() public {
        vm.prank(TM_ADMIN);
        taskManager.setVerifierSigner(address(0));

        bridge = new ZcashBridge(address(this));
        bridge.setRelayer(relayer, true);

        dummyOrder = Order({
            owner: address(0x1),
            tokenIn: address(0x2),
            tokenOut: address(0x3),
            amountIn: FHE.asEuint256(createInEuint256(1 ether, address(bridge))),
            minAmountOut: FHE.asEuint256(createInEuint256(1 ether, address(bridge))),
            slippageBps: FHE.asEuint16(createInEuint16(100, address(bridge))),
            deadline: uint64(block.timestamp + 1 hours),
            salt: bytes32("salt"),
            metadata: "",
            status: OrderStatus.Executed
        });
    }

    function testRequestAndConfirmSettlement() public {
        IZcashBridge.SettlementRequest memory request = _buildRequest(10 ether, 1 hours);

        bridge.requestSettlement(dummyOrder, request);

        ZcashBridge.SettlementOperation memory op = bridge.getOperation(request.orderHash);
        assertEq(op.orderHash, request.orderHash);
        assertEq(op.relayer, relayer);
        assertFalse(op.completed);

        vm.prank(relayer);
        bridge.confirmSettlement(request.orderHash, bytes32(uint256(0xABC)));

        assertTrue(bridge.isSettled(request.orderHash));

        op = bridge.getOperation(request.orderHash);
        assertTrue(op.completed);
        assertEq(op.zcashTxId, bytes32(uint256(0xABC)));
    }

    function testOnlyAuthorizedRelayerCanConfirm() public {
        IZcashBridge.SettlementRequest memory request = _buildRequest(5 ether, 1 hours);
        bridge.requestSettlement(dummyOrder, request);

        vm.expectRevert(
            abi.encodeWithSelector(ZcashBridge.NotAuthorizedRelayer.selector, address(0x123))
        );
        vm.prank(address(0x123));
        bridge.confirmSettlement(request.orderHash, bytes32(uint256(0x1)));
    }

    function testExpireSettlementAfterDeadline() public {
        IZcashBridge.SettlementRequest memory request = _buildRequest(5 ether, 6 minutes);
        bridge.requestSettlement(dummyOrder, request);

        vm.warp(block.timestamp + 10 minutes);
        bridge.expireSettlement(request.orderHash);

        vm.expectRevert(abi.encodeWithSelector(ZcashBridge.UnknownOrder.selector, request.orderHash));
        bridge.getOperation(request.orderHash);
    }

    function _buildRequest(uint256 amount, uint64 expiryDelay) internal returns (IZcashBridge.SettlementRequest memory) {
        InEuint256 memory cipher = createInEuint256(amount, TM_ADMIN);
        euint256 encryptedAmount = FHE.asEuint256(cipher);

        bytes32 orderHash = keccak256(abi.encodePacked(address(this), amount, block.timestamp));

        RelayParams memory params = RelayParams({
            relayer: relayer,
            shieldedReceiver: SHIELDED_RECEIVER,
            minConfirmations: 10,
            expiry: uint64(block.timestamp + expiryDelay)
        });

        return IZcashBridge.SettlementRequest({
            orderHash: orderHash,
            encryptedAmountOut: encryptedAmount,
            relayerData: abi.encode(params)
        });
    }
}

