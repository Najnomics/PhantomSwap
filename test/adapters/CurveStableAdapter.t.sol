// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";
import {FHE, InEuint256, InEuint16, euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {CurveStableAdapter} from "../../src/adapters/CurveStableAdapter.sol";
import {Order, OrderStatus} from "../../src/types/PhantomOrder.sol";
import {IPhantomAdapter} from "../../src/interfaces/IPhantomAdapter.sol";

import {MockCurvePool} from "../mocks/curve/MockCurvePool.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract CurveStableAdapterTest is Test, CoFheTest {
    CurveStableAdapter internal adapter;
    MockCurvePool internal pool;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal phantomSwap = address(this);

    function setUp() public {
        vm.prank(TM_ADMIN);
        taskManager.setVerifierSigner(address(0));

        tokenIn = new MockERC20("TokenIn", "TIN", 18);
        tokenOut = new MockERC20("TokenOut", "TOUT", 18);

        pool = new MockCurvePool(address(tokenIn), address(tokenOut));
        pool.setRate(1_050_000_000_000_000_000); // 1.05x

        adapter = new CurveStableAdapter(phantomSwap, address(pool), 0, 1);
    }

    function testRequestQuoteReturnsEncryptedDy() public {
        Order memory order = _buildOrder(100 ether, 95 ether, 100);

        vm.prank(phantomSwap);
        IPhantomAdapter.Quote memory quote = adapter.requestQuote(bytes32("order"), order, bytes(""));

        assertHashValue(euint256.unwrap(quote.encryptedAmountOut), 105 ether, "quote mismatch");

        assertEq(quote.routeId, keccak256(abi.encode(bytes32("order"), address(pool))));
    }

    function testExecuteSwapPullsFundsAndReturnsCipher() public {
        uint256 amountIn = 200 ether;
        tokenIn.mint(address(this), amountIn);
        tokenOut.mint(address(pool), 1_000_000 ether);

        tokenIn.approve(address(adapter), type(uint256).max);

        Order memory order = _buildOrder(amountIn, 190 ether, 50);
        bytes32 orderHash = keccak256("curve-order");

        vm.prank(phantomSwap);
        IPhantomAdapter.ExecutionResponse memory response = adapter.executeSwap(orderHash, order, bytes(""));

        assertEq(tokenIn.balanceOf(address(this)), 0, "input not transferred");
        assertEq(tokenOut.balanceOf(address(this)), 210 ether, "output mismatch");
        assertEq(tokenIn.allowance(address(adapter), address(pool)), 0, "allowance not reset");

        assertHashValue(euint256.unwrap(response.encryptedAmountOut), 210 ether, "ciphertext amount mismatch");
    }

    function _buildOrder(uint256 amountIn, uint256 minOut, uint16 slippageBps)
        internal
        returns (Order memory order)
    {
        InEuint256 memory amountCipher = createInEuint256(amountIn, address(adapter));
        InEuint256 memory minOutCipher = createInEuint256(minOut, address(adapter));
        InEuint16 memory slippageCipher = createInEuint16(slippageBps, address(adapter));

        order = Order({
            owner: address(0xBEEF),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            amountIn: FHE.asEuint256(amountCipher),
            minAmountOut: FHE.asEuint256(minOutCipher),
            slippageBps: FHE.asEuint16(slippageCipher),
            deadline: uint64(block.timestamp + 1 hours),
            salt: bytes32("salt"),
            metadata: "",
            status: OrderStatus.Submitted
        });

        FHE.allow(order.amountIn, address(adapter));
        FHE.allow(order.minAmountOut, address(adapter));
        FHE.allow(order.slippageBps, address(adapter));
    }
}


