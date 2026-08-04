// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, Cashback, Mode, SafeData } from "../../../../../src/interfaces/ICashModule.sol";
import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";

/**
 * @title ParityFuzzBase
 * @notice Shared harness for the canSpend/spend parity fuzz on both engines. Two properties:
 *         approvals settle — canSpend == true implies spend succeeds at the same state, except inside a
 *         pending-mode window, where the lens deliberately previews the incoming mode ("pending counts")
 *         and the promise is eventual: the spend succeeds once the mode matures (the backend retries
 *         with the same txId);
 *         declines stay conservative — a declined check that still settles must be one of the engine's
 *         enumerated conservative asymmetries (the lens declining what execution can fund); anything
 *         unexplained is a bug.
 * @dev The pending-withdrawal class is classified by observation (the request existed before the spend
 *      and the spend cancelled it), so it is self-verifying; engine-specific classes come from _classify's
 *      pre-spend predicates. Ghost counters expose which classes a campaign actually hit; each concrete
 *      file pairs the fuzz with deterministic witnesses so an unreachable class is visible in review.
 */
abstract contract ParityFuzzBase is CashModuleTestSetup {
    /// How a declined-but-settled spend is explained. Unexplained fails the property.
    enum Divergence {
        Unexplained,
        ModeWindow, // lens previewed the incoming mode, execution ran the current one
        BufferedFloor, // lens quoted with the min-health-factor buffer, execution kept Aave's raw bound
        PendingWithdrawalReserved, // lens refused to touch the reservation, execution cancelled the withdrawal
        ResupplyInvisible // lens ignores loose collateral a credit spend can resupply
    }

    Cashback[] internal noCashback;

    uint256 public hitsModeWindow;
    uint256 public hitsBufferedFloor;
    uint256 public hitsPendingWithdrawalReserved;
    uint256 public hitsResupplyInvisible;

    /// External so the parity check can try/catch the spend's revert.
    function externalSpend(bytes32 txId_, address token, uint256 amountUsd) external {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId_, BinSponsor.Reap, tokens, amounts, noCashback);
    }

    /// Engine-specific pre-spend classification of a potential declined-but-settled spend.
    function _classify(address, uint256) internal view virtual returns (Divergence) {
        return Divergence.Unexplained;
    }

    /// The lens previews a different mode than execution runs: a pending mode change (or opt-out rail)
    /// whose start time has not strictly passed.
    function _modeWindowOpen() internal view returns (bool) {
        SafeData memory data = cashModule.getData(address(safe));
        return data.incomingModeStartTime != 0 && block.timestamp <= data.incomingModeStartTime && data.incomingMode != data.mode;
    }

    /// Runs canSpend then spend at the current state and asserts both parity properties.
    function _assertParity(bytes32 txId_, address token, uint256 amountUsd) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;

        // ----- the check side: the lens verdict the backend would approve the card auth on
        (bool lensApproved, string memory declineReason) = cashLens.canSpend(address(safe), txId_, tokens, amounts);

        // ----- classification facts, read before the spend mutates state
        bool windowOpen = _modeWindowOpen();
        Divergence class = lensApproved ? Divergence.Unexplained : _classify(token, amountUsd);
        bool hadPendingRequest = cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length > 0;
        uint256 pendingStartTime = cashModule.getData(address(safe)).incomingModeStartTime;

        // ----- the execution side: the settlement attempt
        bool spendSettled;
        try this.externalSpend(txId_, token, amountUsd) {
            spendSettled = true;
        } catch { }

        // ----- approvals settle: an approved auth must land, retried past maturity inside a mode window
        if (lensApproved && !spendSettled && windowOpen) {
            // Eventual parity: the backend retries the same txId; the approval must settle once the
            // previewed mode matures.
            vm.warp(pendingStartTime + 1);
            try this.externalSpend(txId_, token, amountUsd) {
                spendSettled = true;
            } catch { }
            assertTrue(spendSettled, "approved auth failed to settle after the mode matured");
        } else if (lensApproved) {
            assertTrue(spendSettled, "approved auth failed to settle");
        }

        // ----- declines stay conservative: a declined-but-settled spend must be a known asymmetry
        if (!lensApproved && spendSettled) {
            if (hadPendingRequest && cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length == 0) {
                // Observed, not predicted: the spend could only settle by consuming the reservation
                class = Divergence.PendingWithdrawalReserved;
            } else if (class == Divergence.Unexplained && windowOpen) {
                class = Divergence.ModeWindow;
            }
            assertTrue(class != Divergence.Unexplained, string.concat("unexplained divergence, declined as: ", declineReason));
            _count(class);
        }

        // ----- bookkeeping: anything that settled must have cleared its transaction id
        if (spendSettled) {
            assertTrue(cashModule.transactionCleared(address(safe), txId_), "settled spend must clear its txId");
        }
    }

    /// Bumps the ghost counter for the divergence class a declined-but-settled spend was explained by.
    function _count(Divergence class) private {
        if (class == Divergence.ModeWindow) hitsModeWindow++;
        else if (class == Divergence.BufferedFloor) hitsBufferedFloor++;
        else if (class == Divergence.PendingWithdrawalReserved) hitsPendingWithdrawalReserved++;
        else if (class == Divergence.ResupplyInvisible) hitsResupplyInvisible++;
    }
}
