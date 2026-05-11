// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RecoveryMessageLib } from "../../src/libraries/RecoveryMessageLib.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { AssetRecoveryDispatcher, ITopUpFactoryDeployer } from "../../src/top-up/AssetRecoveryDispatcher.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { ITopUpFactoryView } from "../../src/top-up/TopUpV2.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";
import { RoleRegistryMock } from "../mocks/RoleRegistryMock.sol";

/// @dev Stub TopUpFactory: tracks the salt-to-address mapping the dispatcher relies on
///      and (optionally) etches code at the predicted address when `deployTopUpContract`
///      is called, simulating the CREATE3 deploy.
contract TopUpFactoryStub is Test {
    /// @dev Configured pre-deploy address per salt. Lets tests pin where a salt resolves.
    mapping(bytes32 => address) public predicted;
    /// @dev Bytecode etched onto the predicted address on deploy. Empty = no-op deploy
    ///      (lets us simulate "factory call returned but didn't actually populate code").
    bytes public deployBytecode;
    /// @dev When true, `deployTopUpContract` reverts (paused / not authorized).
    bool public revertOnDeploy;
    /// @dev Tracks the last salt deployed for assertions.
    bytes32 public lastDeployedSalt;
    uint256 public deployCallCount;

    function setPredicted(bytes32 salt, address addr) external {
        predicted[salt] = addr;
    }

    function setDeployBytecode(bytes calldata code) external {
        deployBytecode = code;
    }

    function setRevertOnDeploy(bool v) external {
        revertOnDeploy = v;
    }

    function getDeterministicAddress(bytes32 salt) external view returns (address) {
        return predicted[salt];
    }

    function deployTopUpContract(bytes32 salt) external {
        if (revertOnDeploy) revert("factory paused");
        deployCallCount++;
        lastDeployedSalt = salt;
        address target = predicted[salt];
        if (deployBytecode.length > 0 && target != address(0)) {
            vm.etch(target, deployBytecode);
        }
    }
}

