// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICurveStableSwap {
    function coins(uint256 index) external view returns (address);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
}


