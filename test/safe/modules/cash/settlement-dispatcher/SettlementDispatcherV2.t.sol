// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";
import { IFraxCustodian } from "../../../../../src/interfaces/IFraxCustodian.sol";
import { IFraxRemoteHop } from "../../../../../src/interfaces/IFraxRemoteHop.sol";
import { IOFT, MessagingFee, SendParam } from "../../../../../src/interfaces/IOFT.sol";
import { Constants } from "../../../../../src/utils/Constants.sol";
import { IMidasVault } from "../../../../../src/interfaces/IMidasVault.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";

/**
 * @notice Mock Frax custodian: pulls fraxUsd from owner, sends usdc to receiver. Returns configurable amountOut.
 */
contract MockFraxCustodian is IFraxCustodian {
    IERC20 public immutable fraxUsd;
    IERC20 public immutable usdc;
    uint256 public amountOutToReturn;

    constructor(address _fraxUsd, address _usdc) {
        fraxUsd = IERC20(_fraxUsd);
        usdc = IERC20(_usdc);
    }

    function setAmountOutToReturn(uint256 _amountOutToReturn) external {
        amountOutToReturn = _amountOutToReturn;
    }

    function deposit(uint256, address) external payable returns (uint256) {
        revert("MockFraxCustodian: deposit not used in tests");
    }

    function redeem(uint256 sharesIn, address reciever, address owner) external returns (uint256 amountOut) {
        fraxUsd.transferFrom(owner, address(this), sharesIn);
        usdc.transfer(reciever, amountOutToReturn);
        return amountOutToReturn;
    }
}

/**
 * @notice Mock Midas vault: redeemRequest pulls midas token from msg.sender and sends tokenOut to recipient.
 * In production the vault would process the request asynchronously and send to recipient when ready.
 */
contract MockMidasVault is IMidasVault {
    IERC20 public immutable midasToken;

    constructor(address _midasToken) {
        midasToken = IERC20(_midasToken);
    }

    function depositInstant(address, uint256, uint256, bytes32) external pure override {
        revert("MockMidasVault: depositInstant not used");
    }

    function redeemInstant(address, uint256, uint256) external pure override {
        revert("MockMidasVault: use redeemRequest in tests");
    }

    function redeemRequest(address tokenOut, uint256 amountMTokenIn, address recipient) external override returns (uint256) {
        midasToken.transferFrom(msg.sender, address(this), amountMTokenIn);
        IERC20(tokenOut).transfer(recipient, amountMTokenIn);
        return 1;
    }
}

/**
 * @notice Mock Frax RemoteHop: simulates LayerZero OFT bridging by pulling tokens and returning a fixed fee.
 */
contract MockFraxRemoteHop is IFraxRemoteHop {
    uint256 public nativeFeeToReturn;

    function setNativeFeeToReturn(uint256 _fee) external {
        nativeFeeToReturn = _fee;
    }

    function sendOFT(address _oft, uint32, bytes32, uint256 _amountLD) external payable override {
        IERC20(_oft).transferFrom(msg.sender, address(this), _amountLD);
    }

    function quote(address, uint32, bytes32, uint256) external view override returns (MessagingFee memory fee) {
        return MessagingFee({ nativeFee: nativeFeeToReturn, lzTokenFee: 0 });
    }
}

