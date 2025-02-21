// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors } from "../../src/safe/EtherFiSafe.sol";

contract SafeTestSetup is Test {
    EtherFiSafe public safe;

    uint256 owner1Pk;
    uint256 owner2Pk;
    uint256 owner3Pk;
    uint256 notOwnerPk;
    address public owner1;
    address public owner2;
    address public owner3;
    address public notOwner;

    uint8 threshold;

    address public module1 = makeAddr("module1");
    address public module2 = makeAddr("module2");

    function setUp() public {
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");
        (owner3, owner3Pk) = makeAddrAndKey("owner3");
        (notOwner, notOwnerPk) = makeAddrAndKey("notOwner");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        threshold = 2;

        safe = new EtherFiSafe(address(0));
        safe.initialize(owners, threshold);
    }
}