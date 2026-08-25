// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BinSponsor, Cashback, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { IAaveV4Spoke } from "../../../../../src/interfaces/IAaveV4Spoke.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { LendSourcingLib } from "../../../../../src/libraries/LendSourcingLib.sol";
import { MockLendGateway } from "../../../../../src/mocks/MockLendGateway.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title MinHealthFactorTest
 * @notice The post-op health-factor floor on user-extraction ops: the borrow page, withdrawal requests
 *         that pull from Aave, and turning a collateral flag off enforce getAccountData().healthFactor >=
 *         minHealthFactor after the op. Card spends (credit and debit) and repays are deliberately exempt:
 *         settlement obligations must never fail on the floor and de-risking must always stay open.
 *         Liquidation still happens at HF < 1e18 on Aave regardless — the floor only keeps ether.fi-initiated
 *         extraction from parking a position near that line.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/MinHealthFactor.t.sol
 */
contract MinHealthFactorTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    uint256 internal constant FLOOR = 1.05e18;

    /// @dev These tests measure the health-factor floor, never the spending limit -- but their
    ///      spend amounts derive from the LIVE value of the weETH collateral (unpinned fork), so
    ///      the base $10k daily cap starts binding whenever weETH's price drifts high enough
    ///      (CI flaked exactly this way: ExceededDailySpendingLimit / declined buffered quotes).
    ///      Size the limits out of the way so only the floor ever decides these outcomes.
    function setUp() public virtual override {
        super.setUp();
        _updateSpendingLimit(1_000_000e6, 10_000_000e6);
    }

    function _setFloor(uint256 value) internal {
        vm.prank(owner);
        gw.setMinHealthFactor(value);
    }

    // ----------------------------------------------------------------- admin setter

    function test_setMinHealthFactor_adminOnlyBoundsAndEvent() public {
        vm.expectRevert();
        gw.setMinHealthFactor(FLOOR); // no role

        vm.startPrank(owner);
        vm.expectRevert(LendGateway.InvalidMinHealthFactor.selector);
        gw.setMinHealthFactor(0.9e18);
        vm.expectRevert(LendGateway.InvalidMinHealthFactor.selector);
        gw.setMinHealthFactor(2.1e18);

        vm.expectEmit(false, false, false, true, address(gw));
        emit LendGateway.MinHealthFactorSet(FLOOR);
        gw.setMinHealthFactor(FLOOR);
        assertEq(gw.minHealthFactor(), FLOOR, "floor stored");

        gw.setMinHealthFactor(0);
        assertEq(gw.minHealthFactor(), 0, "0 disables");
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- borrow page

    /// A borrow-page borrow that would land the health factor below the floor reverts. The borrow page
    /// re-supplies its proceeds as collateral, so a single borrow from a clean position cannot breach the
    /// floor — the check bites on a position already levered up (e.g. by earlier borrows).
    function test_borrow_revertsBelowFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 99) / 100, recipient); // HF ~1.01
        _setFloor(FLOOR);

        uint256 amountInUsd = gw.getAccountData(address(safe)).availableBorrowsUsd / 2;
        (address[] memory signers, bytes[] memory sigs) = _borrowSig(address(usdc), amountInUsd);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        cashModule.borrow(address(safe), address(usdc), amountInUsd, signers, sigs);
    }

    /// A borrow that keeps the health factor above the floor goes through.
    function test_borrow_okWithinFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _setFloor(FLOOR);

        uint256 amountInUsd = (gw.getAccountData(address(safe)).availableBorrowsUsd * 80) / 100; // HF ~1.25
        (address[] memory signers, bytes[] memory sigs) = _borrowSig(address(usdc), amountInUsd);
        cashModule.borrow(address(safe), address(usdc), amountInUsd, signers, sigs);

        assertGe(gw.getAccountData(address(safe)).healthFactor, FLOOR, "landed above the floor");
    }

    /// With the floor disabled (default), the same borrow on the same levered position goes through.
    function test_borrow_rawMaxOkWhenFloorDisabled() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 99) / 100, recipient); // HF ~1.01
        assertEq(gw.minHealthFactor(), 0, "floor disabled by default");

        uint256 amountInUsd = gw.getAccountData(address(safe)).availableBorrowsUsd / 2;
        (address[] memory signers, bytes[] memory sigs) = _borrowSig(address(usdc), amountInUsd);
        cashModule.borrow(address(safe), address(usdc), amountInUsd, signers, sigs);

        assertLt(gw.getAccountData(address(safe)).healthFactor, FLOOR, "below 1.05 by design");
    }

    // ----------------------------------------------------------------- withdrawal requests

    /// A withdrawal pulling from Aave that Aave itself would allow (HF stays >= 1) reverts on the
    /// stricter floor: the raw-LTV max quote is no longer requestable once the floor is set.
    function test_requestWithdrawal_aavePullRevertsBelowFloor() public {
        _buildGatewayPosition(address(safe), address(weETH), 10 ether, address(usdc), 5000e6);
        uint256 max = cashLens.getMaxSourceable(address(safe), address(weETH)); // raw-LTV bound: post-pull HF ~1.0
        _setFloor(FLOOR);

        (address[] memory signers, bytes[] memory signatures) = _signRequestWithdrawal(_addr1(address(weETH)), _uint1(max), withdrawRecipient);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        cashModule.requestWithdrawal(address(safe), _addr1(address(weETH)), _uint1(max), withdrawRecipient, signers, signatures);
    }

    /// A loose-balance-only withdrawal never touches the Aave position, so it stays open even while the
    /// safe already sits below the floor.
    function test_requestWithdrawal_looseOnlyOkBelowFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 99) / 100, recipient);
        _setFloor(FLOOR);
        assertLt(gw.getAccountData(address(safe)).healthFactor, FLOOR, "already below the floor");

        deal(address(usdc), address(safe), 100e6);
        _requestWithdrawal(_addr1(address(usdc)), _uint1(100e6), withdrawRecipient);
    }

    // ----------------------------------------------------------------- spends are exempt

    /// A credit spend goes through even when it leaves the health factor below the floor: card
    /// settlement must never fail on the buffer.
    function test_spendCredit_alwaysGoesThroughBelowFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _setModeCredit();
        _setFloor(FLOOR);

        uint256 amountInUsd = (gw.getAccountData(address(safe)).availableBorrowsUsd * 97) / 100; // HF ~1.03
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _addr1(address(usdc)), _uint1(amountInUsd), _noCashback());

        assertTrue(cashModule.transactionCleared(address(safe), txId), "credit spend settled");
        uint256 hf = gw.getAccountData(address(safe)).healthFactor;
        assertLt(hf, FLOOR, "spend was allowed to cross the floor");
        assertGe(hf, 1e18, "still above Aave's liquidation line");
    }

    /// A debit spend on a safe already below the floor still settles.
    function test_spendDebit_alwaysGoesThroughBelowFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 99) / 100, recipient);
        _setFloor(FLOOR);
        assertLt(gw.getAccountData(address(safe)).healthFactor, FLOOR, "already below the floor");

        deal(address(usdc), address(safe), 100e6);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _addr1(address(usdc)), _uint1(50e6), _noCashback());

        assertTrue(cashModule.transactionCleared(address(safe), txId), "debit spend settled");
    }

    // ----------------------------------------------------------------- repay is exempt

    /// Repaying is always open below the floor — de-risking must never be blocked.
    function test_repay_alwaysOpenBelowFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 99) / 100, recipient);
        _setFloor(FLOOR);
        uint256 hfBefore = gw.getAccountData(address(safe)).healthFactor;
        assertLt(hfBefore, FLOOR, "starts below the floor");

        deal(address(usdc), address(safe), 2000e6);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), 1000e6);

        assertGt(gw.getAccountData(address(safe)).healthFactor, hfBefore, "repay improved the position");
    }

    // ----------------------------------------------------------------- collateral flag off

    /// Dropping a collateral flag that Aave would allow (HF stays >= 1) reverts on the stricter floor;
    /// disabling the floor re-opens it.
    function test_setUsingAsCollateralFalse_revertsBelowFloor() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        uint256 weethOnlyAvail = gw.getAccountData(address(safe)).availableBorrowsUsd;
        _supplyToGateway(address(safe), address(usdc), 1000e6);
        // Debt sized so weETH alone still covers it (Aave allows the drop) but lands HF ~1.01 (< floor)
        _borrowOnGateway(address(safe), address(usdc), (weethOnlyAvail * 99) / 100, recipient);
        _setFloor(FLOOR);

        vm.prank(driver);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        gw.setUsingAsCollateral(address(safe), address(usdc), false);

        _setFloor(0);
        vm.prank(driver);
        gw.setUsingAsCollateral(address(safe), address(usdc), false); // Aave's own check still passes
    }

    // ----------------------------------------------------------------- rounding & dust

    /// withdrawHeadroom rounds the required (post-floor) debt cover UP: `required` is a minimum, so
    /// rounding it down would let the exact max quote sit a hair past the floor and fail the post-op
    /// health check (test_getMaxSourceable_quoteExactlyRequestableWithFloor pins that end-to-end).
    /// Here: the floor strictly shrinks the headroom while debt is open, and a position below the floor
    /// quotes zero while the raw (1.00) headroom stays open for settlement.
    function test_withdrawHeadroom_bufferedInsideRaw() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 99) / 100, recipient);

        uint256 raw = gw.rawWithdrawHeadroom(address(safe));
        assertGt(raw, 0, "healthy position has raw headroom");
        assertEq(gw.withdrawHeadroom(address(safe)), raw, "no floor: buffered equals raw");

        _setFloor(FLOOR);
        assertLt(gw.getAccountData(address(safe)).healthFactor, FLOOR, "position sits below the floor");
        assertEq(gw.withdrawHeadroom(address(safe)), 0, "below the floor the buffered headroom is zero");
        assertGt(gw.rawWithdrawHeadroom(address(safe)), 0, "raw headroom stays open for settlement");
    }

    /// Dust debt below the 6-decimal USD floor must still cap the quotes: Aave enforces it on withdrawals
    /// even when flooring would read it as zero. Two guards pin that: debt legs round UP in
    /// getAccountData (so the headroom reserves cover), and hasDebt reads raw per-asset debt — the quote
    /// stays below the full supplied balance instead of overquoting and reverting on Aave's health check.
    function test_hasDebt_dustDebtStillCapsQuotes() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        // 1 wei of raw weETH debt injected at the spoke reads the gateway derives from: ~3e-9 USD, far
        // below the 6-decimal USD floor (weETH itself is collateral-only, so it cannot be borrowed for real).
        // getUserTotalDebt feeds hasDebt/getAccountData; the premium ray feeds the capacity accumulators.
        vm.mockCall(address(spoke), abi.encodeWithSelector(IAaveV4Spoke.getUserTotalDebt.selector, weethReserveId, address(safe)), abi.encode(uint256(1)));
        vm.mockCall(address(spoke), abi.encodeWithSelector(IAaveV4Spoke.getUserPremiumDebtRay.selector, weethReserveId, address(safe)), abi.encode(uint256(1e27)));
        vm.mockCall(address(spoke), abi.encodeWithSelector(IAaveV4Spoke.getUserReserveStatus.selector, weethReserveId, address(safe)), abi.encode(true, true));

        // Debt legs round UP in getAccountData, so even sub-micro dust registers as one micro-dollar
        assertEq(gw.getAccountData(address(safe)).debtUsd, 1, "dust debt ceils to one micro-dollar");
        assertTrue(gw.hasDebt(address(safe)), "raw read sees the debt too");

        uint256 max = cashLens.getMaxSourceable(address(safe), address(weETH));
        assertLt(max, 5 ether, "dust debt caps the quote below the full supplied balance");
    }

    // ----------------------------------------------------------------- lens quotes are buffered

    /// The lens quotes credit capacity buffered by the floor: an amount inside the buffer is approved and
    /// settles landing above the floor; between the buffer and Aave's raw bound it is declined.
    function test_lens_creditQuoteBuffered() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _setModeCredit();
        uint256 rawMax = cashLens.getMaxSpendCredit(address(safe));

        _setFloor(FLOOR);
        uint256 bufferedMax = cashLens.getMaxSpendCredit(address(safe));
        assertLt(bufferedMax, rawMax, "floor shrinks the credit quote");
        assertApproxEqRel(bufferedMax, (rawMax * 1e18) / FLOOR, 0.001e18, "buffered = raw / floor with no debt");

        (bool ok,) = cashLens.canSpend(address(safe), txId, _addr1(address(usdc)), _uint1(bufferedMax));
        assertTrue(ok, "quote is approvable");
        (bool okOver, string memory reason) = cashLens.canSpend(address(safe), txId, _addr1(address(usdc)), _uint1((bufferedMax + rawMax) / 2));
        assertFalse(okOver, "past the buffer is declined");
        assertEq(reason, "Insufficient borrowing power");

        // Spending exactly the buffered quote settles and lands at (or above) the floor
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _addr1(address(usdc)), _uint1(bufferedMax), _noCashback());
        assertGe(gw.getAccountData(address(safe)).healthFactor, FLOOR - 0.002e18, "landed at the floor (rounding tolerance)");
    }

    /// Soft enforcement: an amount the lens declines (between the buffer and Aave's raw bound) still
    /// SETTLES if it was authorized earlier — spend execution keeps the raw bound.
    function test_lens_declinedCreditSpendStillSettles() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _setModeCredit();
        _setFloor(FLOOR);

        uint256 amount = (gw.getAccountData(address(safe)).availableBorrowsUsd * 97) / 100; // inside raw, past buffer
        (bool ok,) = cashLens.canSpend(address(safe), txId, _addr1(address(usdc)), _uint1(amount));
        assertFalse(ok, "new auths at this size are declined");

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _addr1(address(usdc)), _uint1(amount), _noCashback());
        assertTrue(cashModule.transactionCleared(address(safe), txId), "previously authorized spend settled");
        assertLt(gw.getAccountData(address(safe)).healthFactor, FLOOR, "past the floor, by design");
    }

    /// The debit quote shrinks under the floor and spending exactly the quote lands at or above it.
    function test_lens_debitQuoteBuffered() public {
        _supplyToGateway(address(safe), address(usdc), 10_000e6);
        _borrowOnGateway(address(safe), address(usdc), 4000e6, recipient);
        uint256 rawQuote = cashLens.getMaxSpendDebit(address(safe), _addr1(address(usdc))).totalSpendableInUsd;

        _setFloor(FLOOR);
        uint256 bufferedQuote = cashLens.getMaxSpendDebit(address(safe), _addr1(address(usdc))).totalSpendableInUsd;
        assertLt(bufferedQuote, rawQuote, "floor shrinks the debit quote");

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _addr1(address(usdc)), _uint1(bufferedQuote), _noCashback());
        assertGe(gw.getAccountData(address(safe)).healthFactor, FLOOR - 0.002e18, "landed at the floor (rounding tolerance)");
    }

    /// With the floor set, getMaxSourceable is exactly requestable: the quote passes the post-pull check
    /// and one weETH-cent more reverts on it (closes the quote/enforcement gap for withdrawals).
    function test_getMaxSourceable_quoteExactlyRequestableWithFloor() public {
        _buildGatewayPosition(address(safe), address(weETH), 10 ether, address(usdc), 5000e6);
        _setFloor(FLOOR);

        uint256 max = cashLens.getMaxSourceable(address(safe), address(weETH));
        assertLt(max, 10 ether, "debt caps the withdrawable balance");

        (address[] memory signers, bytes[] memory signatures) = _signRequestWithdrawal(_addr1(address(weETH)), _uint1(max + 0.01 ether), withdrawRecipient);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        cashModule.requestWithdrawal(address(safe), _addr1(address(weETH)), _uint1(max + 0.01 ether), withdrawRecipient, signers, signatures);

        _requestWithdrawal(_addr1(address(weETH)), _uint1(max), withdrawRecipient);
        assertGe(gw.getAccountData(address(safe)).healthFactor, FLOOR, "quote respects the floor");
    }

    // ----------------------------------------------------------------- helpers

    function _setModeCredit() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(Mode.Credit))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.setMode(address(safe), Mode.Credit, owner1, abi.encodePacked(r, s, v));
        (,, uint64 modeDelay) = cashModule.getDelays();
        vm.warp(block.timestamp + modeDelay + 1);
    }

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

    function _signRequestWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient_) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, recipient_))).toEthSignedMessageHash();
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

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

    function _noCashback() internal pure returns (Cashback[] memory) {
        return new Cashback[](0);
    }
}
