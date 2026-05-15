// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "solady/auth/Ownable.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";

/// @dev Minimal target with a constructor arg + payable receive so we can verify both
///      constructor args and value-forwarding through the deployer.
contract Greeter {
    uint256 public greetingId;
    constructor(uint256 _id) payable {
        greetingId = _id;
    }
    receive() external payable {}
}

contract EtherFiDeployerTest is Test {
    EtherFiDeployer public deployer;
    address public owner = makeAddr("owner");
    address public deployerA = makeAddr("deployerA");
    address public deployerB = makeAddr("deployerB");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        // Default fixture: deployer is constructed with NO initial deployers; tests opt in
        // by calling `configureDeployers` (and a couple test the constructor variant).
        deployer = new EtherFiDeployer(owner, new address[](0));
    }

    function _addr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _flag(bool b) internal pure returns (bool[] memory out) {
        out = new bool[](1);
        out[0] = b;
    }

    function _greeterInitCode(uint256 id) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Greeter).creationCode, abi.encode(id));
    }

    // ---- Constructor: initial deployers ----

    function test_constructor_seedsInitialDeployers() public {
        address[] memory initial = new address[](2);
        initial[0] = deployerA;
        initial[1] = deployerB;
        EtherFiDeployer seeded = new EtherFiDeployer(owner, initial);

        assertTrue(seeded.isDeployer(deployerA));
        assertTrue(seeded.isDeployer(deployerB));
        assertEq(seeded.deployerCount(), 2);
    }

    function test_constructor_dedupesInitialDeployers() public {
        // Duplicate entry shouldn't revert; the registry just ends up with the one entry.
        address[] memory initial = new address[](2);
        initial[0] = deployerA;
        initial[1] = deployerA;
        EtherFiDeployer seeded = new EtherFiDeployer(owner, initial);

        assertTrue(seeded.isDeployer(deployerA));
        assertEq(seeded.deployerCount(), 1);
    }

    function test_constructor_revertsOnZeroAddressInitial() public {
        address[] memory initial = new address[](1);
        initial[0] = address(0);
        vm.expectRevert(EtherFiDeployer.InvalidDeployer.selector);
        new EtherFiDeployer(owner, initial);
    }

    // ---- configureDeployers ----

    function test_configureDeployers_addsAndRemoves_inOneCall() public {
        address[] memory a = new address[](2);
        a[0] = deployerA;
        a[1] = deployerB;
        bool[] memory add = new bool[](2);
        add[0] = true;
        add[1] = true;

        vm.prank(owner);
        deployer.configureDeployers(a, add);
        assertEq(deployer.deployerCount(), 2);

        // Now remove A and re-add nothing in one call.
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(false));
        assertFalse(deployer.isDeployer(deployerA));
        assertTrue(deployer.isDeployer(deployerB));
    }

    function test_configureDeployers_mixesAddAndRemove() public {
        // Seed deployerA.
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));

        // Same call: remove A, add B.
        address[] memory a = new address[](2);
        a[0] = deployerA;
        a[1] = deployerB;
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = false;
        shouldAdd[1] = true;

        vm.expectEmit(true, true, true, true);
        emit EtherFiDeployer.DeployerRemoved(deployerA);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDeployer.DeployerAdded(deployerB);
        vm.prank(owner);
        deployer.configureDeployers(a, shouldAdd);

        assertFalse(deployer.isDeployer(deployerA));
        assertTrue(deployer.isDeployer(deployerB));
    }

    function test_configureDeployers_revertsWhen_notOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(stranger);
        deployer.configureDeployers(_addr(deployerA), _flag(true));
    }

    function test_configureDeployers_revertsWhen_arrayLengthMismatch() public {
        bool[] memory flags = new bool[](2);
        flags[0] = true;
        flags[1] = false;
        vm.expectRevert(EtherFiDeployer.ArrayLengthMismatch.selector);
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), flags);
    }

    function test_configureDeployers_revertsWhen_zeroAddress() public {
        vm.expectRevert(EtherFiDeployer.InvalidDeployer.selector);
        vm.prank(owner);
        deployer.configureDeployers(_addr(address(0)), _flag(true));
    }

    function test_configureDeployers_isIdempotent_onDuplicateAdd() public {
        vm.startPrank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));
        deployer.configureDeployers(_addr(deployerA), _flag(true)); // no-op, no revert
        vm.stopPrank();

        assertTrue(deployer.isDeployer(deployerA));
        assertEq(deployer.deployerCount(), 1);
    }

    function test_configureDeployers_isIdempotent_onMissingRemove() public {
        // Remove an address that was never registered — silent no-op.
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(false));

        assertFalse(deployer.isDeployer(deployerA));
        assertEq(deployer.deployerCount(), 0);
    }

    function test_getDeployers_listsAllRegistered() public {
        address[] memory a = new address[](2);
        a[0] = deployerA;
        a[1] = deployerB;
        bool[] memory add = new bool[](2);
        add[0] = true;
        add[1] = true;
        vm.prank(owner);
        deployer.configureDeployers(a, add);

        address[] memory list = deployer.getDeployers();
        assertEq(list.length, 2);
        assertEq(list[0], deployerA);
        assertEq(list[1], deployerB);
    }

    // ---- Deploy happy path ----

    function test_deploy_byRegisteredDeployer_landsAtDeterministicAddress() public {
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));

        bytes32 salt = keccak256("greeter-1");
        address predicted = deployer.getDeterministicAddress(salt);

        vm.expectEmit(true, true, true, true);
        emit EtherFiDeployer.ContractDeployed(salt, predicted, deployerA, 0);
        vm.prank(deployerA);
        address deployed = deployer.deploy(salt, _greeterInitCode(42));

        assertEq(deployed, predicted, "deployed != predicted");
        assertEq(Greeter(payable(deployed)).greetingId(), 42, "constructor arg passed through");
    }

    function test_deploy_byAnyRegisteredDeployer() public {
        address[] memory a = new address[](2);
        a[0] = deployerA;
        a[1] = deployerB;
        bool[] memory add = new bool[](2);
        add[0] = true;
        add[1] = true;
        vm.prank(owner);
        deployer.configureDeployers(a, add);

        bytes32 saltA = keccak256("from-A");
        vm.prank(deployerA);
        deployer.deploy(saltA, _greeterInitCode(1));

        bytes32 saltB = keccak256("from-B");
        vm.prank(deployerB);
        deployer.deploy(saltB, _greeterInitCode(2));
    }

    function test_deploy_forwardsValueToConstructor() public {
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));

        bytes32 salt = keccak256("greeter-2");
        address predicted = deployer.getDeterministicAddress(salt);
        vm.deal(deployerA, 1 ether);

        vm.prank(deployerA);
        deployer.deploy{ value: 0.5 ether }(salt, _greeterInitCode(7));

        assertEq(predicted.balance, 0.5 ether, "value forwarded to new contract");
    }

    // ---- Deploy auth ----

    function test_deploy_revertsWhen_callerNotRegistered() public {
        vm.expectRevert(EtherFiDeployer.OnlyDeployer.selector);
        vm.prank(stranger);
        deployer.deploy(keccak256("x"), _greeterInitCode(1));
    }

    function test_deploy_revertsWhen_callerIsOwnerButNotRegistered() public {
        // Owner is NOT implicitly a deployer — must be added explicitly.
        vm.expectRevert(EtherFiDeployer.OnlyDeployer.selector);
        vm.prank(owner);
        deployer.deploy(keccak256("x"), _greeterInitCode(1));
    }

    function test_deploy_revertsAfterDeployerRemoved() public {
        vm.startPrank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));
        deployer.configureDeployers(_addr(deployerA), _flag(false));
        vm.stopPrank();

        vm.expectRevert(EtherFiDeployer.OnlyDeployer.selector);
        vm.prank(deployerA);
        deployer.deploy(keccak256("x"), _greeterInitCode(1));
    }

    // ---- Collision: re-deploy with same salt reverts ----

    function test_deploy_revertsWhen_saltAlreadyUsed() public {
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));

        bytes32 salt = keccak256("dup");
        vm.startPrank(deployerA);
        deployer.deploy(salt, _greeterInitCode(1));
        vm.expectRevert();
        deployer.deploy(salt, _greeterInitCode(2));
        vm.stopPrank();
    }

    // ---- Cross-chain stability invariant: address derived only from (this, salt) ----

    function test_address_independentOfCaller() public {
        vm.prank(owner);
        deployer.configureDeployers(_addr(deployerA), _flag(true));

        bytes32 salt = keccak256("stable");
        vm.prank(stranger);
        address predictedByStranger = deployer.getDeterministicAddress(salt);
        address predictedByThis = deployer.getDeterministicAddress(salt);
        assertEq(predictedByStranger, predictedByThis);

        vm.prank(deployerA);
        address deployed = deployer.deploy(salt, _greeterInitCode(99));
        assertEq(deployed, predictedByThis);
    }
}
