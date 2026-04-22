// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { TopUpDispatcher } from "../../src/top-up/TopUpDispatcher.sol";
import { RecoveryMessageLib } from "../../src/libraries/RecoveryMessageLib.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";
import { RoleRegistryMock } from "../mocks/RoleRegistryMock.sol";

contract TopUpDispatcherTest is Test {
    TopUpDispatcher public dispatcher;
    LZEndpointMock public endpoint;
    RoleRegistryMock public roleRegistry;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public weth = makeAddr("weth");
    address public recoveryModule = makeAddr("recoveryModule"); // peer on OP
    uint32 public constant OP_EID = 30_111;
    bytes32 public constant GUID = bytes32(uint256(1));

    function setUp() public {
        endpoint = new LZEndpointMock();
        roleRegistry = new RoleRegistryMock(pauser, unpauser);

        address impl = address(new TopUpDispatcher(address(endpoint), OP_EID, address(roleRegistry)));
        dispatcher = TopUpDispatcher(address(new UUPSProxy(impl, abi.encodeWithSelector(TopUpDispatcher.initialize.selector, owner))));

        vm.prank(owner);
        dispatcher.setPeer(OP_EID, bytes32(uint256(uint160(recoveryModule))));

        token = new MockERC20("Mock", "MOCK", 18);
    }

    function test_lzReceive_forwardsToTopUp() public {
        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        token.mint(address(topup), 100e18);

        address recipient = makeAddr("recipient");
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(topup),
            token: address(token),
            amount: 40e18,
            recipient: recipient
        }));

        vm.expectEmit(true, true, true, true);
        emit TopUpDispatcher.RecoveryDispatched(GUID, address(topup), address(token), recipient, 40e18);

        _deliver(message);

        assertEq(token.balanceOf(recipient), 40e18);
        assertEq(token.balanceOf(address(topup)), 60e18);
    }

    function test_lzReceive_revertsIfNotEndpoint() public {
        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(topup),
            token: address(token),
            amount: 1e18,
            recipient: makeAddr("recipient")
        }));

        Origin memory origin = Origin({
            srcEid: OP_EID,
            sender: bytes32(uint256(uint160(recoveryModule))),
            nonce: 1
        });

        vm.prank(makeAddr("random"));
        vm.expectRevert();
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }

    function test_lzReceive_revertsIfWrongPeer() public {
        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(topup),
            token: address(token),
            amount: 1e18,
            recipient: makeAddr("recipient")
        }));

        Origin memory origin = Origin({
            srcEid: OP_EID,
            sender: bytes32(uint256(uint160(makeAddr("imposter")))),
            nonce: 1
        });

        vm.prank(address(endpoint));
        vm.expectRevert();
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }

    function test_lzReceive_revertsIfPayloadTargetsNonDispatcherTopUp() public {
        TopUpV2 rogueTopup = new TopUpV2(weth, makeAddr("someOtherDispatcher"));
        token.mint(address(rogueTopup), 100e18);

        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(rogueTopup),
            token: address(token),
            amount: 1e18,
            recipient: makeAddr("recipient")
        }));

        vm.expectRevert(TopUpV2.OnlyDispatcher.selector);
        _deliver(message);
    }

    function test_lzReceive_revertsIfTopUpNotDeployed() public {
        address undeployed = makeAddr("undeployedTopUp"); // has no code
        assertEq(undeployed.code.length, 0, "precondition: no code");

        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: undeployed,
            token: address(token),
            amount: 1e18,
            recipient: makeAddr("recipient")
        }));

        vm.expectRevert(TopUpDispatcher.TopUpNotDeployed.selector);
        _deliver(message);
    }

    function test_lzReceive_revertsIfSrcEidDoesNotMatch() public {
        // Set up a peer under a *different* EID — OAppReceiver's peer check accepts it,
        // but our SOURCE_EID defence should still trip.
        uint32 wrongSrcEid = 40_001;
        vm.prank(owner);
        dispatcher.setPeer(wrongSrcEid, bytes32(uint256(uint160(recoveryModule))));

        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(topup),
            token: address(token),
            amount: 1e18,
            recipient: makeAddr("recipient")
        }));

        Origin memory origin = Origin({
            srcEid: wrongSrcEid,
            sender: bytes32(uint256(uint160(recoveryModule))),
            nonce: 1
        });

        vm.prank(address(endpoint));
        vm.expectRevert(TopUpDispatcher.WrongSrcEid.selector);
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }

    function test_pause_blocksLzReceive() public {
        vm.prank(pauser);
        dispatcher.pause();

        TopUpV2 topup = new TopUpV2(weth, address(dispatcher));
        token.mint(address(topup), 100e18);

        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(topup),
            token: address(token),
            amount: 1e18,
            recipient: makeAddr("recipient")
        }));

        vm.expectRevert();
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

    function _deliver(bytes memory message) internal {
        Origin memory origin = Origin({
            srcEid: OP_EID,
            sender: bytes32(uint256(uint160(recoveryModule))),
            nonce: 1
        });
        vm.prank(address(endpoint));
        dispatcher.lzReceive(origin, GUID, message, address(0), "");
    }
}
