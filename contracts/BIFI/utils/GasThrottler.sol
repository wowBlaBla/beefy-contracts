// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

import "./IGasPrice.sol";

contract GasThrottler {

    address public gasprice = address(0x16cD932c494Ac1B3452d6C8453fB7665aB49EC6b);

    modifier gasThrottle() {
        require(tx.gasprice <= IGasPrice(gasprice).maxGasPrice(), "gas is too high!");
        _;
    }
}