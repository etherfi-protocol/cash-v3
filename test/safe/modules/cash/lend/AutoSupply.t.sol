// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { EtherFiSafeErrors } from "../../../../../src/safe/EtherFiSafeErrors.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

/**
 * @title AutoSupplyTest
 * @notice Fork tests for the on-chain half of auto-supply: the sweep entrypoint (supplyToLend, called by the
 *         cash-be cron via the EtherFi wallet) that moves a safe's loose balances into Aave as collateral,
 *         and the borrow entrypoint whose proceeds land in the safe and are supplied back atomically.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/AutoSupply.t.sol
 */
contract AutoSupplyTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    /// The sweep supplies each token's loose balance net of the pending-withdrawal reservation and flags
    /// it as collateral; the reserved balance stays loose and the request survives.
    function test_supplyToLend_sweepsLooseNetOfReservation() public {
        uint256 looseUsdc = 1000e6;
        uint256 reservedUsdc = 300e6;
        uint256 looseWeeth = 2 ether;
        deal(address(usdc), address(safe), looseUsdc);
        deal(address(weETH), address(safe), looseWeeth);
        _requestWithdrawal(_addr1(address(usdc)), _uint1(reservedUsdc), withdrawRecipient);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weETH);

        vm.expectEmit(true, true, false, true, address(gw));
        emit LendGateway.Supplied(address(safe), address(usdc), looseUsdc - reservedUsdc);
        vm.expectEmit(true, true, false, true, address(gw));
        emit LendGateway.CollateralUsageSet(address(safe), address(usdc), true);
        vm.expectEmit(true, true, false, true, address(gw));
        emit LendGateway.Supplied(address(safe), address(weETH), looseWeeth);
        vm.expectEmit(true, true, false, true, address(gw));
        emit LendGateway.CollateralUsageSet(address(safe), address(weETH), true);
        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), tokens);

        assertEq(gw.suppliedOf(address(safe), address(usdc)), looseUsdc - reservedUsdc, "swept loose minus the reservation");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), looseWeeth, "swept the full weETH balance");
        assertEq(usdc.balanceOf(address(safe)), reservedUsdc, "reserved balance stays loose");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), reservedUsdc, "withdrawal request survived");
        assertGt(gw.getAccountData(address(safe)).availableBorrowsUsd, 0, "supplied balances count as collateral");
    }

    /// Zero-balance and unregistered tokens are skipped, not reverted, so a keeper batch never bricks.
    function test_supplyToLend_skipsZeroAndUnregisteredTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = makeAddr("unregistered");
        tokens[1] = address(weETH); // zero balance

        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), tokens);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "nothing supplied");
    }

    /// A reserve that rejects the supply (here, frozen) is skipped best-effort: the sweep supplies the
    /// healthy token, leaves the blocked token's balance loose for the next sweep, and never bricks the batch.
    function test_supplyToLend_skipsReserveThatRejectsSupply() public {
        uint256 looseUsdc = 1000e6;
        uint256 looseWeeth = 2 ether;
        deal(address(usdc), address(safe), looseUsdc);
        deal(address(weETH), address(safe), looseWeeth);

        _setAaveReserveFrozen(usdcReserveId, true); // supply into the USDC reserve now reverts inside Aave

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weETH);

        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), tokens);

        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "frozen reserve skipped, nothing supplied");
        assertEq(usdc.balanceOf(address(safe)), looseUsdc, "blocked token stays loose for the next sweep");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), looseWeeth, "healthy token still swept");
    }

    /// A collateral-toggle failure rolls back only that token, emits the reason, and does not brick the batch.
    function test_supplyToLend_skipsCollateralEnablementFailure() public {
        uint256 looseWeeth = 2 ether;
        uint256 looseUsdc = 1000e6;
        deal(address(weETH), address(safe), looseWeeth);
        deal(address(usdc), address(safe), looseUsdc);

        bytes memory reason = abi.encodeWithSelector(ISpoke.MaximumUserReservesExceeded.selector);
        vm.mockCallRevert(address(spoke), abi.encodeCall(ISpoke.setUsingAsCollateral, (weethReserveId, true, address(safe))), reason);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weETH);
        tokens[1] = address(usdc);

        vm.expectEmit(true, true, false, true, address(cashEventEmitter));
        emit CashEventEmitter.LendSupplyFailed(address(safe), address(weETH), looseWeeth, reason);
        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), tokens);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "failed token was not left supplied");
        assertEq(weETH.balanceOf(address(safe)), looseWeeth, "failed token stays loose");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), looseUsdc, "healthy token still swept");
    }

    /// An opted-out safe is a no-op sweep (the keeper legitimately races an opt-out); its funds stay loose.
    function test_supplyToLend_noopWhenOptedOut() public {
        uint256 looseUsdc = 500e6;
        _optOut();
        deal(address(usdc), address(safe), looseUsdc);

        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), _addr1(address(usdc)));

        assertEq(usdc.balanceOf(address(safe)), looseUsdc, "opted-out safe keeps funds loose");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "nothing supplied");
    }

    /// Routing a legacy safe to the sweep is a keeper bug and reverts loudly.
    function test_supplyToLend_revertsForLegacySafe() public {
        _forceLegacyEngine(address(safe));
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyLendGatewaySafe.selector);
        cashModule.supplyToLend(address(safe), _addr1(address(usdc)));
    }

    /// A borrow lands in the safe and is supplied back as collateral in the same tx: the portfolio gains
    /// the asset, nothing stays loose, and the borrowing power moves by the asset's LTV weight net of debt.
    function test_borrow_suppliesProceedsAsCollateral() public {
        uint256 collateralWeeth = 5 ether;
        uint256 borrowUsd = 500e6;
        _supplyToGateway(address(safe), address(weETH), collateralWeeth);
        uint256 availableBefore = gw.getAccountData(address(safe)).availableBorrowsUsd;

        uint256 borrowAmt = debtManager.convertUsdToCollateralToken(address(usdc), borrowUsd);
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), borrowUsd);
        vm.expectEmit(true, true, false, true, address(gw));
        emit LendGateway.Supplied(address(safe), address(usdc), borrowAmt);
        vm.expectEmit(true, true, false, true, address(gw));
        emit LendGateway.CollateralUsageSet(address(safe), address(usdc), true);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.LendBorrowed(address(safe), address(usdc), borrowAmt, borrowUsd);
        cashModule.borrow(address(safe), address(usdc), borrowUsd, signers, signatures);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowAmt, 2, "debt opened");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), borrowAmt, 2, "proceeds supplied back");
        assertEq(usdc.balanceOf(address(safe)), 0, "nothing left loose");
        // The borrow adds borrowUsd of debt, and supplying the proceeds back adds CF% of it as collateral
        // weight, so the net borrowing-power cost is the remaining (100 - CF)%
        uint256 powerConsumedUsd = borrowUsd - (borrowUsd * _usdcCollateralFactorBps()) / 10_000;
        assertApproxEqAbs(availableBefore - gw.getAccountData(address(safe)).availableBorrowsUsd, powerConsumedUsd, 2e6, "borrow power moved by debt minus LTV-weighted supply");
    }

    /// The borrow proceeds are supplied back best-effort: with the borrow reserve at its supply cap, the
    /// borrow the owners signed for still lands and the proceeds stay loose (the next sweep restores them),
    /// rather than reverting the whole borrow.
    function test_borrow_proceedsStayLooseWhenSupplyCapped() public {
        uint256 collateralWeeth = 5 ether;
        uint256 borrowUsd = 500e6;
        _supplyToGateway(address(safe), address(weETH), collateralWeeth);

        // USDC reserve at a zero supply cap (any add reverts AddCapExceeded); borrow draw stays uncapped
        _setAaveSpokeCaps(usdcReserveId, 0, type(uint40).max);

        uint256 borrowAmt = debtManager.convertUsdToCollateralToken(address(usdc), borrowUsd);
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), borrowUsd);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.LendBorrowed(address(safe), address(usdc), borrowAmt, borrowUsd);
        cashModule.borrow(address(safe), address(usdc), borrowUsd, signers, signatures);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowAmt, 2, "debt opened");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "capped reserve rejected the supply-back");
        assertApproxEqAbs(usdc.balanceOf(address(safe)), borrowAmt, 2, "proceeds stay loose for the next sweep");
    }

    /// An opted-out safe cannot borrow.
    function test_borrow_revertsWhenOptedOut() public {
        _optOut();

        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), 100e6);
        vm.expectRevert(ICashModule.LendOptedOut.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, signatures);
    }

    /// A registered but collateral-only asset (weETH's reserve has borrowable off) is rejected with the
    /// module's own error, not deep inside Aave. The check reads the gateway, not the DebtManager.
    function test_borrow_revertsForNonBorrowableToken() public {
        _supplyToGateway(address(safe), address(usdc), 1000e6);
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(weETH), 100e6);
        vm.expectRevert(ICashModule.OnlyBorrowToken.selector);
        cashModule.borrow(address(safe), address(weETH), 100e6, signers, signatures);
    }

    /// A legacy safe has no gateway borrow flow.
    function test_borrow_revertsForLegacySafe() public {
        _forceLegacyEngine(address(safe));
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), 100e6);
        vm.expectRevert(ICashModule.OnlyLendGatewaySafe.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, signatures);
    }

    /// Borrow needs the owner quorum: a non-owner in the signer set is rejected.
    function test_borrow_rejectsNonOwnerSigner() public {
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), 100e6);
        signers[1] = notOwner; // owner1 still signs, but the second slot is a non-owner

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 1));
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, signatures);
    }

    /// Borrow needs the owner quorum: a single owner signature is below the threshold of two.
    function test_borrow_rejectsBelowThreshold() public {
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), 100e6);
        address[] memory one = _addr1(signers[0]);
        bytes[] memory oneSig = new bytes[](1);
        oneSig[0] = signatures[0];

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, one, oneSig);
    }

    /// Borrow needs the owner quorum: an owner is named but its signature is from the wrong key.
    function test_borrow_rejectsBadSignature() public {
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), 100e6);
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(address(usdc), uint256(100e6)))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner3Pk, digest); // owner3 signs the owner2 slot
        signatures[1] = abi.encodePacked(r, s, v);

        vm.expectRevert(CashVerificationLib.InvalidSignatures.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, signatures);
    }

    /// The nonce advances on a successful borrow, so replaying the same signatures is rejected.
    function test_borrow_rejectsReplay() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        (address[] memory signers, bytes[] memory signatures) = _borrowSig(address(usdc), 100e6);
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, signatures);

        vm.expectRevert(CashVerificationLib.InvalidSignatures.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, signatures);
    }

    /// @dev Opts the safe out of the lend market, riding out the mode-change delay.
    function _optOut() internal {
        (address signer, bytes memory sig) = _toggleLendSig(false);
        cashModule.toggleLend(address(safe), false, signer, sig);
        (,, uint64 modeDelay) = cashModule.getDelays();
        if (modeDelay != 0) {
            vm.warp(block.timestamp + modeDelay + 1);
            cashModule.processLendOptOut(address(safe));
        }
    }

    function _toggleLendSig(bool enable) internal view returns (address, bytes memory) {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(enable))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        return (owner1, abi.encodePacked(r, s, v));
    }

    /// @dev Builds the owner quorum (owner1 + owner2, the safe's threshold) signing a borrow intent.
    function _borrowSig(address token, uint256 amountInUsd) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(token, amountInUsd))).toEthSignedMessageHash();
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        return (signers, signatures);
    }

    function _uint1(uint256 a) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = a;
        return arr;
    }
}
