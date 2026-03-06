// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {EtherFiSafeFactory} from "../../src/safe/EtherFiSafeFactory.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";
import {Utils} from "./Utils.sol";

contract SafeTestSimulationHelper is Utils, Test {
    bytes32 public constant ETHERFI_SAFE_FACTORY_ADMIN_ROLE = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 public constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");

    RoleRegistry roleRegistry;
    EtherFiSafeFactory safeFactory;
    address etherfiWalletAddress;

    constructor () {
        etherfiWalletAddress = makeAddr("etherfiWallet");
        string memory deployments = readDeploymentFile();
        roleRegistry = RoleRegistry(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry")));
        safeFactory = EtherFiSafeFactory(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiSafeFactory")));
        _grantRoles();
    }

    function deploySafe() public returns (address etherfiWallet, address owner, uint256 ownerPk, address safe) {
        (owner, ownerPk) = makeAddrAndKey("owner");

        address[] memory owners = new address[](1);
        owners[0] = owner;

        etherfiWallet = etherfiWalletAddress;

        address[] memory modules = new address[](0);
        bytes[] memory moduleSetupData = new bytes[](0);
        uint8 threshold = 1;

        bytes32 safeSalt = keccak256(abi.encodePacked(block.timestamp, owner));

        safe = EtherFiSafeFactory(safeFactory).getDeterministicAddress(safeSalt);

        vm.prank(etherfiWallet);
        EtherFiSafeFactory(safeFactory).deployEtherFiSafe(safeSalt, owners, modules, moduleSetupData, threshold);

        return (etherfiWallet, owner, ownerPk, safe);
    }

    function grantRole(address account, bytes32 role) public {
        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(role, account);
        vm.stopPrank();
    }

    function getSignatures(bytes32 digestHash, address owner, uint256 ownerPk) external pure returns (address[] memory, bytes[] memory) {
        address[] memory signers = new address[](1);
        signers[0] = owner;

        bytes[] memory signatures = new bytes[](1);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(ownerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        return (signers, signatures);
    }

    function _grantRoles() internal {
        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherfiWalletAddress);
        roleRegistry.grantRole(ETHER_FI_WALLET_ROLE, etherfiWalletAddress);
        roleRegistry.grantRole(CASH_MODULE_CONTROLLER_ROLE, etherfiWalletAddress);
        vm.stopPrank();
    }
}