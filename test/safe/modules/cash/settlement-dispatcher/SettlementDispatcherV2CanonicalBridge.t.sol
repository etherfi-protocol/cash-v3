// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { IL2StandardBridge } from "../../../../../src/interfaces/IL2StandardBridge.sol";
import { RoleRegistry } from "../../../../../src/role-registry/RoleRegistry.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";
import { Constants } from "../../../../../src/utils/Constants.sol";

contract SettlementDispatcherV2CanonicalBridgeTest is Test, Constants {
    SettlementDispatcherV2 public dispatcher;
    RoleRegistry public roleRegistry;

    address public owner;
    address public bridger;
    address public alice;
    address public dataProvider;

    bytes32 constant BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");
    address constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
    address constant USDT_OP = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;

    function setUp() public {
        string memory opRpc = vm.envString("OPTIMISM_RPC");
        if (bytes(opRpc).length == 0) opRpc = "https://mainnet.optimism.io";
        vm.createSelectFork(opRpc);

        owner = makeAddr("owner");
        bridger = makeAddr("bridger");
        alice = makeAddr("alice");
        dataProvider = makeAddr("dataProvider");

        vm.mockCall(dataProvider, abi.encodeWithSignature("getRefundWallet()"), abi.encode(makeAddr("defaultRefund")));

        vm.startPrank(owner);

        address rrImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(rrImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        address dispImpl = address(new SettlementDispatcherV2(BinSponsor.Reap, dataProvider));

        address[] memory emptyTokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory emptyDest = new SettlementDispatcherV2.DestinationData[](0);

        dispatcher = SettlementDispatcherV2(payable(address(new UUPSProxy(
            dispImpl, abi.encodeWithSelector(SettlementDispatcherV2.initialize.selector, address(roleRegistry), emptyTokens, emptyDest)
        ))));

        roleRegistry.grantRole(BRIDGER_ROLE, owner);
        roleRegistry.grantRole(BRIDGER_ROLE, bridger);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _setCanonicalBridgeDestination(address token, address recipient, uint64 minGasLimit) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: recipient,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: minGasLimit,
            isOFT: false
        });

        dispatcher.setDestinationData(tokens, destDatas);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  CANONICAL BRIDGE — ERC20 (USDT)
    // ═══════════════════════════════════════════════════════════════

    function test_bridge_canonicalBridge_USDT_succeeds() public {
        uint256 amount = 100e6;
        uint64 minGasLimit = 200_000;

        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, minGasLimit);

        deal(USDT_OP, address(dispatcher), amount);

        uint256 dispatcherBalBefore = IERC20(USDT_OP).balanceOf(address(dispatcher));

        vm.prank(bridger);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.CanonicalBridgeWithdraw(USDT_OP, alice, amount);
        dispatcher.bridge(USDT_OP, amount, 0);

        assertEq(IERC20(USDT_OP).balanceOf(address(dispatcher)), dispatcherBalBefore - amount);
    }

    function test_bridge_canonicalBridge_USDT_callsBridgeWithCorrectParams() public {
        uint256 amount = 50e6;
        uint64 minGasLimit = 150_000;

        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, minGasLimit);

        deal(USDT_OP, address(dispatcher), amount);

        vm.expectCall(
            L2_STANDARD_BRIDGE,
            abi.encodeCall(IL2StandardBridge.withdrawTo, (USDT_OP, alice, amount, uint32(minGasLimit), ""))
        );

        vm.prank(bridger);
        dispatcher.bridge(USDT_OP, amount, 0);
    }

    function test_bridge_canonicalBridge_USDT_drainsFullBalance() public {
        uint256 amount = 1000e6;

        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, 200_000);

        deal(USDT_OP, address(dispatcher), amount);

        vm.prank(bridger);
        dispatcher.bridge(USDT_OP, amount, 0);

        assertEq(IERC20(USDT_OP).balanceOf(address(dispatcher)), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  CANONICAL BRIDGE — ETH
    // ═══════════════════════════════════════════════════════════════

    function test_bridge_canonicalBridge_ETH_succeeds() public {
        uint256 amount = 1 ether;
        uint64 minGasLimit = 200_000;

        vm.prank(owner);
        _setCanonicalBridgeDestination(ETH, alice, minGasLimit);

        vm.deal(address(dispatcher), amount);

        uint256 dispatcherBalBefore = address(dispatcher).balance;

        vm.prank(bridger);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.CanonicalBridgeWithdraw(ETH, alice, amount);
        dispatcher.bridge(ETH, amount, 0);

        assertEq(address(dispatcher).balance, dispatcherBalBefore - amount);
    }

    function test_bridge_canonicalBridge_ETH_callsBridgeWithCorrectParams() public {
        uint256 amount = 0.5 ether;
        uint64 minGasLimit = 100_000;

        vm.prank(owner);
        _setCanonicalBridgeDestination(ETH, alice, minGasLimit);

        vm.deal(address(dispatcher), amount);

        vm.expectCall(
            L2_STANDARD_BRIDGE,
            amount,
            abi.encodeCall(IL2StandardBridge.bridgeETHTo, (alice, uint32(minGasLimit), ""))
        );

        vm.prank(bridger);
        dispatcher.bridge(ETH, amount, 0);
    }

    function test_bridge_canonicalBridge_ETH_drainsFullBalance() public {
        uint256 amount = 2 ether;

        vm.prank(owner);
        _setCanonicalBridgeDestination(ETH, alice, 200_000);

        vm.deal(address(dispatcher), amount);

        vm.prank(bridger);
        dispatcher.bridge(ETH, amount, 0);

        assertEq(address(dispatcher).balance, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  CANONICAL BRIDGE — REVERTS
    // ═══════════════════════════════════════════════════════════════

    function test_bridge_canonicalBridge_reverts_whenInsufficientBalance_ERC20() public {
        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, 200_000);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        dispatcher.bridge(USDT_OP, 100e6, 0);
    }

    function test_bridge_canonicalBridge_reverts_whenInsufficientBalance_ETH() public {
        vm.prank(owner);
        _setCanonicalBridgeDestination(ETH, alice, 200_000);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        dispatcher.bridge(ETH, 1 ether, 0);
    }

    function test_bridge_canonicalBridge_reverts_whenDestinationDataNotSet() public {
        deal(USDT_OP, address(dispatcher), 100e6);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.DestinationDataNotSet.selector);
        dispatcher.bridge(USDT_OP, 100e6, 0);
    }

    function test_bridge_canonicalBridge_reverts_whenNotBridger() public {
        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, 200_000);

        deal(USDT_OP, address(dispatcher), 100e6);

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        dispatcher.bridge(USDT_OP, 100e6, 0);
    }

    function test_bridge_canonicalBridge_reverts_whenZeroAmount() public {
        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, 200_000);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.bridge(USDT_OP, 0, 0);
    }

    function test_bridge_canonicalBridge_reverts_whenZeroToken() public {
        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.bridge(address(0), 100e6, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  DESTINATION DATA — CANONICAL BRIDGE
    // ═══════════════════════════════════════════════════════════════

    function test_setDestinationData_canonicalBridge_succeeds() public {
        vm.prank(owner);
        _setCanonicalBridgeDestination(USDT_OP, alice, 200_000);

        SettlementDispatcherV2.DestinationData memory dest = dispatcher.destinationData(USDT_OP);
        assertEq(dest.destRecipient, alice);
        assertTrue(dest.useCanonicalBridge);
        assertEq(dest.minGasLimit, 200_000);
        assertEq(dest.stargate, address(0));
        assertEq(dest.destEid, 0);
    }

    function test_setDestinationData_canonicalBridge_reverts_whenStargateSet() public {
        address[] memory tokens = new address[](1);
        tokens[0] = USDT_OP;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: alice,
            stargate: makeAddr("stargate"),
            useCanonicalBridge: true,
            minGasLimit: 200_000,
            isOFT: false
        });

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.setDestinationData(tokens, destDatas);
    }

    function test_setDestinationData_canonicalBridge_reverts_whenDestEidSet() public {
        address[] memory tokens = new address[](1);
        tokens[0] = USDT_OP;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 30101,
            destRecipient: alice,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 200_000,
            isOFT: false
        });

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.setDestinationData(tokens, destDatas);
    }
}
