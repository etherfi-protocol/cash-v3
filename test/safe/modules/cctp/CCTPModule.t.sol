// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CCTPModule } from "../../../../src/modules/cctp/CCTPModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { ICCTPTokenMessenger } from "../../../../src/interfaces/ICCTPTokenMessenger.sol";
import { ICashModule, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";

/// @dev Mock TokenMessenger: records the last depositForBurn call so tests can assert the burn payload.
contract MockTokenMessenger is ICCTPTokenMessenger {
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
}

contract CCTPModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    CCTPModule cctpModule;
    MockTokenMessenger messenger;

    uint32 destDomain = 6; // arbitrary
    // Transfer mode + fee are now admin-config, not request params.
    uint32 cfgFinality = 1000;   // Fast, to exercise a non-zero fee
    uint256 cfgMaxFeeBps = 5;    // 0.05%
    address destRecipientAddr = makeAddr("destRecipient");

    function _expectedMaxFee(uint256 amount) internal view returns (uint256) {
        return (amount * cfgMaxFeeBps) / cctpModule.MAX_BPS();
    }

    function setUp() public override {
        super.setUp();

        messenger = new MockTokenMessenger();

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), finalityThreshold: cfgFinality, maxFeeBps: cfgMaxFeeBps });

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
        cctpModule.setAllowedDomains(doms, ok);
        vm.stopPrank();
    }

    // ───────────────────────── helpers ─────────────────────────

    function _params(uint256 amount) internal view returns (CCTPModule.BridgeParams memory) {
        return CCTPModule.BridgeParams({
            destDomain: destDomain,
            asset: address(usdc),
            amount: amount,
            destRecipient: destRecipientAddr
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

    // ───────────────────────── config ─────────────────────────

    function test_setAllowedDomains_nonAdminReverts() public {
        uint32[] memory doms = new uint32[](1);
        doms[0] = 42;
        bool[] memory ok = new bool[](1);
        ok[0] = true;
        vm.expectRevert(CCTPModule.Unauthorized.selector);
        cctpModule.setAllowedDomains(doms, ok);
    }

    function test_setAssetConfig_invalidFinalityThresholdReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), finalityThreshold: 1234, maxFeeBps: 0 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.InvalidFinalityThreshold.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_setAssetConfig_maxFeeBpsTooHighReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        // Fast finality so the Standard-fee rule doesn't fire first; isolates the bps cap check.
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), finalityThreshold: 1000, maxFeeBps: 10_000 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.MaxFeeBpsTooHigh.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_setAssetConfig_standardModeWithFeeReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        // Standard (2000) + non-zero fee is rejected: Standard transfers are free on OP.
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), finalityThreshold: 2000, maxFeeBps: 1 });
        vm.prank(owner);
        vm.expectRevert(CCTPModule.StandardModeFeeNotAllowed.selector);
        cctpModule.setAssetConfig(assets, cfgs);
    }

    function test_setAssetConfig_standardModeZeroFeeAllowed() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger), finalityThreshold: 2000, maxFeeBps: 0 });
        vm.prank(owner);
        cctpModule.setAssetConfig(assets, cfgs);
        assertEq(cctpModule.getAssetConfig(address(usdc)).finalityThreshold, 2000);
        assertEq(cctpModule.getAssetConfig(address(usdc)).maxFeeBps, 0);
    }

    function test_getBridgeFee_returnsConfiguredFee() public view {
        (address feeToken, uint256 fee) = cctpModule.getBridgeFee(address(usdc), 100e6);
        assertEq(feeToken, address(usdc));
        assertEq(fee, _expectedMaxFee(100e6));
    }

    // ───────────────────────── request validation ─────────────────────────

    function test_requestBridge_unsupportedDomainReverts() public {
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.destDomain = 999;
        vm.expectRevert(CCTPModule.UnsupportedDomain.selector);
        cctpModule.requestBridge(address(safe), p, new address[](0), new bytes[](0));
    }

    function test_requestBridge_invalidInputReverts() public {
        CCTPModule.BridgeParams memory p = _params(100e6);
        p.destRecipient = address(0);
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
        assertEq(w.destRecipient, destRecipientAddr);
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
        assertEq(r, bytes32(uint256(uint160(destRecipientAddr))));
        assertEq(t, address(usdc));
        assertEq(dc, bytes32(0));
        assertEq(mf, _expectedMaxFee(amount));
        assertEq(mft, cfgFinality);
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
        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, address(0));

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
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(messenger2), finalityThreshold: 2000, maxFeeBps: 0 });
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
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: address(0), finalityThreshold: 0, maxFeeBps: 0 });
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
        cctpModule.setAllowedDomains(doms, no);

        (uint64 delay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + delay);
        cctpModule.executeBridge(address(safe));

        assertEq(messenger.calls(), 1);
        assertFalse(cctpModule.isDomainAllowed(destDomain));
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

        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length, 0);
    }

    function test_cancelBridgeByCashModule_clearsQueue() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        CCTPModule.BridgeParams memory p = _params(amount);
        (address[] memory s, bytes[] memory sigs) = _sign(p);
        cctpModule.requestBridge(address(safe), p, s, sigs);

        vm.prank(address(cashModule));
        cctpModule.cancelBridgeByCashModule(address(safe));

        assertEq(cctpModule.getPendingBridge(address(safe)).destRecipient, address(0));
    }

    function test_cancelBridgeByCashModule_nonCashModuleReverts() public {
        vm.expectRevert(CCTPModule.Unauthorized.selector);
        cctpModule.cancelBridgeByCashModule(address(safe));
    }
}