contract AssetRecoveryDispatcherTest is Test {
    AssetRecoveryDispatcher public dispatcher;
    LZEndpointMock public endpoint;
    RoleRegistryMock public roleRegistry;
    TopUpFactoryStub public factory;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public weth = makeAddr("weth");
    address public recoveryModule = makeAddr("recoveryModule"); // peer on OP
    uint32 public constant OP_EID = 30_111;
    bytes32 public constant GUID = bytes32(uint256(1));
    bytes32 public constant SALT = bytes32(uint256(0xCAFE));

    function setUp() public {
        endpoint = new LZEndpointMock();
        roleRegistry = new RoleRegistryMock(pauser, unpauser);
        factory = new TopUpFactoryStub();

        address impl = address(new AssetRecoveryDispatcher(address(endpoint), OP_EID, address(factory)));
        dispatcher = AssetRecoveryDispatcher(address(new UUPSProxy(impl, abi.encodeWithSelector(AssetRecoveryDispatcher.initialize.selector, owner, address(roleRegistry)))));

        vm.prank(owner);
        dispatcher.setPeer(OP_EID, bytes32(uint256(uint160(recoveryModule))));

        token = new MockERC20("Mock", "MOCK", 18);
    }

    function test_lzReceive_forwardsToTopUp() public {
        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        token.mint(address(topup), 100e18);

        // Direct-deployed impl pins owner() to 0xdEaD; stub isTokenSupported so the
        // unsupported-token check inside executeRecovery passes.
        vm.mockCall(topup.owner(), abi.encodeWithSelector(ITopUpFactoryView.isTokenSupported.selector, address(token)), abi.encode(false));

        address recipient = makeAddr("recipient");
        bytes memory message = RecoveryMessageLib.encode(_payload(address(topup), address(token), recipient, SALT));

        vm.expectEmit(true, true, true, true);
        emit AssetRecoveryDispatcher.RecoveryDispatched(GUID, address(topup), address(token), recipient);

        _deliver(message);

        assertEq(token.balanceOf(recipient), 100e18);
        assertEq(token.balanceOf(address(topup)), 0);
        assertEq(factory.deployCallCount(), 0, "factory should not be touched when topup is already deployed");
    }

    function test_lzReceive_lazyDeploysTopUpWhenMissing() public {
        // Spin up a TopUpV2 elsewhere and use its runtime as the bytecode the factory will
        // etch onto the salt-predicted address. This gives the etched contract a real
        // `executeRecovery` + `DISPATCHER == address(this dispatcher)`.
        TopUpV2 topupTemplate = new TopUpV2(weth, address(dispatcher));
        bytes memory runtimeCode = address(topupTemplate).code;

        address predictedSafe = makeAddr("safe-pre-deploy");
        assertEq(predictedSafe.code.length, 0, "precondition: safe address has no code");

        factory.setPredicted(SALT, predictedSafe);
        factory.setDeployBytecode(runtimeCode);

        // Mint the stuck token at the predicted address (this models funds that arrived
        // before TopUp was ever deployed on this chain).
        token.mint(predictedSafe, 100e18);

        // Stub the factory's `isTokenSupported` (which is what the etched TopUp's `owner()`
        // resolves to via the dead-address baked into the impl constructor — the same trick
        // used in the existing forwardsToTopUp test).
        vm.mockCall(TopUpV2(payable(predictedSafe)).owner(), abi.encodeWithSelector(ITopUpFactoryView.isTokenSupported.selector, address(token)), abi.encode(false));

        address recipient = makeAddr("recipient");
        bytes memory message = RecoveryMessageLib.encode(_payload(predictedSafe, address(token), recipient, SALT));

        vm.expectEmit(true, false, false, true);
        emit AssetRecoveryDispatcher.TopUpLazyDeployed(predictedSafe, SALT);
        vm.expectEmit(true, true, true, true);
        emit AssetRecoveryDispatcher.RecoveryDispatched(GUID, predictedSafe, address(token), recipient);

        _deliver(message);

        assertEq(factory.deployCallCount(), 1, "factory should have been called exactly once");
        assertEq(factory.lastDeployedSalt(), SALT, "factory called with payload salt");
        assertEq(token.balanceOf(recipient), 100e18, "recipient should have stuck balance");
        assertEq(token.balanceOf(predictedSafe), 0, "topup should be drained after lazy deploy");
    }

    function test_lzReceive_revertsIfSaltDoesNotMatchSafe() public {
        // Factory will resolve the salt to a *different* address than payload.safe — bogus
        // salt should be rejected before any deploy happens, so we don't litter the chain
        // with stray TopUp proxies at attacker-chosen addresses.
        address bogusSafe = makeAddr("bogus-safe");
        factory.setPredicted(SALT, makeAddr("some-other-address"));

        bytes memory message = RecoveryMessageLib.encode(_payload(bogusSafe, address(token), makeAddr("recipient"), SALT));

        vm.expectRevert(AssetRecoveryDispatcher.SaltDoesNotMatchSafe.selector);
        _deliver(message);

        assertEq(factory.deployCallCount(), 0, "factory must not be called on salt mismatch");
    }

    function test_lzReceive_revertsIfFactoryReverts() public {
        // Factory is paused (or otherwise reverts on deploy). LZ packet stays retryable.
        address predictedSafe = makeAddr("safe-pre-deploy");
        factory.setPredicted(SALT, predictedSafe);
        factory.setRevertOnDeploy(true);

        bytes memory message = RecoveryMessageLib.encode(_payload(predictedSafe, address(token), makeAddr("recipient"), SALT));

        vm.expectRevert(); // bubbled up from factory.deployTopUpContract
        _deliver(message);
    }

    function test_lzReceive_revertsIfFactoryDoesNotPopulateCode() public {
        // Salt-to-address says one thing, but `deployTopUpContract` succeeds without
        // actually populating code at the predicted address (factory misconfigured /
        // beacon impl missing). Defensive revert keeps the LZ packet retryable.
        address predictedSafe = makeAddr("safe-pre-deploy");
        factory.setPredicted(SALT, predictedSafe);
        // deployBytecode left empty → no code etched after deploy
        factory.setDeployBytecode("");

        bytes memory message = RecoveryMessageLib.encode(_payload(predictedSafe, address(token), makeAddr("recipient"), SALT));

        vm.expectRevert(AssetRecoveryDispatcher.TopUpNotDeployed.selector);
        _deliver(message);
    }

    function test_lzReceive_revertsIfNotEndpoint() public {
        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        bytes memory message = RecoveryMessageLib.encode(_payload(address(topup), address(token), makeAddr("recipient"), SALT));

        Origin memory origin = Origin({ srcEid: OP_EID, sender: bytes32(uint256(uint160(recoveryModule))), nonce: 1 });

        vm.prank(makeAddr("random"));
        vm.expectRevert();
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }

    function test_lzReceive_revertsIfWrongPeer() public {
        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        bytes memory message = RecoveryMessageLib.encode(_payload(address(topup), address(token), makeAddr("recipient"), SALT));

        Origin memory origin = Origin({ srcEid: OP_EID, sender: bytes32(uint256(uint160(makeAddr("imposter")))), nonce: 1 });

        vm.prank(address(endpoint));
        vm.expectRevert();
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }

    function test_lzReceive_revertsIfPayloadTargetsNonDispatcherTopUp() public {
        TopUpV2 rogueTopup = new TopUpV2(weth, makeAddr("someOtherDispatcher"));
        token.mint(address(rogueTopup), 100e18);

        bytes memory message = RecoveryMessageLib.encode(_payload(address(rogueTopup), address(token), makeAddr("recipient"), SALT));

        vm.expectRevert(TopUpV2.OnlyDispatcher.selector);
        _deliver(message);
    }

    function test_lzReceive_revertsIfSrcEidDoesNotMatch() public {
        // Set up a peer under a *different* EID — OAppReceiver's peer check accepts it,
        // but our SOURCE_EID defence should still trip.
        uint32 wrongSrcEid = 40_001;
        vm.prank(owner);
        dispatcher.setPeer(wrongSrcEid, bytes32(uint256(uint160(recoveryModule))));

        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        bytes memory message = RecoveryMessageLib.encode(_payload(address(topup), address(token), makeAddr("recipient"), SALT));

        Origin memory origin = Origin({ srcEid: wrongSrcEid, sender: bytes32(uint256(uint160(recoveryModule))), nonce: 1 });

        vm.prank(address(endpoint));
        vm.expectRevert(AssetRecoveryDispatcher.WrongSrcEid.selector);
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }

    function test_pause_blocksLzReceive() public {
        vm.prank(pauser);
        dispatcher.pause();

        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        token.mint(address(topup), 100e18);

        bytes memory message = RecoveryMessageLib.encode(_payload(address(topup), address(token), makeAddr("recipient"), SALT));

        // Pinned to OZ Pausable's `EnforcedPause()` — `_lzReceive` carries `whenNotPaused`.
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        _deliver(message);
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistryMock.NotPauser.selector);
        dispatcher.pause();
    }

    function test_unpause_onlyUnpauser() public {
        vm.prank(pauser);
        dispatcher.pause();

        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistryMock.NotUnpauser.selector);
        dispatcher.unpause();

        vm.prank(unpauser);
        dispatcher.unpause();
    }

    function test_sourceEid_immutableSetInConstructor() public view {
        assertEq(uint256(dispatcher.SOURCE_EID()), uint256(OP_EID));
    }

    function test_topUpFactory_immutableSetInConstructor() public view {
        assertEq(address(dispatcher.TOPUP_FACTORY()), address(factory));
    }

    function _payload(address safe, address tokenAddr, address recipient, bytes32 salt) internal pure returns (RecoveryMessageLib.Payload memory) {
        return RecoveryMessageLib.Payload({ safe: safe, token: tokenAddr, recipient: recipient, salt: salt });
    }

    function _deliver(bytes memory message) internal {
        Origin memory origin = Origin({ srcEid: OP_EID, sender: bytes32(uint256(uint160(recoveryModule))), nonce: 1 });
        vm.prank(address(endpoint));
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }
}