contract SettlementDispatcherV2Test is CashModuleTestSetup {
    address alice = makeAddr("alice");
    SettlementDispatcherV2 v2;

    address constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    uint32 constant ETHEREUM_EID = 30101;


    function setUp() public override {
        super.setUp();

        // Upgrade to V2
        address settlementDispatcherV2Impl = address(new SettlementDispatcherV2(BinSponsor.Reap, address(dataProvider)));
        vm.prank(owner);
        UUPSUpgradeable(address(settlementDispatcherReap)).upgradeToAndCall(settlementDispatcherV2Impl, "");
        
        v2 = SettlementDispatcherV2(payable(address(settlementDispatcherReap)));

        address[] memory tokens = new address[](1);
        tokens[0] = EURC;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: ETHEREUM_EID,
            destRecipient: alice,
            stargate: EURC,
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: true,
            remoteToken: address(0),
            useCCTP: false
        });

        vm.prank(owner);
        v2.setDestinationData(tokens, destDatas);
    }

    function test_v2_setRefundWallet_succeeds() public {
        address newWallet = makeAddr("newWallet");
        
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.RefundWalletSet(newWallet);
        v2.setRefundWallet(newWallet);
        
        assertEq(v2.getRefundWallet(), newWallet);
    }

    function test_v2_getRefundWallet_fallsBackToDataProvider() public {
        assertEq(v2.getRefundWallet(), refundWallet);
        
        address customWallet = makeAddr("customWallet");
        vm.prank(owner);
        v2.setRefundWallet(customWallet);
        assertEq(v2.getRefundWallet(), customWallet);
        
        vm.prank(owner);
        v2.setRefundWallet(address(0));
        assertEq(v2.getRefundWallet(), refundWallet);
    }

    function test_v2_setRefundWallet_reverts_whenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        v2.setRefundWallet(makeAddr("newWallet"));
    }

    // --- Frax config and redeem tests ---

    function test_v2_redeemFraxToUsdc_succeeds() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodian = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        custodian.setAmountOutToReturn(100e6);

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodian), address(0), address(0));

        uint256 amount = 100e18;
        fraxUsdToken.mint(address(v2), amount);
        deal(address(usdcScroll), address(custodian), 100e6);

        uint256 usdcBefore = IERC20(usdcScroll).balanceOf(address(v2));
        uint256 fraxBefore = fraxUsdToken.balanceOf(address(v2));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.FraxRedeemed(amount, 100e6);
        v2.redeemFraxToUsdc(amount, 100e6);

        assertEq(fraxUsdToken.balanceOf(address(v2)), fraxBefore - amount);
        assertEq(IERC20(usdcScroll).balanceOf(address(v2)), usdcBefore + 100e6);
    }

    function test_v2_redeemFraxToUsdc_reverts_whenInsufficientReturnAmount() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodian = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        custodian.setAmountOutToReturn(50e6);

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodian), address(0), address(0));
        fraxUsdToken.mint(address(v2), 100e18);
        deal(address(usdcScroll), address(custodian), 100e6);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientReturnAmount.selector);
        v2.redeemFraxToUsdc(100e18, 100e6);
    }

    function test_v2_redeemFraxToUsdc_reverts_whenNotBridger() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodian = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodian), address(0), address(0));
        fraxUsdToken.mint(address(v2), 100e18);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        v2.redeemFraxToUsdc(100e18, 100e6);
    }

    // --- Midas config and redeem tests ---

    function test_v2_setMidasRedemptionVault_succeeds() public {
        MockERC20 midasToken = new MockERC20("Liquid Reserve", "LR", 6);
        MockMidasVault vault = new MockMidasVault(address(midasToken));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.MidasRedemptionVaultSet(address(midasToken), address(vault));
        v2.setMidasRedemptionVault(address(midasToken), address(vault));

        assertEq(v2.getMidasRedemptionVault(address(midasToken)), address(vault));
    }

    function test_v2_redeemMidasToAsset_succeeds() public {
        MockERC20 midasToken = new MockERC20("Liquid Reserve", "LR", 6);
        MockMidasVault vault = new MockMidasVault(address(midasToken));

        vm.prank(owner);
        v2.setMidasRedemptionVault(address(midasToken), address(vault));

        uint256 amount = 100e6;
        midasToken.mint(address(v2), amount);
        deal(address(usdcScroll), address(vault), amount);

        uint256 usdcBefore = IERC20(usdcScroll).balanceOf(address(v2));
        uint256 midasBefore = midasToken.balanceOf(address(v2));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.MidasRedeemed(address(midasToken), address(usdcScroll), amount, amount);
        v2.redeemMidasToAsset(address(midasToken), address(usdcScroll), amount, amount);

        assertEq(midasToken.balanceOf(address(v2)), midasBefore - amount);
        assertEq(IERC20(usdcScroll).balanceOf(address(v2)), usdcBefore + amount);
    }

    function test_v2_redeemMidasToAsset_reverts_whenVaultNotSet() public {
        MockERC20 midasToken = new MockERC20("Liquid Reserve", "LR", 6);
        midasToken.mint(address(v2), 100e6);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.MidasRedemptionVaultNotSet.selector);
        v2.redeemMidasToAsset(address(midasToken), address(usdcScroll), 100e6, 100e6);
    }

    function test_v2_redeemMidasToAsset_reverts_whenNotBridger() public {
        MockERC20 midasToken = new MockERC20("Liquid Reserve", "LR", 6);
        MockMidasVault vault = new MockMidasVault(address(midasToken));
        vm.prank(owner);
        v2.setMidasRedemptionVault(address(midasToken), address(vault));
        midasToken.mint(address(v2), 100e6);
        deal(address(usdcScroll), address(vault), 100e6);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        v2.redeemMidasToAsset(address(midasToken), address(usdcScroll), 100e6, 100e6);
    }

    // --- Frax async redeem tests ---

    function test_v2_setFraxConfig_withRemoteHop_succeeds() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();
        address recipient = makeAddr("ethRecipient");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.FraxConfigSet(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), recipient);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), recipient);

        (address fraxUsd_, address fraxCustodian_, address fraxRemoteHop_, address fraxAsyncRedeemRecipient_) = v2.getFraxConfig();
        assertEq(fraxUsd_, address(fraxUsdToken));
        assertEq(fraxCustodian_, address(custodianMock));
        assertEq(fraxRemoteHop_, address(remoteHopMock));
        assertEq(fraxAsyncRedeemRecipient_, recipient);
    }

    function test_v2_redeemFraxAsync_succeeds() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();
        remoteHopMock.setNativeFeeToReturn(0.01 ether);
        address recipient = makeAddr("ethRecipient");

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), recipient);

        uint256 amount = 100e18;
        fraxUsdToken.mint(address(v2), amount);
        vm.deal(address(v2), 1 ether);

        uint256 fraxBefore = fraxUsdToken.balanceOf(address(v2));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.FraxAsyncRedeemed(amount, recipient);
        v2.redeemFraxAsync(amount);

        assertEq(fraxUsdToken.balanceOf(address(v2)), fraxBefore - amount);
        assertEq(fraxUsdToken.balanceOf(address(remoteHopMock)), amount);
    }

    function test_v2_redeemFraxAsync_reverts_whenRemoteHopNotSet() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(0), makeAddr("recipient"));

        fraxUsdToken.mint(address(v2), 100e18);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.FraxConfigNotSet.selector);
        v2.redeemFraxAsync(100e18);
    }

    function test_v2_redeemFraxAsync_reverts_whenAmountContainsDust() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), makeAddr("recipient"));

        uint256 dustyAmount = 100e18 + 1; // not a multiple of 1e12
        fraxUsdToken.mint(address(v2), dustyAmount);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.AmountContainsDust.selector);
        v2.redeemFraxAsync(dustyAmount);
    }

    function test_v2_redeemFraxAsync_reverts_whenInsufficientBalance() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), makeAddr("recipient"));

        // Don't mint any tokens to v2

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        v2.redeemFraxAsync(100e18);
    }

    function test_v2_redeemFraxAsync_reverts_whenInsufficientNativeFee() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();
        remoteHopMock.setNativeFeeToReturn(1 ether);

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), makeAddr("recipient"));

        fraxUsdToken.mint(address(v2), 100e18);
        // Don't provide ETH to v2

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientNativeFee.selector);
        v2.redeemFraxAsync(100e18);
    }

    function test_v2_redeemFraxAsync_reverts_whenNotBridger() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), makeAddr("recipient"));
        fraxUsdToken.mint(address(v2), 100e18);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        v2.redeemFraxAsync(100e18);
    }

    function test_v2_redeemFraxAsync_reverts_whenInvalidValue() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), makeAddr("recipient"));
        fraxUsdToken.mint(address(v2), 100e18);

        // zero amount
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        v2.redeemFraxAsync(0);
    }

    function test_v2_redeemFraxAsync_reverts_whenRecipientNotSet() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), address(0));
        fraxUsdToken.mint(address(v2), 100e18);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.FraxConfigNotSet.selector);
        v2.redeemFraxAsync(100e18);
    }

    function test_v2_quoteAsyncFraxRedeem_succeeds() public {
        MockERC20 fraxUsdToken = new MockERC20("Frax USD", "FRAX", 18);
        MockFraxCustodian custodianMock = new MockFraxCustodian(address(fraxUsdToken), address(usdcScroll));
        MockFraxRemoteHop remoteHopMock = new MockFraxRemoteHop();
        remoteHopMock.setNativeFeeToReturn(0.05 ether);

        vm.prank(owner);
        v2.setFraxConfig(address(fraxUsdToken), address(custodianMock), address(remoteHopMock), makeAddr("recipient"));

        MessagingFee memory fee = v2.quoteAsyncFraxRedeem(100e18);
        assertEq(fee.nativeFee, 0.05 ether);
        assertEq(fee.lzTokenFee, 0);
    }


    function test_v2_prepareOftSend_succeeds() public view {
        uint256 amount = 100e6;
        (address oft, uint256 valueToSend, uint256 minReturn, SendParam memory sendParam, MessagingFee memory messagingFee) = v2.prepareOftSend(EURC, amount);

        assertEq(oft, EURC);
        assertGt(valueToSend, 0);
        assertGt(minReturn, 0);
        assertLe(minReturn, amount);
        assertEq(sendParam.dstEid, ETHEREUM_EID);
        assertEq(sendParam.amountLD, amount);
        assertGt(messagingFee.nativeFee, 0);
    }
    
    function test_v2_bridge_succeeds_withOFT() public {
        uint256 amount = 100e6;
        deal(EURC, address(v2), amount);

        (, uint256 valueToSend, , ,) = v2.prepareOftSend(EURC, amount);
        vm.deal(address(v2), valueToSend);

        uint256 eurcBalBefore = IERC20(EURC).balanceOf(address(v2));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.FundsBridgedWithOFT(EURC, amount);
        v2.bridge{value: 0}(EURC, amount, 1);

        assertEq(IERC20(EURC).balanceOf(address(v2)), eurcBalBefore - amount);
    }

    function test_v2_bridge_reverts_withOFT_whenInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        v2.bridge(EURC, 100e6, 1);
    }

    function test_v2_bridge_reverts_withOFT_whenInsufficientFee() public {
        uint256 amount = 100e6;
        deal(EURC, address(v2), amount);
        // Don't provide ETH for fees

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientFeeToCoverCost.selector);
        v2.bridge(EURC, amount, 1);
    }

    function test_v2_bridge_reverts_withOFT_whenMinReturnTooHigh() public {
        uint256 amount = 100e6;
        deal(EURC, address(v2), amount);

        (, uint256 valueToSend, uint256 minReturnFromOft, ,) = v2.prepareOftSend(EURC, amount);
        vm.deal(address(v2), valueToSend);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientMinReturn.selector);
        v2.bridge{value: 0}(EURC, amount, minReturnFromOft + 1);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  SETTLE (SAME-CHAIN TRANSFER)
    // ═══════════════════════════════════════════════════════════════

    function _setRecipient(address token, address recipient) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        address[] memory r = new address[](1);
        r[0] = recipient;
        v2.setSettlementRecipients(t, r);
    }

    function test_v2_settle_succeeds() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        address recipient = makeAddr("settleRecipient");

        vm.prank(owner);
        _setRecipient(address(token), recipient);

        token.mint(address(v2), 1000e6);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.FundsSettled(address(token), recipient, 500e6);
        v2.settle(address(token), 500e6);

        assertEq(token.balanceOf(recipient), 500e6);
        assertEq(token.balanceOf(address(v2)), 500e6);
    }

    function test_v2_settle_differentRecipientsPerToken() public {
        MockERC20 tokenA = new MockERC20("USDC", "USDC", 6);
        MockERC20 tokenB = new MockERC20("USDT", "USDT", 6);
        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");

        vm.startPrank(owner);
        _setRecipient(address(tokenA), recipientA);
        _setRecipient(address(tokenB), recipientB);
        vm.stopPrank();

        tokenA.mint(address(v2), 1000e6);
        tokenB.mint(address(v2), 500e6);

        vm.startPrank(owner);
        v2.settle(address(tokenA), 1000e6);
        v2.settle(address(tokenB), 500e6);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(recipientA), 1000e6);
        assertEq(tokenB.balanceOf(recipientB), 500e6);
    }

    function test_v2_settle_reverts_whenRecipientNotSet() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        token.mint(address(v2), 100e6);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.SettlementRecipientNotSet.selector);
        v2.settle(address(token), 100e6);
    }

    function test_v2_settle_reverts_whenInsufficientBalance() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        vm.prank(owner);
        _setRecipient(address(token), alice);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InsufficientBalance.selector);
        v2.settle(address(token), 100e6);
    }

    function test_v2_settle_reverts_whenNotBridger() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        vm.prank(owner);
        _setRecipient(address(token), alice);
        token.mint(address(v2), 100e6);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        v2.settle(address(token), 100e6);
    }

    function test_v2_settle_reverts_whenZeroAmount() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        vm.prank(owner);
        _setRecipient(address(token), alice);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        v2.settle(address(token), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  ADMIN: SETTLEMENT RECIPIENT
    // ═══════════════════════════════════════════════════════════════

    function test_v2_setSettlementRecipient_succeeds() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.SettlementRecipientSet(address(token), alice);
        _setRecipient(address(token), alice);

        assertEq(v2.getSettlementRecipient(address(token)), alice);
    }

    function test_v2_setSettlementRecipient_reverts_whenNotOwner() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        _setRecipient(address(token), alice);
    }

    function test_v2_setSettlementRecipient_reverts_whenZeroAddress() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcherV2.InvalidValue.selector);
        _setRecipient(address(token), address(0));
    }
}

