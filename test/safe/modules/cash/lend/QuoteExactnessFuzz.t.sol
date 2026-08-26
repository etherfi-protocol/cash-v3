// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { IPriceProvider } from "../../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { LendSourcingLib } from "../../../../../src/libraries/LendSourcingLib.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title QuoteExactnessFuzzTest
 * @notice The backend sizes real spends and withdrawals with the lens quotes, so each quote must be
 *         exactly executable — and just past it must fail — under fuzzed positions and interest accrual:
 *         getMaxSpendDebit, getMaxSpendCredit, and getMaxSourceable. Rounding-direction checks ride along:
 *         a debit never settles more value than authorized (conversion floors), a credit always covers the
 *         authorized value (conversion ceils), and a full-exit withdrawal pays the quote exactly.
 * @dev No min-health-factor floor is set here, so the buffered and raw bounds coincide and "one unit more
 *      fails" holds on-chain, not just in the lens (the floor asymmetry is the parity fuzz's subject).
 *      Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/QuoteExactnessFuzz.t.sol"
 */
contract QuoteExactnessFuzzTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    Cashback[] internal noCashback;

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

    /// Single-element amount array.
    function _uint1(uint256 a) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = a;
        return arr;
    }

    /// Executes a single-token USDC spend of `amountUsd` as the ether.fi wallet.
    function _spend(bytes32 txId_, uint256 amountUsd) private {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId_, BinSponsor.Reap, tokens, amounts, noCashback);
    }

    /// Lens verdict for a single-token USDC spend of `amountUsd`.
    function _canSpend(bytes32 txId_, uint256 amountUsd) private view returns (bool, string memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        return cashLens.canSpend(address(safe), txId_, tokens, amounts);
    }

    /// The debit max-spend quote is exactly executable across loose/supplied splits, debt, and accrual;
    /// one USD unit more is declined and reverts. The settled value never exceeds the authorized USD.
    /// forge-config: lend.fuzz.runs = 64
    function testFuzz_maxSpendDebit_exactlyExecutable(uint256 suppliedUsdc, uint256 looseUsdc, uint256 collateralWeeth, uint256 debtBps, uint256 warpSecs) public {
        suppliedUsdc = bound(suppliedUsdc, 10e6, 2000e6);
        looseUsdc = bound(looseUsdc, 0, 1000e6);
        collateralWeeth = bound(collateralWeeth, 0.05 ether, 1 ether);
        debtBps = bound(debtBps, 0, 7000);
        warpSecs = bound(warpSecs, 0, 1 hours);

        _supplyToGateway(address(safe), address(usdc), suppliedUsdc);
        _supplyToGateway(address(safe), address(weETH), collateralWeeth);
        uint256 debtAmt = (gw.borrowCapacity(address(safe), address(usdc)) * debtBps) / 10_000;
        if (debtAmt > 0) {
            _borrowOnGateway(address(safe), address(usdc), debtAmt, recipient);
        }
        deal(address(usdc), address(safe), looseUsdc);
        vm.warp(block.timestamp + warpSecs);

        address[] memory prefs = new address[](1);
        prefs[0] = address(usdc);
        uint256 quote = cashLens.getMaxSpendDebit(address(safe), prefs).totalSpendableInUsd;
        assertGt(quote, 0, "funded safe quotes a spendable amount");
        // The quote is pure capacity: canSpend applies the spending limit separately, so the position
        // bounds above must keep the quote under the daily limit or the spend declines on the limit instead
        assertLt(quote, dailyLimitInUsd, "position bounds must keep the quote inside the spending limit");

        // The probe runs first, on its own txId: a settled spend at the quote would consume the capacity
        // and the spending limit this probe needs to be testing against.
        (bool okPlus,) = _canSpend(keccak256("qePlus"), quote + 1);
        assertFalse(okPlus, "one USD unit past the quote must be declined");
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        _spend(keccak256("qePlus"), quote + 1);

        (bool ok, string memory reason) = _canSpend(txId, quote);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _spend(txId, quote);
        uint256 settled = usdc.balanceOf(address(settlementDispatcherReap)) - dispatcherBefore;

        IPriceProvider pp = IPriceProvider(address(priceProvider));
        assertEq(settled, LendSourcingLib.fromUsd(pp, address(usdc), quote), "debit settles the floored conversion exactly");
        assertLe(LendSourcingLib.toUsd(pp, address(usdc), settled), quote, "a debit never settles more value than authorized");
    }

    /// The credit max-spend quote is exactly borrowable across collateral, prior debt, and accrual; one
    /// USD unit more is declined and reverts on Aave (nothing loose to resupply). The settled tokens
    /// always cover the authorized USD (the borrow conversion rounds up).
    /// forge-config: lend.fuzz.runs = 64
    function testFuzz_maxSpendCredit_exactlyExecutable(uint256 collateralWeeth, uint256 priorDebtBps, uint256 warpSecs) public {
        collateralWeeth = bound(collateralWeeth, 0.05 ether, 1 ether);
        priorDebtBps = bound(priorDebtBps, 0, 6000);
        warpSecs = bound(warpSecs, 0, 1 hours);

        _supplyToGateway(address(safe), address(weETH), collateralWeeth);
        uint256 debtAmt = (gw.borrowCapacity(address(safe), address(usdc)) * priorDebtBps) / 10_000;
        if (debtAmt > 0) {
            _borrowOnGateway(address(safe), address(usdc), debtAmt, recipient);
        }
        vm.warp(block.timestamp + warpSecs);
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 quote = cashLens.getMaxSpendCredit(address(safe));
        assertGt(quote, 0, "collateralized safe quotes borrowing power");
        // The quote is pure capacity: canSpend applies the spending limit separately, so the collateral
        // bound above must keep the quote under the daily limit or the spend declines on the limit instead
        assertLt(quote, dailyLimitInUsd, "collateral bound must keep the quote inside the spending limit");

        // The probe runs first, on its own txId: a settled spend at the quote would consume the borrowing
        // power this probe needs to be testing against.
        (bool okPlus,) = _canSpend(keccak256("qePlus"), quote + 1);
        assertFalse(okPlus, "one USD unit past the quote must be declined");
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        _spend(keccak256("qePlus"), quote + 1);

        (bool ok, string memory reason) = _canSpend(txId, quote);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _spend(txId, quote);
        uint256 settled = usdc.balanceOf(address(settlementDispatcherReap)) - dispatcherBefore;

        IPriceProvider pp = IPriceProvider(address(priceProvider));
        assertEq(settled, LendSourcingLib.fromUsdUp(pp, address(usdc), quote), "credit borrows the ceiled conversion exactly");
        assertGe(LendSourcingLib.toUsd(pp, address(usdc), settled), quote, "a credit always covers the authorized value");
    }

    /// The sourceable quote is exactly requestable and pays out in full across supplied/loose splits,
    /// debt, and accrual; one wei more reverts. The revert is unqualified on purpose: which side refuses
    /// depends on the position, Aave's health check when debt caps the pull and the module's balance check
    /// otherwise, and pinning either would make the fuzz assert the position shape rather than the bound.
    /// forge-config: lend.fuzz.runs = 64
    function testFuzz_maxSourceable_exactlyRequestable(uint256 suppliedWeeth, uint256 looseWeeth, uint256 debtBps, uint256 warpSecs) public {
        suppliedWeeth = bound(suppliedWeeth, 0.1 ether, 5 ether);
        looseWeeth = bound(looseWeeth, 0, 1 ether);
        debtBps = bound(debtBps, 0, 7000);
        warpSecs = bound(warpSecs, 0, 1 hours);

        _supplyToGateway(address(safe), address(weETH), suppliedWeeth);
        uint256 debtAmt = (gw.borrowCapacity(address(safe), address(usdc)) * debtBps) / 10_000;
        if (debtAmt > 0) {
            _borrowOnGateway(address(safe), address(usdc), debtAmt, recipient);
        }
        deal(address(weETH), address(safe), looseWeeth);
        vm.warp(block.timestamp + warpSecs);

        uint256 max = cashLens.getMaxSourceable(address(safe), address(weETH));
        assertGt(max, 0, "supplied safe quotes a sourceable amount");

        (address[] memory signers, bytes[] memory signatures) = _signRequestWithdrawal(_addr1(address(weETH)), _uint1(max + 1), withdrawRecipient);
        vm.expectRevert();
        cashModule.requestWithdrawal(address(safe), _addr1(address(weETH)), _uint1(max + 1), withdrawRecipient, signers, signatures);

        _requestWithdrawal(_addr1(address(weETH)), _uint1(max), withdrawRecipient);
        assertEq(weETH.balanceOf(address(safe)), max, "the quote is sourced into the safe exactly");

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(address(safe));
        assertEq(weETH.balanceOf(withdrawRecipient), max, "the recipient is paid the full quote");
    }
}
