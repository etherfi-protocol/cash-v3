// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcherV3 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV3.sol";
import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { RoleRegistry } from "../../../../../src/role-registry/RoleRegistry.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";
import { IFraxCustodian } from "../../../../../src/interfaces/IFraxCustodian.sol";
import { IFraxRemoteHop } from "../../../../../src/interfaces/IFraxRemoteHop.sol";
import { IMidasVault } from "../../../../../src/interfaces/IMidasVault.sol";
import { MessagingFee } from "../../../../../src/interfaces/IOFT.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";

contract SettlementDispatcherV3Test is Test {
    SettlementDispatcherV3 public dispatcher;
    RoleRegistry public roleRegistry;

    MockERC20 public usdc;
    MockERC20 public usdt;

    address public owner;
    address public bridger;
    address public alice;
    address public dataProvider;

    bytes32 constant BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");

    /// @dev Helper to set a single settlement recipient (wraps the batch API)
    function _setRecipient(address token, address recipient) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        address[] memory r = new address[](1);
        r[0] = recipient;
        dispatcher.setSettlementRecipients(t, r);
    }

    /// @dev Helper to set a single Midas redemption vault
    function _setMidasVault(address midasToken, address vault) internal {
        dispatcher.setMidasRedemptionVault(midasToken, vault);
    }

    function setUp() public {
        owner = makeAddr("owner");
        bridger = makeAddr("bridger");
        alice = makeAddr("alice");
        dataProvider = makeAddr("dataProvider");

        usdc = new MockERC20("USDC", "USDC", 6);
        usdt = new MockERC20("USDT", "USDT", 6);

        vm.mockCall(dataProvider, abi.encodeWithSignature("getRefundWallet()"), abi.encode(makeAddr("defaultRefund")));

        vm.startPrank(owner);

        address rrImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(rrImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        address dispImpl = address(new SettlementDispatcherV3(BinSponsor.Reap, dataProvider));

        address[] memory emptyTokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory emptyDest = new SettlementDispatcherV2.DestinationData[](0);

        dispatcher = SettlementDispatcherV3(payable(address(new UUPSProxy(
            dispImpl, abi.encodeWithSelector(SettlementDispatcherV2.initialize.selector, address(roleRegistry), emptyTokens, emptyDest)
        ))));

        roleRegistry.grantRole(BRIDGER_ROLE, owner);
        roleRegistry.grantRole(BRIDGER_ROLE, bridger);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  SETTLE (DIRECT TRANSFER)
    // ═══════════════════════════════════════════════════════════════

    function test_settle_succeeds() public {
        address rainRecipient = makeAddr("rain");
        vm.prank(owner);
        _setRecipient(address(usdc), rainRecipient);

        usdc.mint(address(dispatcher), 1000e6);

        vm.prank(bridger);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV3.FundsSettled(address(usdc), rainRecipient, 500e6);
        dispatcher.settle(address(usdc), 500e6);

        assertEq(usdc.balanceOf(rainRecipient), 500e6);
        assertEq(usdc.balanceOf(address(dispatcher)), 500e6);
    }

    function test_settle_differentRecipientsPerToken() public {
        address rainRecipient = makeAddr("rain");
        address reapRecipient = makeAddr("reap");

        vm.startPrank(owner);
        _setRecipient(address(usdc), rainRecipient);
        _setRecipient(address(usdt), reapRecipient);
        vm.stopPrank();

        usdc.mint(address(dispatcher), 1000e6);
        usdt.mint(address(dispatcher), 500e6);

        vm.startPrank(bridger);
        dispatcher.settle(address(usdc), 1000e6);
        dispatcher.settle(address(usdt), 500e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(rainRecipient), 1000e6);
        assertEq(usdt.balanceOf(reapRecipient), 500e6);
    }

    function test_settle_reverts_whenRecipientNotSet() public {
        usdc.mint(address(dispatcher), 100e6);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV3.SettlementRecipientNotSet.selector);
        dispatcher.settle(address(usdc), 100e6);
    }

    function test_settle_reverts_whenInsufficientBalance() public {
        vm.prank(owner);
        _setRecipient(address(usdc), alice);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        dispatcher.settle(address(usdc), 100e6);
    }

    function test_settle_reverts_whenNotBridger() public {
        vm.prank(owner);
        _setRecipient(address(usdc), alice);
        usdc.mint(address(dispatcher), 100e6);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        dispatcher.settle(address(usdc), 100e6);
    }

    function test_settle_reverts_whenZeroAmount() public {
        vm.prank(owner);
        _setRecipient(address(usdc), alice);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.settle(address(usdc), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  ADMIN: SETTLEMENT RECIPIENT
    // ═══════════════════════════════════════════════════════════════

    function test_setSettlementRecipient_succeeds() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV3.SettlementRecipientSet(address(usdc), alice);
        _setRecipient(address(usdc), alice);

        assertEq(dispatcher.getSettlementRecipient(address(usdc)), alice);
    }

    function test_setSettlementRecipient_reverts_whenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        _setRecipient(address(usdc), alice);
    }

    function test_setSettlementRecipient_reverts_whenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        _setRecipient(address(usdc), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //                  REFUND WALLET
    // ═══════════════════════════════════════════════════════════════

    function test_refundWallet_fallsBackToDataProvider() public {
        assertEq(dispatcher.getRefundWallet(), makeAddr("defaultRefund"));
    }

    function test_setRefundWallet_succeeds() public {
        address newWallet = makeAddr("newRefund");
        vm.prank(owner);
        dispatcher.setRefundWallet(newWallet);
        assertEq(dispatcher.getRefundWallet(), newWallet);
    }

    function test_transferFundsToRefundWallet_succeeds() public {
        address refund = makeAddr("refund");
        vm.prank(owner);
        dispatcher.setRefundWallet(refund);

        usdc.mint(address(dispatcher), 100e6);

        vm.prank(bridger);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.TransferToRefundWallet(address(usdc), refund, 100e6);
        dispatcher.transferFundsToRefundWallet(address(usdc), 100e6);

        assertEq(usdc.balanceOf(refund), 100e6);
    }

    function test_transferFundsToRefundWallet_reverts_whenZeroAmount() public {
        vm.prank(owner);
        dispatcher.setRefundWallet(makeAddr("refund"));

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.CannotWithdrawZeroAmount.selector);
        dispatcher.transferFundsToRefundWallet(address(usdc), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  DEPRECATED FUNCTIONS REVERT
    // ═══════════════════════════════════════════════════════════════

    function test_bridge_reverts_deprecated() public {
        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV3.Deprecated.selector);
        dispatcher.bridge(address(usdc), 100e6, 100e6);
    }

    function test_setDestinationData_reverts_deprecated() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV3.Deprecated.selector);
        dispatcher.setDestinationData(new address[](0), new SettlementDispatcherV2.DestinationData[](0));
    }

    function test_destinationData_reverts_deprecated() public {
        vm.expectRevert(SettlementDispatcherV3.Deprecated.selector);
        dispatcher.destinationData(address(usdc));
    }

    function test_prepareRideBus_reverts_deprecated() public {
        vm.expectRevert(SettlementDispatcherV3.Deprecated.selector);
        dispatcher.prepareRideBus(address(usdc), 100e6);
    }

    function test_prepareOftSend_reverts_deprecated() public {
        vm.expectRevert(SettlementDispatcherV3.Deprecated.selector);
        dispatcher.prepareOftSend(address(usdc), 100e6);
    }
}
