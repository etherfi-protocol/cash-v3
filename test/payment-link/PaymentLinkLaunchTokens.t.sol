// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { IPaymentLinkModule } from "../../src/interfaces/IPaymentLinkModule.sol";
import { PaymentLinkModuleTestSetup } from "./PaymentLinkModuleTestSetup.t.sol";

/**
 * @title PaymentLinkLaunchTokensTest
 * @notice Round-trips each launch token through the module against the REAL token contract on an
 *         Optimism fork, no mocks: request and fund a link, claim it to an external address
 *         (paying the fee), then request, fund and cancel a second one. Every step asserts exact
 *         balance deltas for the safe, the module, the recipient and the fee receiver, and that
 *         liabilities return to zero. This is the evidence that each token moves exact amounts in
 *         and out of the module, which the allowlist requires.
 * @dev Run with: TEST_CHAIN=10 TEST_RPC=<optimism rpc> forge test --match-path test/payment-link/PaymentLinkLaunchTokens.t.sol
 */
contract PaymentLinkLaunchTokensTest is PaymentLinkModuleTestSetup {
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address internal constant USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;

    /// @dev 1,234.567891 units at 6 decimals: odd enough that a rounding or fee bug shows.
    uint256 internal constant LINK_AMOUNT = 1_234_567_891;

    function test_launchToken_USDC_movesExactAmounts() public {
        _roundTrip(USDC, "USDC");
    }

    function test_launchToken_EURC_movesExactAmounts() public {
        _roundTrip(EURC, "EURC");
    }

    function test_launchToken_USDT0_movesExactAmounts() public {
        _roundTrip(USDT0, unicode"USD₮0");
    }

    function _roundTrip(address token, string memory symbol) internal {
        assertGt(token.code.length, 0, "token not deployed on this fork");
        assertEq(IERC20Metadata(token).decimals(), 6);
        assertEq(IERC20Metadata(token).symbol(), symbol);

        // The fixture's CashModule is local to the fork: list the token as withdrawable there and
        // allow it on the module, as the enable step does in production.
        address[] memory assets = new address[](1);
        assets[0] = token;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        vm.startPrank(owner);
        cashModule.configureWithdrawAssets(assets, yes);
        plm.setTokenAllowed(token, true);
        vm.stopPrank();

        deal(token, address(safe), 10 * LINK_AMOUNT);
        assertEq(_bal(token, address(safe)), 10 * LINK_AMOUNT, "deal reached the token's balance slot");

        uint256 safeStart = _bal(token, address(safe));
        uint256 moduleStart = _bal(token, address(plm));
        uint256 recipientStart = _bal(token, externalRecipient);
        uint256 feeReceiverStart = _bal(token, plFeeReceiver);

        // 1. Fund: the safe pays exactly the amount and the module receives exactly the amount.
        (address claimed, uint256 claimedPk) = _fundedLink(token, LINK_AMOUNT);
        assertEq(_bal(token, address(safe)), safeStart - LINK_AMOUNT, "fund: safe debit");
        assertEq(_bal(token, address(plm)), moduleStart + LINK_AMOUNT, "fund: module credit");
        assertEq(plm.getLiabilities(token), LINK_AMOUNT);

        // 2. Claim to an external address: fee to the receiver, the rest to the recipient.
        uint256 fee = LINK_AMOUNT * FEE_BPS / 10_000;
        _claim(claimed, claimedPk, externalRecipient);
        assertEq(uint8(_status(claimed)), uint8(IPaymentLinkModule.LinkStatus.Claimed));
        assertEq(_bal(token, externalRecipient), recipientStart + LINK_AMOUNT - fee, "claim: recipient credit");
        assertEq(_bal(token, plFeeReceiver), feeReceiverStart + fee, "claim: fee receiver credit");
        assertEq(_bal(token, address(plm)), moduleStart, "claim: module debit");
        assertEq(plm.getLiabilities(token), 0);

        // 3. A second link funds and is cancelled: the safe gets the exact amount back.
        (address cancelled,) = _fundedLink(token, LINK_AMOUNT);
        assertEq(_bal(token, address(safe)), safeStart - 2 * LINK_AMOUNT, "second fund: safe debit");
        assertEq(_bal(token, address(plm)), moduleStart + LINK_AMOUNT, "second fund: module credit");
        _cancel(cancelled);
        assertEq(uint8(_status(cancelled)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(_bal(token, address(safe)), safeStart - LINK_AMOUNT, "cancel: safe refund");
        assertEq(_bal(token, address(plm)), moduleStart, "cancel: module debit");
        assertEq(plm.getLiabilities(token), 0);

        // Net: the safe paid one link; recipient plus fee receiver got exactly that.
        assertEq((_bal(token, externalRecipient) - recipientStart) + (_bal(token, plFeeReceiver) - feeReceiverStart), LINK_AMOUNT);
    }
}
