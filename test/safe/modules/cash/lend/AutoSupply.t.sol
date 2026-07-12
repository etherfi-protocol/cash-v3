// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { SignatureUtils } from "../../../../../src/libraries/SignatureUtils.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

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

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.LendSupplied(address(safe), address(usdc), looseUsdc - reservedUsdc);
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
        (address signer, bytes memory sig) = _borrowSig(address(usdc), borrowUsd);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.LendSupplied(address(safe), address(usdc), borrowAmt);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.LendBorrowed(address(safe), address(usdc), borrowAmt, borrowUsd);
        cashModule.borrow(address(safe), address(usdc), borrowUsd, signer, sig);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowAmt, 2, "debt opened");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), borrowAmt, 2, "proceeds supplied back");
        assertEq(usdc.balanceOf(address(safe)), 0, "nothing left loose");
        // The borrow adds borrowUsd of debt, and supplying the proceeds back adds CF% of it as collateral
        // weight, so the net borrowing-power cost is the remaining (100 - CF)%
        uint256 powerConsumedUsd = borrowUsd - (borrowUsd * _usdcCollateralFactorBps()) / 10_000;
        assertApproxEqAbs(availableBefore - gw.getAccountData(address(safe)).availableBorrowsUsd, powerConsumedUsd, 2e6, "borrow power moved by debt minus LTV-weighted supply");
    }

    /// An opted-out safe cannot borrow.
    function test_borrow_revertsWhenOptedOut() public {
        _optOut();

        (address signer, bytes memory sig) = _borrowSig(address(usdc), 100e6);
        vm.expectRevert(ICashModule.LendDisabled.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signer, sig);
    }

    /// A legacy safe has no gateway borrow flow.
    function test_borrow_revertsForLegacySafe() public {
        _forceLegacyEngine(address(safe));
        (address signer, bytes memory sig) = _borrowSig(address(usdc), 100e6);
        vm.expectRevert(ICashModule.OnlyLendGatewaySafe.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signer, sig);
    }

    /// Borrow is owner-signed: a named signer who is not a safe admin is rejected.
    function test_borrow_rejectsNonAdminSigner() public {
        (, bytes memory sig) = _borrowSig(address(usdc), 100e6);
        vm.expectRevert(ICashModule.OnlySafeAdmin.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, makeAddr("notAdmin"), sig);
    }

    /// Borrow is owner-signed: an admin is named but the signature is from the wrong key.
    function test_borrow_rejectsBadSignature() public {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, address(safe), nonce, abi.encode(address(usdc), uint256(100e6)))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2Pk, digest); // owner2 signs, but we claim owner1
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(SignatureUtils.InvalidSigner.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, owner1, sig);
    }

    /// The nonce advances on a successful borrow, so replaying the same signature is rejected.
    function test_borrow_rejectsReplay() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        (address signer, bytes memory sig) = _borrowSig(address(usdc), 100e6);
        cashModule.borrow(address(safe), address(usdc), 100e6, signer, sig);

        vm.expectRevert(SignatureUtils.InvalidSigner.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signer, sig);
    }

    /// @dev Opts the safe out of the lend market, riding out the mode-change delay.
    function _optOut() internal {
        (address signer, bytes memory sig) = _toggleLendSig(false);
        cashModule.toggleLend(address(safe), false, signer, sig);
        (,, uint64 modeDelay) = cashModule.getDelays();
        if (modeDelay != 0) {
            vm.warp(block.timestamp + modeDelay + 1);
            cashModule.processLendDisable(address(safe));
        }
    }

    function _toggleLendSig(bool enable) internal view returns (address, bytes memory) {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(enable))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        return (owner1, abi.encodePacked(r, s, v));
    }

    function _borrowSig(address token, uint256 amountInUsd) internal view returns (address, bytes memory) {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, address(safe), nonce, abi.encode(token, amountInUsd))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        return (owner1, abi.encodePacked(r, s, v));
    }

    function _uint1(uint256 a) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = a;
        return arr;
    }
}
