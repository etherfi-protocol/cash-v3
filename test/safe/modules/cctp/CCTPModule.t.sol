// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";

import { CCTPModule } from "../../../../src/modules/cctp/CCTPModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { ICCTPTokenMessenger } from "../../../../src/interfaces/ICCTPTokenMessenger.sol";
import { ICCTPTokenMinter } from "../../../../src/interfaces/ICCTPTokenMinter.sol";
import { ICashModule, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";

/// @dev Mock TokenMessenger + Minter. Default burn cap = uint256.max.
contract MockTokenMessenger is ICCTPTokenMessenger, ICCTPTokenMinter {
    struct Call {
        uint256 amount;
        uint32 destDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }
    Call public last;
    uint256 public calls;
    mapping(address => uint256) public limits;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        // pull tokens to simulate burn
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        last = Call(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold);
        calls++;
    }

    function localMinter() external view returns (address) {
        return address(this);
    }

    function burnLimitsPerMessage(address token) external view returns (uint256) {
        uint256 l = limits[token];
        return l == 0 ? type(uint256).max : l;
    }

    function setBurnLimit(address token, uint256 limit) external {
        limits[token] = limit;
    }
}

contract CCTPModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    CCTPModule cctpModule;
    MockTokenMessenger messenger;

    uint32 destDomain = 6;
    uint32 cfgFinality = 1000;
    uint256 cfgMaxFeeBps = 5;
    bytes32 destRecipient = bytes32(uint256(uint160(makeAddr("destRecipient"))));

    function _expectedMaxFee(uint256 amount) internal view returns (uint256) {
        return (amount * cfgMaxFeeBps) / cctpModule.MAX_BPS();
    }

    function setUp() public override {
        super.setUp();

        messenger = new MockTokenMessenger();

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), maxFeeBps: cfgMaxFeeBps, providerFeeBps: 0 });

        cctpModule = new CCTPModule(assets, cfgs, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(cctpModule);
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(modules, yes);
        cashModule.configureModulesCanRequestWithdraw(modules, yes);
        vm.stopPrank();

        bytes[] memory setupData = new bytes[](1);
        _configureModules(modules, yes, setupData);

        bytes32 adminRole = cctpModule.CCTP_MODULE_ADMIN_ROLE();
        uint32[] memory doms = new uint32[](1);
        doms[0] = destDomain;
        bool[] memory ok = new bool[](1);
        ok[0] = true;
        vm.startPrank(owner);
        roleRegistry.grantRole(adminRole, owner);
        cctpModule.setAllowedRoutes(address(usdc), doms, ok);
        vm.stopPrank();
    }

    // ───────────────────────── helpers ─────────────────────────

    function _params(uint256 amount) internal view returns (CCTPModule.BridgeParams memory) {
        return CCTPModule.BridgeParams({
            destDomain: destDomain,
            asset: address(usdc),
            amount: amount,
            destRecipient: destRecipient,
            finalityThreshold: cfgFinality
        });
    }

    function _sign(CCTPModule.BridgeParams memory p) internal view returns (address[] memory signers, bytes[] memory signatures) {
        bytes32 digest = keccak256(abi.encodePacked(
            cctpModule.REQUEST_BRIDGE_SIG(),
            block.chainid,
            address(cctpModule),
            safe.nonce(),
            address(safe),
            abi.encode(p)
        )).toEthSignedMessageHash();

        signers = new address[](2);
        signers[0] = owner1; signers[1] = owner2;
        signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
    }

    function _signOne(CCTPModule.BridgeParams memory p) internal view returns (address[] memory signers, bytes[] memory signatures) {
        bytes32 digest = keccak256(abi.encodePacked(
            cctpModule.REQUEST_BRIDGE_SIG(),
            block.chainid,
            address(cctpModule),
            safe.nonce(),
            address(safe),
            abi.encode(p)
        )).toEthSignedMessageHash();
        signers = new address[](1);
        signers[0] = owner1;
        signatures = new bytes[](1);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        signatures[0] = abi.encodePacked(r1, s1, v1);
    }

    function _signCancel() internal view returns (address[] memory signers, bytes[] memory signatures) {
        bytes32 digest = keccak256(abi.encodePacked(
            cctpModule.CANCEL_BRIDGE_SIG(),
            block.chainid,
            address(cctpModule),
            safe.nonce(),
            address(safe)
        )).toEthSignedMessageHash();
        signers = new address[](2);
        signers[0] = owner1; signers[1] = owner2;
        signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
    }

    function _assertBridgeCancelledOnce(uint256 expectedAmount, bytes32 expectedRecipient) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 cancelSig = keccak256("BridgeCancelled(address,uint32,address,uint256,bytes32)");
        uint256 cancelCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(cctpModule) && logs[i].topics[0] == cancelSig) {
                cancelCount++;
                (uint256 emittedAmount, bytes32 emittedRecipient) = abi.decode(logs[i].data, (uint256, bytes32));
                assertEq(emittedAmount, expectedAmount);
                assertEq(emittedRecipient, expectedRecipient);
            }
        }
        assertEq(cancelCount, 1);
    }

    // ───────────────────────── config ─────────────────────────

    function test_setAllowedRoutes_nonAdminReverts() public {
        uint32[] memory doms = new uint32[](1);
        doms[0] = 42;
        bool[] memory ok = new bool[](1);
        ok[0] = true;
        vm.expectRevert(CCTPModule.Unauthorized.selector);
        cctpModule.setAllowedRoutes(address(usdc), doms, ok);
    }

    function test_requestBridge_invalidFinalityThresholdReverts() public {
        deal(address(usdc), address(safe), 100e6);
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.finalityThreshold = 1234;
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        vm.expectRevert(CCTPModule.InvalidFinalityThreshold.selector);
        cctpModule.requestBridge(address(safe), p, s, sigs);
    }

    function test_requestBridge_standardModeForcesZeroFee() public {
        deal(address(usdc), address(safe), 100e6);
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.finalityThreshold = 2000; // Standard: cctp maxFee forced to 0 regardless of admin ceiling
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        CCTPModule.CrossChainWithdrawal memory w = cctpModule.getPendingBridge(address(safe));
        assertEq(w.maxFee, 0);
        assertEq(w.minFinalityThreshold, 2000);
    }

    function test_setAssetConfig_maxFeeBpsTooHighReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), maxFeeBps: 10_000, providerFeeBps: 0 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.MaxFeeBpsTooHigh.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_getBridgeFee_returnsConfiguredFee() public view {
        (address feeToken, uint256 providerFee, uint256 cctpMaxFee) = cctpModule.getBridgeFee(address(usdc), 100e6, cfgFinality);
        assertEq(feeToken, address(usdc));
        assertEq(providerFee, 0);
        assertEq(cctpMaxFee, _expectedMaxFee(100e6));

        (, , uint256 stdFee) = cctpModule.getBridgeFee(address(usdc), 100e6, 2000);
        assertEq(stdFee, 0);
    }

    function _configureproviderFee(uint256 bps, address recipient) internal {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), maxFeeBps: cfgMaxFeeBps, providerFeeBps: bps });
        vm.startPrank(owner);
        cctpModule.setAssetConfig(assets, cfgs);
        cctpModule.setproviderFeeRecipient(recipient);
        vm.stopPrank();
    }

    function test_providerFee_chargedAndBurnReduced() public {
        address feeRecipient = makeAddr("etherFiTreasury");
        _configureproviderFee(50, feeRecipient); // 0.5%

        uint256 amount = 100e6;
        uint256 expectedFee = (amount * 50) / 10_000;
        uint256 expectedBurn = amount - expectedFee;

        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);

        vm.expectEmit(true, true, false, true, address(cctpModule));
        emit CCTPModule.providerFeeCharged(address(safe), address(usdc), expectedFee, feeRecipient);
        cctpModule.executeBridge(address(safe));

        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
        (uint256 burned,,,,,,) = messenger.last();
        assertEq(burned, expectedBurn);
    }

    function test_providerFee_requiresRecipientWhenBpsNonZero() public {
        _configureproviderFee(50, address(0)); // fee configured but no recipient

        deal(address(usdc), address(safe), 100e6);
        CCTPModule.BridgeParams memory p = _params(100e6);
        // pre-sign; we shouldn't get past the recipient check inside _buildWithdrawal
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        vm.expectRevert(CCTPModule.providerFeeRecipientNotSet.selector);
        cctpModule.requestBridge(address(safe), p, s, sigs);
    }

    function test_setproviderFeeRecipient_nonAdminReverts() public {
        vm.expectRevert(CCTPModule.Unauthorized.selector);
        cctpModule.setproviderFeeRecipient(address(1));
    }

    function test_providerFee_queuedMaxFeeUsesBurnAmount() public {
        _configureproviderFee(50, makeAddr("t")); // 0.5% service fee
        uint256 amount = 1_000e6;
        uint256 fee = (amount * 50) / 10_000;
        uint256 burn = amount - fee;

        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        CCTPModule.CrossChainWithdrawal memory w = cctpModule.getPendingBridge(address(safe));
        assertEq(w.providerFee, fee);
        assertEq(w.maxFee, (burn * cfgMaxFeeBps) / 10_000);
    }

    function test_providerFee_recipientSnapshottedAtRequest() public {
        address original = makeAddr("originalTreasury");
        address rotated = makeAddr("rotatedTreasury");
        _configureproviderFee(50, original);

        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        // Admin rotates recipient AFTER queueing; snapshot should still send to original.
        vm.prank(owner);
        cctpModule.setproviderFeeRecipient(rotated);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        uint256 expectedFee = (amount * 50) / 10_000;
        assertEq(usdc.balanceOf(original), expectedFee);
        assertEq(usdc.balanceOf(rotated), 0);
    }

    function test_requestBridge_nonceReplayReverts() public {
        deal(address(usdc), address(safe), 200e6);
        CCTPModule.BridgeParams memory p = _params(100e6);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        // Cancel to clear the pending withdrawal so we can attempt a fresh requestBridge.
        (address[] memory cs, bytes[] memory csigs) = _signCancel();
        cctpModule.cancelBridge(address(safe), cs, csigs);

        // Replay the ORIGINAL signatures — safe nonce has advanced twice, digest no longer matches.
        vm.expectRevert(CCTPModule.InvalidSignatures.selector);
        cctpModule.requestBridge(address(safe), p, s, sigs);
    }

    function test_storageSlot_notEqualToStargate() public pure {
        bytes32 stargate = 0xeafa2356b7fab3fae77872025a25cb67884d7667f22b14ae60e3f63732a39c00;
        bytes32 cctp = 0x8acda1cfca4f5cfd72da8b3438a383a2a5be2d370022c8dfe2b3e8c2690b2e00;
        assertTrue(stargate != cctp);
    }

    function test_getBridgeFee_withproviderFee() public {
        _configureproviderFee(50, makeAddr("t")); // 0.5% service fee
        uint256 amount = 1_000e6;
        (address feeToken, uint256 providerFee, uint256 cctpMaxFee) = cctpModule.getBridgeFee(address(usdc), amount, cfgFinality);
        assertEq(feeToken, address(usdc));
        assertEq(providerFee, (amount * 50) / 10_000);
        // CCTP maxFee should be on burn amount, not gross
        assertEq(cctpMaxFee, ((amount - providerFee) * cfgMaxFeeBps) / 10_000);
    }

    function test_cancelBridge_badSignatureReverts() public {
        deal(address(usdc), address(safe), 100e6);
        CCTPModule.BridgeParams memory p = _params(100e6);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        // Pass the request signatures where cancel signatures are expected.
        vm.expectRevert(CCTPModule.InvalidSignatures.selector);
        cctpModule.cancelBridge(address(safe), s, sigs);
    }

    function test_cancelBridge_noQueueReverts() public {
        (address[] memory s, bytes[] memory sigs) = _signCancel();
        vm.expectRevert(CCTPModule.NoWithdrawalQueuedForCCTP.selector);
        cctpModule.cancelBridge(address(safe), s, sigs);
    }

    function test_setAssetConfig_invalidTokenMessengerReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(0x1), maxFeeBps: cfgMaxFeeBps, providerFeeBps: 0 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.InvalidTokenMessenger.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_setAssetConfig_providerFeeBpsTooHighReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), maxFeeBps: 0, providerFeeBps: 10_000 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.providerFeeBpsTooHigh.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_setAssetConfig_validatesBpsOnRemoval() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(0), maxFeeBps: 10_000, providerFeeBps: 0 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.MaxFeeBpsTooHigh.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_getproviderFee_revertsUnsupportedAsset() public {
        vm.expectRevert(CCTPModule.UnsupportedAsset.selector);
        cctpModule.getproviderFee(makeAddr("random"), 100e6);
    }

    function test_getBridgeFee_revertsUnsupportedAsset() public {
        vm.expectRevert(CCTPModule.UnsupportedAsset.selector);
        cctpModule.getBridgeFee(makeAddr("random"), 100e6, cfgFinality);
    }

    // ───────────────────────── request validation ─────────────────────────

    function test_requestBridge_unsupportedRouteReverts() public {
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.destDomain = 999;
        vm.expectRevert(CCTPModule.UnsupportedRoute.selector);
        cctpModule.requestBridge(address(safe), p, new address[](0), new bytes[](0));
    }

    function test_requestBridge_revertsWhenRouteAllowedForOtherAssetOnly() public {
        // Configure a second asset with the SAME token messenger, allow it on `destDomain`,
        // but do NOT allow USDC on `destDomain` via setAllowedRoutes for a fresh domain.
        address otherAsset = address(usdt);
        address[] memory assets = new address[](1);
        assets[0] = otherAsset;
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), maxFeeBps: 5, providerFeeBps: 0 });
        vm.startPrank(owner);
        cctpModule.setAssetConfig(assets, cfgs);
        uint32[] memory doms = new uint32[](1);
        doms[0] = 42;
        bool[] memory ok = new bool[](1);
        ok[0] = true;
        cctpModule.setAllowedRoutes(otherAsset, doms, ok);
        vm.stopPrank();

        assertTrue(cctpModule.isRouteAllowed(otherAsset, 42));
        assertFalse(cctpModule.isRouteAllowed(address(usdc), 42));

        CCTPModule.BridgeParams memory p = _params(100e6);
        p.destDomain = 42;
        vm.expectRevert(CCTPModule.UnsupportedRoute.selector);
        cctpModule.requestBridge(address(safe), p, new address[](0), new bytes[](0));
    }

    function test_executeBridge_revertsIfCctpLimitTightenedAfterRequest() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        messenger.setBurnLimit(address(usdc), amount - 1);
        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);

        vm.expectRevert(abi.encodeWithSelector(CCTPModule.BurnExceedsCctpLimit.selector, amount, amount - 1));
        cctpModule.executeBridge(address(safe));
    }

    function test_requestBridge_acceptsNonEvmRecipient() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        bytes32 solanaRecipient = keccak256("some-solana-pubkey");
        CCTPModule.BridgeParams memory p = _params(amount);
        p.destRecipient = solanaRecipient;
        (address[] memory s, bytes[] memory sigs) = _sign(p);

        cctpModule.requestBridge(address(safe), p, s, sigs);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        (, , bytes32 r, , , , ) = messenger.last();
        assertEq(r, solanaRecipient);
    }

    function test_setAllowedRoutes_zeroAssetReverts() public {
        uint32[] memory doms = new uint32[](1);
        doms[0] = 1;
        bool[] memory ok = new bool[](1);
        ok[0] = true;
        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        cctpModule.setAllowedRoutes(address(0), doms, ok);
    }

    function test_requestBridge_invalidInputReverts() public {
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.destRecipient = bytes32(0);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        cctpModule.requestBridge(address(safe), p, new address[](0), new bytes[](0));

        p = _params(0);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        cctpModule.requestBridge(address(safe), p, new address[](0), new bytes[](0));
    }

    function test_requestBridge_unsupportedAsset() public {
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.asset = address(weETH);
        vm.expectRevert(CCTPModule.UnsupportedAsset.selector);
        cctpModule.requestBridge(address(safe), p, new address[](0), new bytes[](0));
    }

    function test_requestBridge_badSignatureReverts() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        // sign a different amount, then call with the right one
        CCTPModule.BridgeParams memory other = _params(amount + 1);
        (address[] memory s, bytes[] memory sigs) = _sign(other);

        vm.expectRevert(CCTPModule.InvalidSignatures.selector);
        cctpModule.requestBridge(address(safe), p, s, sigs);
    }

    function test_requestBridge_insufficientQuorumReverts() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _signOne(p); // only 1 of 2

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        cctpModule.requestBridge(address(safe), p, s, sigs);
    }

    // ───────────────────────── request / execute ─────────────────────────

    /// @notice A second requestBridge replaces the pending bridge via CashModule's cancel hook.
    function test_requestBridge_replacesPendingBridge() public {
        uint256 firstAmount = 100e6;
        uint256 secondAmount = 80e6;
        bytes32 newRecipient = bytes32(uint256(uint160(makeAddr("newDestRecipient"))));

        deal(address(usdc), address(safe), firstAmount);

        CCTPModule.BridgeParams memory first = _params(firstAmount);
        (address[] memory s1, bytes[] memory sigs1) = _sign(first);
        cctpModule.requestBridge(address(safe), first, s1, sigs1);

        CCTPModule.BridgeParams memory second = _params(secondAmount);
        second.destRecipient = newRecipient;
        (address[] memory s2, bytes[] memory sigs2) = _sign(second);
        vm.recordLogs();
        cctpModule.requestBridge(address(safe), second, s2, sigs2);
        _assertBridgeCancelledOnce(firstAmount, destRecipient);

        WithdrawalRequest memory wr = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(wr.tokens[0], address(usdc));
        assertEq(wr.amounts[0], secondAmount);
        assertEq(wr.recipient, address(cctpModule));

        CCTPModule.CrossChainWithdrawal memory w = cctpModule.getPendingBridge(address(safe));
        assertEq(w.amount, secondAmount);
        assertEq(w.destRecipient, newRecipient);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        assertEq(messenger.calls(), 1);
        (uint256 burned, , bytes32 mintRecipient, , , , ) = messenger.last();
        assertEq(burned, secondAmount);
        assertEq(mintRecipient, newRecipient);
        assertEq(usdc.balanceOf(address(messenger)), secondAmount);
    }

    function test_requestBridge_queuesWithdrawal() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);

        cctpModule.requestBridge(address(safe), p, s, sigs);

        WithdrawalRequest memory wr = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(wr.tokens[0], address(usdc));
        assertEq(wr.amounts[0], amount);
        assertEq(wr.recipient, address(cctpModule));

        CCTPModule.CrossChainWithdrawal memory w = cctpModule.getPendingBridge(address(safe));
        assertEq(w.destDomain, destDomain);
        assertEq(w.asset, address(usdc));
        assertEq(w.amount, amount);
        assertEq(w.destRecipient, destRecipient);
        // snapshot of admin config
        assertEq(w.tokenMessenger, address(messenger));
        assertEq(w.maxFee, _expectedMaxFee(amount));
        assertEq(w.minFinalityThreshold, cfgFinality);
    }

    function test_requestBridge_tinyAmountFeeRoundsToZero() public {
        // amount * 5bps / 10000 rounds down to 0 for small amounts -> allowed, queued maxFee == 0.
        uint256 amount = 1;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);

        cctpModule.requestBridge(address(safe), p, s, sigs);

        CCTPModule.CrossChainWithdrawal memory w = cctpModule.getPendingBridge(address(safe));
        assertEq(w.amount, amount);
        assertEq(w.maxFee, 0);
        assertEq(_expectedMaxFee(amount), 0);
    }

    function test_requestBridge_executesImmediatelyWhenDelayZero() public {
        vm.prank(owner);
        cashModule.setDelays(0, 0, 0);

        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);

        cctpModule.requestBridge(address(safe), p, s, sigs);

        assertEq(messenger.calls(), 1);
        (uint256 a, uint32 d, bytes32 r, address t, bytes32 dc, uint256 mf, uint32 mft) = messenger.last();
        assertEq(a, amount);
        assertEq(d, destDomain);
        assertEq(r, destRecipient);
        assertEq(t, address(usdc));
        assertEq(dc, bytes32(0));
        assertEq(mf, _expectedMaxFee(amount));
        assertEq(mft, cfgFinality);
    }

    function test_requestBridge_revertsWhenBurnExceedsCctpLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        messenger.setBurnLimit(address(usdc), amount - 1);

        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);

        vm.expectRevert(abi.encodeWithSelector(CCTPModule.BurnExceedsCctpLimit.selector, amount, amount - 1));
        cctpModule.requestBridge(address(safe), p, s, sigs);

        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_requestBridge_succeedsAtCctpLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        messenger.setBurnLimit(address(usdc), amount);

        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        assertEq(cctpModule.getPendingBridge(address(safe)).amount, amount);
    }

    function test_requestBridge_zeroDelay_clearsPreExistingOrphan() public {
        // Plant an orphan record at $.withdrawals[safe].destRecipient (struct slot offset +2).
        bytes32 baseSlot = 0x8acda1cfca4f5cfd72da8b3438a383a2a5be2d370022c8dfe2b3e8c2690b2e00;
        bytes32 withdrawalsSlot = bytes32(uint256(baseSlot) + 2);
        bytes32 recordBase = keccak256(abi.encode(address(safe), withdrawalsSlot));
        bytes32 destRecipientSlot = bytes32(uint256(recordBase) + 2);
        vm.store(address(cctpModule), destRecipientSlot, bytes32(uint256(1)));
        assertTrue(cctpModule.getPendingBridge(address(safe)).destRecipient != bytes32(0), "orphan planted");

        // Flip delay to zero and submit a fresh request.
        vm.prank(owner);
        cashModule.setDelays(0, 0, 0);

        uint256 amount = 50e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        // Burn happened, orphan cleared.
        assertEq(messenger.calls(), 1);
        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, bytes32(0));
    }

    function test_executeBridge_afterDelay() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        assertEq(messenger.calls(), 1);
        assertEq(usdc.balanceOf(address(messenger)), amount);
        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, bytes32(0));

        (, , , , , uint256 mf, uint32 mft) = messenger.last();
        assertEq(mf, _expectedMaxFee(amount));
        assertEq(mft, cfgFinality);
    }

    function test_executeBridge_revertsBeforeDelay() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        cctpModule.executeBridge(address(safe));
    }

    function test_executeBridge_noQueueReverts() public {
        vm.expectRevert(CCTPModule.NoWithdrawalQueuedForCCTP.selector);
        cctpModule.executeBridge(address(safe));
    }

    /// @notice Admin changing the messenger after a request must NOT affect an already-queued bridge.
    function test_executeBridge_usesSnapshotNotLiveConfig() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        // Admin swaps the messenger AND changes fee/finality after the request is queued.
        MockTokenMessenger messenger2 = new MockTokenMessenger();
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger2), maxFeeBps: 0, providerFeeBps: 0 });
        vm.prank(owner);
        cctpModule.setAssetConfig(assets, cfgs);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        // Burn went to the ORIGINAL messenger with the ORIGINAL fee/finality.
        assertEq(messenger.calls(), 1);
        assertEq(messenger2.calls(), 0);
        assertEq(usdc.balanceOf(address(messenger)), amount);
        (, , , , , uint256 mf, uint32 mft) = messenger.last();
        assertEq(mf, _expectedMaxFee(amount));
        assertEq(mft, cfgFinality);
    }

    /// @notice Removing the asset (tokenMessenger=0) after a request must not strand the queued bridge.
    function test_executeBridge_succeedsAfterAssetRemoved() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        // Admin removes USDC support after the request is queued.
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(0), maxFeeBps: 0, providerFeeBps: 0 });
        vm.prank(owner);
        cctpModule.setAssetConfig(assets, cfgs);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        assertEq(messenger.calls(), 1); // snapshot kept the original messenger
        assertEq(usdc.balanceOf(address(messenger)), amount);
    }

    /// @notice Snapshot policy: disabling the domain after a request does NOT block the queued bridge.
    function test_executeBridge_succeedsAfterDomainDisabled() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        uint32[] memory doms = new uint32[](1);
        doms[0] = destDomain;
        bool[] memory no = new bool[](1);
        no[0] = false;
        vm.prank(owner);
        cctpModule.setAllowedRoutes(address(usdc), doms, no);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        assertEq(messenger.calls(), 1);
        assertFalse(cctpModule.isRouteAllowed(address(usdc), destDomain));
    }

    // ───────────────────────── cancel ─────────────────────────

    function test_cancelBridge_clearsQueue() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        (s, sigs) = _signCancel();
        cctpModule.cancelBridge(address(safe), s, sigs);

        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, bytes32(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length, 0);
    }

    function test_cancelBridge_emitsOnceWithRealValues() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        (s, sigs) = _signCancel();
        vm.recordLogs();
        cctpModule.cancelBridge(address(safe), s, sigs);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("BridgeCancelled(address,uint32,address,uint256,bytes32)");
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(cctpModule) && logs[i].topics[0] == sig) {
                count++;
                (uint256 emittedAmount, bytes32 emittedRecipient) = abi.decode(logs[i].data, (uint256, bytes32));
                assertEq(emittedAmount, amount);
                assertEq(emittedRecipient, destRecipient);
            }
        }
        assertEq(count, 1);
    }

    function test_cancelBridgeByCashModule_clearsQueue() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        vm.prank(address(cashModule));
        cctpModule.cancelBridgeByCashModule(address(safe));

        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, bytes32(0));
    }

    function test_cancelBridgeByCashModule_nonCashModuleReverts() public {
        vm.expectRevert(CCTPModule.Unauthorized.selector);
        cctpModule.cancelBridgeByCashModule(address(safe));
    }
}
