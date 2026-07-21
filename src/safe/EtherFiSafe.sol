// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";
import { EtherFiSafeCore } from "./EtherFiSafeCore.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";

/**
 * @title EtherFiSafe
 * @author ether.fi
 * @notice Concrete EtherFiSafe. Ownership and recovery are managed locally on this chain;
 *         there is no cross-chain owner synchronization.
 */
contract EtherFiSafe is EtherFiSafeCore {
    constructor(address _dataProvider) payable EtherFiSafeCore(_dataProvider) {}
}
