// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IWETH } from "../interfaces/IWETH.sol";

contract TopUpDestNativeGateway {
    IWETH public constant weth = IWETH(0x5300000000000000000000000000000000000004);
    address public immutable topUpDest;

    constructor(address _topUpDest) {
        topUpDest = _topUpDest;
    }

    receive() external payable {
        weth.deposit{value: msg.value}();
        weth.transfer(topUpDest, msg.value);
    }
}