// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, Vm } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RampVolumeEmitter } from "../../src/ramp-volume/RampVolumeEmitter.sol";
import { IRampVolumeEmitter } from "../../src/interfaces/IRampVolumeEmitter.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract RampVolumeEmitterTest is Test {
    RampVolumeEmitter public emitter;
    RoleRegistry public roleRegistry;

    address public owner = makeAddr("owner");
    address public relayer = makeAddr("relayer");
    address public stranger = makeAddr("stranger");
    address public dataProviderMock = makeAddr("dataProvider");

    bytes32 internal constant ONRAMP = bytes32("onramp");
    bytes32 internal constant OFFRAMP = bytes32("offramp");
    bytes32 internal constant USDC = bytes32("USDC");
    bytes32 internal constant EURC = bytes32("EURC");

    uint64 internal constant DAY = 1781481600; // 2026-06-15 00:00:00 UTC
    uint64 internal constant NOW = 1781500000; // some emission time during that day

    // Mirror of the contract event for vm.expectEmit.
    event RampVolume(bytes32 indexed label, bytes32 indexed token, uint64 indexed dayTimestamp, uint256 value, uint64 asOf);

    function setUp() public {
        vm.warp(NOW);
        vm.startPrank(owner);

        address rrImpl = address(new RoleRegistry(dataProviderMock));
        roleRegistry = RoleRegistry(address(new UUPSProxy(rrImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        address emitterImpl = address(new RampVolumeEmitter());
        emitter = RampVolumeEmitter(address(new UUPSProxy(emitterImpl, abi.encodeWithSelector(RampVolumeEmitter.initialize.selector, address(roleRegistry)))));

        roleRegistry.grantRole(emitter.RAMP_VOLUME_EMITTER_ROLE(), relayer);
        vm.stopPrank();
    }

    function test_roleConstant_matchesKeccak() public view {
        assertEq(emitter.RAMP_VOLUME_EMITTER_ROLE(), keccak256("RAMP_VOLUME_EMITTER_ROLE"));
    }

    function test_emitRampVolume_byRelayer_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(emitter));
        emit RampVolume(ONRAMP, USDC, DAY, 12_345_670000, NOW);

        vm.prank(relayer);
        emitter.emitRampVolume(ONRAMP, USDC, DAY, 12_345_670000);
    }

    function test_emitRampVolume_revertsForNonRole() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vm.prank(stranger);
        emitter.emitRampVolume(ONRAMP, USDC, DAY, 1);
    }

    function test_emitRampVolumes_batch_emitsAllEventsWithSharedAsOf() public {
        IRampVolumeEmitter.RampVolumeData[] memory items = new IRampVolumeEmitter.RampVolumeData[](3);
        items[0] = IRampVolumeEmitter.RampVolumeData(ONRAMP, USDC, DAY, 100e6);
        items[1] = IRampVolumeEmitter.RampVolumeData(OFFRAMP, USDC, DAY, 50e6);
        items[2] = IRampVolumeEmitter.RampVolumeData(ONRAMP, EURC, DAY, 25e6);

        vm.expectEmit(true, true, true, true, address(emitter));
        emit RampVolume(ONRAMP, USDC, DAY, 100e6, NOW);
        vm.expectEmit(true, true, true, true, address(emitter));
        emit RampVolume(OFFRAMP, USDC, DAY, 50e6, NOW);
        vm.expectEmit(true, true, true, true, address(emitter));
        emit RampVolume(ONRAMP, EURC, DAY, 25e6, NOW);

        vm.prank(relayer);
        emitter.emitRampVolumes(items);
    }

    function test_emitRampVolumes_revertsForNonRole() public {
        IRampVolumeEmitter.RampVolumeData[] memory items = new IRampVolumeEmitter.RampVolumeData[](1);
        items[0] = IRampVolumeEmitter.RampVolumeData(ONRAMP, USDC, DAY, 1);

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vm.prank(stranger);
        emitter.emitRampVolumes(items);
    }

    function test_emitRampVolumes_emptyArray_noEmitNoRevert() public {
        IRampVolumeEmitter.RampVolumeData[] memory items = new IRampVolumeEmitter.RampVolumeData[](0);

        vm.recordLogs();
        vm.prank(relayer);
        emitter.emitRampVolumes(items);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    function test_restatement_reemitOlderDayWithNewValue() public {
        // Day already pushed earlier with one value...
        vm.prank(relayer);
        emitter.emitRampVolume(ONRAMP, USDC, DAY, 100e6);

        // ...later (next run) the same day is restated with a higher value. The contract is
        // stateless, so the re-emission just emits again — latest-wins is the consumer's job.
        vm.warp(NOW + 3600);
        vm.expectEmit(true, true, true, true, address(emitter));
        emit RampVolume(ONRAMP, USDC, DAY, 150e6, NOW + 3600);

        vm.prank(relayer);
        emitter.emitRampVolume(ONRAMP, USDC, DAY, 150e6);
    }

    function test_refundShrink_valueCanDecrease() public {
        vm.prank(relayer);
        emitter.emitRampVolume(ONRAMP, USDC, DAY, 100e6);

        // A refund shrinks the day-to-date total; non-monotonic is allowed (no revert).
        vm.warp(NOW + 3600);
        vm.expectEmit(true, true, true, true, address(emitter));
        emit RampVolume(ONRAMP, USDC, DAY, 80e6, NOW + 3600);

        vm.prank(relayer);
        emitter.emitRampVolume(ONRAMP, USDC, DAY, 80e6);
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        emitter.initialize(address(roleRegistry));
    }
}
