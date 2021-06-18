// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

interface IBeltToken {
    function token() external view returns (address);
    function deposit(uint256 amount, uint256 min_mint_amount) external;
}