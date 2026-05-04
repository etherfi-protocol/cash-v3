// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { ICCTPTokenMessenger } from "../../../../../src/interfaces/ICCTPTokenMessenger.sol";
import { RoleRegistry } from "../../../../../src/role-registry/RoleRegistry.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";
import { Constants } from "../../../../../src/utils/Constants.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";

/**
 * @notice Mock CCTP TokenMessenger that burns tokens from caller via transferFrom.
 */
contract MockCCTPTokenMessenger is ICCTPTokenMessenger {
    event DepositForBurnCalled(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external override {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        emit DepositForBurnCalled(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold);
    }
}

contract SettlementDispatcherV2CCTPTest is Test, Constants {
    SettlementDispatcherV2 public dispatcher;
    RoleRegistry public roleRegistry;
    MockCCTPTokenMessenger public mockMessenger;
    MockERC20 public usdc;

    address public owner;
    address public bridger;
    address public alice;
    address public dataProvider;

    bytes32 constant BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");
    uint32 constant DEST_DOMAIN_ETHEREUM = 0;

    function setUp() public {
        owner = makeAddr("owner");
        bridger = makeAddr("bridger");
        alice = makeAddr("alice");
        dataProvider = makeAddr("dataProvider");

        usdc = new MockERC20("USDC", "USDC", 6);
        mockMessenger = new MockCCTPTokenMessenger();

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

        // Configure CCTP
        dispatcher.setCCTPConfig(address(mockMessenger), DEST_DOMAIN_ETHEREUM, 0, 2000);

        vm.stopPrank();
    }

    function _setCCTPDestination(address token, address recipient) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: recipient,
            stargate: address(0),
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: false,
            remoteToken: address(0),
            useCCTP: true
        });

        dispatcher.setDestinationData(tokens, destDatas);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  CCTP CONFIG
    // ═══════════════════════════════════════════════════════════════

    function test_cctp_setCCTPConfig_succeeds() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.CCTPConfigSet(address(mockMessenger), DEST_DOMAIN_ETHEREUM, 0, 2000);
        dispatcher.setCCTPConfig(address(mockMessenger), DEST_DOMAIN_ETHEREUM, 0, 2000);

        (address messenger_, uint32 domain_, uint256 maxFee_, uint32 minFinality_) = dispatcher.getCCTPConfig();
        assertEq(messenger_, address(mockMessenger));
        assertEq(domain_, DEST_DOMAIN_ETHEREUM);
        assertEq(maxFee_, 0);
        assertEq(minFinality_, 2000);
    }

    function test_cctp_setCCTPConfig_reverts_whenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        dispatcher.setCCTPConfig(address(mockMessenger), DEST_DOMAIN_ETHEREUM, 0, 2000);
    }

    function test_cctp_setCCTPConfig_reverts_whenZeroMessenger() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.setCCTPConfig(address(0), DEST_DOMAIN_ETHEREUM, 0, 2000);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  BRIDGE VIA CCTP
    // ═══════════════════════════════════════════════════════════════

    function test_cctp_bridge_succeeds() public {
        uint256 amount = 100e6;

        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        usdc.mint(address(dispatcher), amount);

        uint256 dispatcherBalBefore = usdc.balanceOf(address(dispatcher));

        vm.prank(bridger);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.FundsBridgedWithCCTP(address(usdc), amount, DEST_DOMAIN_ETHEREUM, alice);
        dispatcher.bridge(address(usdc), amount, 0);

        assertEq(usdc.balanceOf(address(dispatcher)), dispatcherBalBefore - amount);
        assertEq(usdc.balanceOf(address(mockMessenger)), amount);
    }

    function test_cctp_bridge_callsDepositForBurnWithCorrectParams() public {
        uint256 amount = 50e6;

        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        usdc.mint(address(dispatcher), amount);

        vm.expectCall(
            address(mockMessenger),
            abi.encodeCall(ICCTPTokenMessenger.depositForBurn, (
                amount,
                DEST_DOMAIN_ETHEREUM,
                bytes32(uint256(uint160(alice))),
                address(usdc),
                bytes32(0),
                0,
                2000
            ))
        );

        vm.prank(bridger);
        dispatcher.bridge(address(usdc), amount, 0);
    }

    function test_cctp_bridge_drainsFullBalance() public {
        uint256 amount = 1000e6;

        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        usdc.mint(address(dispatcher), amount);

        vm.prank(bridger);
        dispatcher.bridge(address(usdc), amount, 0);

        assertEq(usdc.balanceOf(address(dispatcher)), 0);
    }

    function test_cctp_bridge_worksWithCustomMaxFeeAndFinality() public {
        // Reconfigure with non-zero maxFee (fast transfer)
        vm.prank(owner);
        dispatcher.setCCTPConfig(address(mockMessenger), DEST_DOMAIN_ETHEREUM, 500, 1000);

        uint256 amount = 100e6;

        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        usdc.mint(address(dispatcher), amount);

        vm.expectCall(
            address(mockMessenger),
            abi.encodeCall(ICCTPTokenMessenger.depositForBurn, (
                amount,
                DEST_DOMAIN_ETHEREUM,
                bytes32(uint256(uint160(alice))),
                address(usdc),
                bytes32(0),
                500,
                1000
            ))
        );

        vm.prank(bridger);
        dispatcher.bridge(address(usdc), amount, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  BRIDGE VIA CCTP — REVERTS
    // ═══════════════════════════════════════════════════════════════

    function test_cctp_bridge_reverts_whenInsufficientBalance() public {
        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        dispatcher.bridge(address(usdc), 100e6, 0);
    }

    function test_cctp_bridge_reverts_whenCCTPConfigNotSet() public {
        // Deploy a fresh dispatcher without CCTP config
        vm.startPrank(owner);

        address dispImpl2 = address(new SettlementDispatcherV2(BinSponsor.Rain, dataProvider));
        address[] memory emptyTokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory emptyDest = new SettlementDispatcherV2.DestinationData[](0);

        SettlementDispatcherV2 dispatcher2 = SettlementDispatcherV2(payable(address(new UUPSProxy(
            dispImpl2, abi.encodeWithSelector(SettlementDispatcherV2.initialize.selector, address(roleRegistry), emptyTokens, emptyDest)
        ))));

        // Set CCTP destination but don't configure CCTP messenger
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: alice,
            stargate: address(0),
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: false,
            remoteToken: address(0),
            useCCTP: true
        });
        dispatcher2.setDestinationData(tokens, destDatas);

        usdc.mint(address(dispatcher2), 100e6);

        // bridger already has the role from setUp (same roleRegistry)
        vm.stopPrank();

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.CCTPConfigNotSet.selector);
        dispatcher2.bridge(address(usdc), 100e6, 0);
    }

    function test_cctp_bridge_reverts_whenNotBridger() public {
        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        usdc.mint(address(dispatcher), 100e6);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        dispatcher.bridge(address(usdc), 100e6, 0);
    }

    function test_cctp_bridge_reverts_whenDestinationDataNotSet() public {
        usdc.mint(address(dispatcher), 100e6);

        vm.prank(bridger);
        vm.expectRevert(SettlementDispatcherV2.DestinationDataNotSet.selector);
        dispatcher.bridge(address(usdc), 100e6, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  DESTINATION DATA — CCTP VALIDATION
    // ═══════════════════════════════════════════════════════════════

    function test_cctp_setDestinationData_succeeds() public {
        vm.prank(owner);
        _setCCTPDestination(address(usdc), alice);

        SettlementDispatcherV2.DestinationData memory dest = dispatcher.destinationData(address(usdc));
        assertEq(dest.destRecipient, alice);
        assertTrue(dest.useCCTP);
        assertFalse(dest.useCanonicalBridge);
        assertEq(dest.stargate, address(0));
    }

    function test_cctp_setDestinationData_reverts_whenStargateAlsoSet() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: alice,
            stargate: makeAddr("stargate"),
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: false,
            remoteToken: address(0),
            useCCTP: true
        });

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.setDestinationData(tokens, destDatas);
    }

    function test_cctp_setDestinationData_reverts_whenCanonicalBridgeAlsoSet() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: alice,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 200_000,
            isOFT: false,
            remoteToken: address(0),
            useCCTP: true
        });

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        dispatcher.setDestinationData(tokens, destDatas);
    }
}
