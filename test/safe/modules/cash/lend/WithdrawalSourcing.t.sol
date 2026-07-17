// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title WithdrawalSourcingTest
 * @notice Fork tests for the withdrawal request's pull-first step: a gateway safe's shortfall is withdrawn
 *         from Aave into the safe at request time, then the existing delayed queue runs on the loose
 *         balance. Aave enforces the position's health on the pull, so a request that would leave the safe
 *         unhealthy reverts, and the quote side (CashLens.getMaxSourceable) is exactly requestable. The
 *         legacy path is untouched (the pull is skipped), covered by the default-profile withdrawal tests.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/WithdrawalSourcing.t.sol
 */
contract WithdrawalSourcingTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    /// A request larger than the loose balance pulls only the shortfall out of Aave, queues, and pays out
    /// the full amount after the delay.
    function test_requestWithdrawal_pullsShortfallFromSupplied() public {
        _supplyToGateway(address(safe), address(weETH), 3 ether);
        deal(address(weETH), address(safe), 1 ether);
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(weETH));

        _requestWithdrawal(_addr1(address(weETH)), _uint1(3 ether), withdrawRecipient);

        assertEq(weETH.balanceOf(address(safe)), 3 ether, "shortfall pulled into the safe");
        assertApproxEqAbs(suppliedBefore - gw.suppliedOf(address(safe), address(weETH)), 2 ether, 2, "only the shortfall left the supplied pot");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETH)), 3 ether, "request queued for the full amount");

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(address(safe));
        assertEq(weETH.balanceOf(withdrawRecipient), 3 ether, "recipient paid the full amount");
    }

    /// A frozen reserve still honors withdrawals: the request pulls from the supplied pot as usual, since
    /// Aave's freeze blocks supply and borrow but not withdraw.
    function test_requestWithdrawal_pullsFromSuppliedWhileReserveFrozen() public {
        _supplyToGateway(address(safe), address(weETH), 3 ether);
        _setAaveReserveFrozen(weethReserveId, true);

        _requestWithdrawal(_addr1(address(weETH)), _uint1(2 ether), withdrawRecipient);

        assertEq(weETH.balanceOf(address(safe)), 2 ether, "shortfall pulled from Aave while frozen");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETH)), 2 ether, "request queued");
    }

    /// A fully swept safe (zero loose) can withdraw: the whole amount is pulled from the supplied pot.
    function test_requestWithdrawal_fullySweptSafe() public {
        _supplyToGateway(address(safe), address(usdc), 5000e6);
        assertEq(usdc.balanceOf(address(safe)), 0, "swept safe holds no loose USDC");

        _requestWithdrawal(_addr1(address(usdc)), _uint1(4000e6), withdrawRecipient);

        assertEq(usdc.balanceOf(address(safe)), 4000e6, "pulled from Aave into the safe");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 1000e6, 2, "the rest stays supplied");
    }

    /// The lens quote is exactly requestable with debt open: getMaxSourceable succeeds and one weETH-cent
    /// more reverts on Aave's health check.
    function test_requestWithdrawal_maxWithdrawableIsRequestableWithDebt() public {
        _buildGatewayPosition(address(safe), address(weETH), 10 ether, address(usdc), 5000e6);
        uint256 max = cashLens.getMaxSourceable(address(safe), address(weETH));
        assertLt(max, 10 ether, "debt caps the withdrawable balance");

        (address[] memory signers, bytes[] memory signatures) = _signRequestWithdrawal(_addr1(address(weETH)), _uint1(max + 0.01 ether), withdrawRecipient);
        vm.expectRevert();
        cashModule.requestWithdrawal(address(safe), _addr1(address(weETH)), _uint1(max + 0.01 ether), withdrawRecipient, signers, signatures);

        _requestWithdrawal(_addr1(address(weETH)), _uint1(max), withdrawRecipient);
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETH)), max, "max quote is requestable");
    }

    /// When both pots together cannot fund the request, it reverts with the module's own error.
    function test_requestWithdrawal_revertsWhenBothPotsShort() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);

        (address[] memory signers, bytes[] memory signatures) = _signRequestWithdrawal(_addr1(address(weETH)), _uint1(2 ether), withdrawRecipient);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.requestWithdrawal(address(safe), _addr1(address(weETH)), _uint1(2 ether), withdrawRecipient, signers, signatures);
    }

    /// A request the loose balance already covers never touches the gateway.
    function test_requestWithdrawal_looseCoversSkipsPull() public {
        _supplyToGateway(address(safe), address(weETH), 3 ether);
        deal(address(weETH), address(safe), 2 ether);
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(weETH));

        _requestWithdrawal(_addr1(address(weETH)), _uint1(2 ether), withdrawRecipient);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), suppliedBefore, "supplied pot untouched");
    }

    /// The auto-supply sweep nets out the pending reservation, so the pulled funds are never swept back
    /// into Aave during the delay.
    function test_autoSupply_neverSweepsThePulledFundsBack() public {
        _supplyToGateway(address(safe), address(usdc), 5000e6);
        _requestWithdrawal(_addr1(address(usdc)), _uint1(4000e6), withdrawRecipient);
        uint256 suppliedAfterPull = gw.suppliedOf(address(safe), address(usdc));

        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), _addr1(address(usdc)));

        assertEq(usdc.balanceOf(address(safe)), 4000e6, "reserved funds stay loose");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), suppliedAfterPull, "nothing swept back");
    }

    /// A full exit at the getMaxSourceable quote pays out exactly, even after interest accrual has
    /// moved the share rate: the pull is capped at the same preview the spoke itself caps with, and the
    /// hub transfers the capped amount exactly, so no rounding dust can undercut the balance check.
    function test_requestWithdrawal_fullExitAtQuoteAfterAccrual() public {
        _supplyToGateway(address(safe), address(usdc), 5000e6);

        // An independent borrower drives USDC utilization so the supplied balance accrues interest
        address borrower = makeAddr("dustBorrower");
        deal(address(weETH), borrower, 400 ether);
        vm.startPrank(borrower);
        weETH.approve(address(spoke), 400 ether);
        spoke.supply(weethReserveId, 400 ether, borrower);
        spoke.setUsingAsCollateral(weethReserveId, true, borrower);
        spoke.borrow(usdcReserveId, 500_000e6, borrower);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        uint256 max = cashLens.getMaxSourceable(address(safe), address(usdc));
        assertGt(max, 5000e6, "interest accrued on the supplied balance");

        _requestWithdrawal(_addr1(address(usdc)), _uint1(max), withdrawRecipient);
        assertEq(usdc.balanceOf(address(safe)), max, "full exit lands in the safe exactly");

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(address(safe));
        assertEq(usdc.balanceOf(withdrawRecipient), max, "recipient paid the full quote");
    }

    /// Regression: a gateway safe supplied in an Aave asset that DebtManager no longer lists as collateral
    /// must still be able to withdraw. Both withdrawal paths call DebtManager.ensureHealth, whose
    /// getMaxBorrowAmount walks the safe's Aave-supplied assets and reverts UnsupportedCollateralToken for
    /// any asset missing from the (separate, shrinking) DebtManager collateral registry. The call is gated on
    /// !usesLendGateway, so a gateway safe skips it entirely; Aave already health-checks the pull.
    function test_requestWithdrawal_notBrickedWhenSuppliedAssetDelistedFromDebtManager() public {
        _supplyToGateway(address(safe), address(weETH), 3 ether); // gateway-registered Aave collateral
        deal(address(usdc), address(safe), 4000e6); // unrelated loose USDC the safe wants to withdraw

        // DebtManager retires weETH as legacy collateral while the gateway safe still holds it on Aave: the
        // two registries diverge, which is the intended end state as the legacy engine is wound down.
        vm.prank(owner);
        debtManager.unsupportCollateralToken(address(weETH));

        // requestWithdrawal (the first gated ensureHealth) must not revert.
        _requestWithdrawal(_addr1(address(usdc)), _uint1(4000e6), withdrawRecipient);

        // processWithdrawal (the second gated ensureHealth) must also pay out.
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(address(safe));
        assertEq(usdc.balanceOf(withdrawRecipient), 4000e6, "recipient paid despite the delisted supplied asset");
    }

    /// Catch-all: DebtManager.ensureHealth is a no-op for a gateway safe even when called directly, so any
    /// future caller that forgets the !usesLendGateway guard stays safe. Without the internal guard this
    /// reverts UnsupportedCollateralToken once weETH is delisted while the safe still holds it supplied on Aave.
    function test_ensureHealth_isNoOpForGatewaySafeWithDelistedSuppliedAsset() public {
        _supplyToGateway(address(safe), address(weETH), 3 ether);

        vm.prank(owner);
        debtManager.unsupportCollateralToken(address(weETH));

        debtManager.ensureHealth(address(safe)); // must not revert
    }

    /// Builds the owner signatures for a withdrawal request, so revert-path tests can place expectRevert
    /// immediately before the module call.
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
}
