// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockCurvePool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public rate; // scaled by 1e18

    uint256 public lastDx;
    uint256 public lastMinDy;
    uint256 public lastDy;

    constructor(address token0_, address token1_) {
        token0 = IERC20(token0_);
        token1 = IERC20(token1_);
        rate = 1e18;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return address(token0);
        if (index == 1) return address(token1);
        revert("unsupported index");
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        require(i == 0 && j == 1, "unsupported pair");
        return dx * rate / 1e18;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256) {
        require(i == 0 && j == 1, "unsupported pair");

        lastDx = dx;
        lastMinDy = minDy;

        token0.safeTransferFrom(msg.sender, address(this), dx);

        uint256 dy = dx * rate / 1e18;
        require(dy >= minDy, "insufficient dy");

        lastDy = dy;
        token1.safeTransfer(msg.sender, dy);

        return dy;
    }
}


