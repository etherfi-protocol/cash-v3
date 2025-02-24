// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";

contract SafeTestSetup is Test {
    EtherFiSafe public safe;
    EtherFiDataProvider public dataProvider;
    RoleRegistry public roleRegistry;

    address owner;
    uint256 owner1Pk;
    uint256 owner2Pk;
    uint256 owner3Pk;
    uint256 notOwnerPk;
    address public owner1;
    address public owner2;
    address public owner3;
    address public notOwner;
    address public pauser;
    address public unpauser;
    address public hook;

    uint8 threshold;

    address public module1 = makeAddr("module1");
    address public module2 = makeAddr("module2");
    address public cashModule = makeAddr("cashModule");

    function setUp() public {
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        hook = makeAddr("hook");
        owner = makeAddr("owner");
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");
        (owner3, owner3Pk) = makeAddrAndKey("owner3");
        (notOwner, notOwnerPk) = makeAddrAndKey("notOwner");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        threshold = 2;

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;
        
        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry());
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        address dataProviderImpl = address(new EtherFiDataProvider());
        dataProvider = EtherFiDataProvider(address(new UUPSProxy(
            dataProviderImpl, 
            abi.encodeWithSelector(
                EtherFiDataProvider.initialize.selector,
                address(roleRegistry),
                cashModule,
                modules,
                hook
            )
        )));

        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);

        safe = new EtherFiSafe(address(dataProvider));
        safe.initialize(owners, modules, threshold);

        vm.stopPrank();
    }
}
