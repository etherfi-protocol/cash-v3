// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { console } from "forge-std/console.sol";

import { PaymentLinkConfig } from "../../scripts/payment-link/PaymentLinkConfig.sol";
import { IPaymentLinkModule } from "../../src/interfaces/IPaymentLinkModule.sol";
import { PaymentLinkModuleTestSetup } from "./PaymentLinkModuleTestSetup.t.sol";

/// @dev The launch token list the deploy, verify and enable scripts use.
contract LaunchTokenList is PaymentLinkConfig {
    function tokens() external pure returns (address[] memory) {
        return _launchTokens();
    }
}

/**
 * @title PaymentLinkLaunchTokensTest
 * @notice Round-trips every launch token through the module against the REAL token contract on an
 *         Optimism fork, no mocks: request and fund a link, claim it to an external address
 *         (paying the fee), then request, fund and cancel a second one. Every step asserts exact
 *         balance deltas for the safe, the module, the recipient and the fee receiver, and that
 *         liabilities return to zero. This is the evidence that each token moves exact amounts in
 *         and out of the module, which the allowlist requires. USDC, EURC, USDT0 (6 decimals) and
 *         ZCHF, WETH (18) have their own tests; `test_everyLaunchToken_movesExactAmounts` covers the
 *         whole `_launchTokens()` list and names every token that fails.
 * @dev Run with: TEST_CHAIN=10 TEST_RPC=<optimism rpc> forge test --match-path test/payment-link/PaymentLinkLaunchTokens.t.sol
 */
contract PaymentLinkLaunchTokensTest is PaymentLinkModuleTestSetup {
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address internal constant USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    address internal constant ZCHF = 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev 1,234.567891 units at 6 decimals: odd enough that a rounding or fee bug shows.
    uint256 internal constant LINK_AMOUNT_6 = 1_234_567_891;
    /// @dev 1,234.567890123456789 units at 18 decimals. 30 bps of it is 3,703,703,670,370,370.367,
    ///      so the fee must round down to 3,703,703,670,370,370.
    uint256 internal constant LINK_AMOUNT_18 = 1_234_567_890_123_456_789;
    uint256 internal constant FEE_18 = 3_703_703_670_370_370;

    function test_launchToken_USDC_movesExactAmounts() public {
        _roundTrip(USDC, "USDC", 6, LINK_AMOUNT_6);
    }

    function test_launchToken_EURC_movesExactAmounts() public {
        _roundTrip(EURC, "EURC", 6, LINK_AMOUNT_6);
    }

    function test_launchToken_USDT0_movesExactAmounts() public {
        _roundTrip(USDT0, unicode"USD₮0", 6, LINK_AMOUNT_6);
    }

    /// @dev ZCHF has 18 decimals; the fee on a non-round amount must round down, not up.
    function test_launchToken_ZCHF_movesExactAmounts_feeRoundsDownAt18Decimals() public {
        assertGt(LINK_AMOUNT_18 * FEE_BPS % 10_000, 0, "the amount leaves a fee remainder to round away");
        assertEq(LINK_AMOUNT_18 * FEE_BPS / 10_000, FEE_18);
        uint256 recipientStart = _bal(ZCHF, externalRecipient);
        uint256 feeReceiverStart = _bal(ZCHF, plFeeReceiver);

        _roundTrip(ZCHF, "ZCHF", 18, LINK_AMOUNT_18);

        assertEq(_bal(ZCHF, plFeeReceiver) - feeReceiverStart, FEE_18, "fee rounded down at 18 decimals");
        assertEq(_bal(ZCHF, externalRecipient) - recipientStart, LINK_AMOUNT_18 - FEE_18);
    }

    /// @dev Balances of the four parties, taken once before the round trip.
    struct Start {
        uint256 safe;
        uint256 module;
        uint256 recipient;
        uint256 feeReceiver;
    }

    /// @dev WETH9 at 18 decimals, with the same fee round-down as ZCHF.
    function test_launchToken_WETH_movesExactAmounts_feeRoundsDownAt18Decimals() public {
        uint256 recipientStart = _bal(WETH, externalRecipient);
        uint256 feeReceiverStart = _bal(WETH, plFeeReceiver);

        _roundTrip(WETH, "WETH", 18, LINK_AMOUNT_18);

        assertEq(_bal(WETH, plFeeReceiver) - feeReceiverStart, FEE_18, "fee rounded down at 18 decimals");
        assertEq(_bal(WETH, externalRecipient) - recipientStart, LINK_AMOUNT_18 - FEE_18);
    }

    function _roundTrip(address token, string memory symbol, uint8 decimals, uint256 linkAmount) internal {
        _listAndFund(token, symbol, decimals, linkAmount);
        Start memory b = Start({ safe: _bal(token, address(safe)), module: _bal(token, address(plm)), recipient: _bal(token, externalRecipient), feeReceiver: _bal(token, plFeeReceiver) });

        // 1. Fund: the safe pays exactly the amount and the module receives exactly the amount.
        (address claimed, uint256 claimedPk) = _fundedLink(token, linkAmount);
        assertEq(_bal(token, address(safe)), b.safe - linkAmount, "fund: safe debit");
        assertEq(_bal(token, address(plm)), b.module + linkAmount, "fund: module credit");
        assertEq(plm.getLiabilities(token), linkAmount);

        // 2. Claim to an external address: fee to the receiver, the rest to the recipient.
        uint256 fee = linkAmount * FEE_BPS / 10_000;
        _claim(claimed, claimedPk, externalRecipient);
        assertEq(uint8(_status(claimed)), uint8(IPaymentLinkModule.LinkStatus.Claimed));
        assertEq(_bal(token, externalRecipient), b.recipient + linkAmount - fee, "claim: recipient credit");
        assertEq(_bal(token, plFeeReceiver), b.feeReceiver + fee, "claim: fee receiver credit");
        assertEq(_bal(token, address(plm)), b.module, "claim: module debit");
        assertEq(plm.getLiabilities(token), 0);

        // 3. A second link funds and is cancelled: the safe gets the exact amount back.
        (address cancelled,) = _fundedLink(token, linkAmount);
        assertEq(_bal(token, address(safe)), b.safe - 2 * linkAmount, "second fund: safe debit");
        assertEq(_bal(token, address(plm)), b.module + linkAmount, "second fund: module credit");
        _cancel(cancelled);
        assertEq(uint8(_status(cancelled)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(_bal(token, address(safe)), b.safe - linkAmount, "cancel: safe refund");
        assertEq(_bal(token, address(plm)), b.module, "cancel: module debit");
        assertEq(plm.getLiabilities(token), 0);

        // Net: the safe paid one link; recipient plus fee receiver got exactly that.
        assertEq((_bal(token, externalRecipient) - b.recipient) + (_bal(token, plFeeReceiver) - b.feeReceiver), linkAmount);
    }

    /// @dev Checks the real token's metadata, lists it as withdrawable on the fixture's CashModule
    ///      (local to the fork), allows it on the module as the enable step does in production,
    ///      and funds the safe.
    function _listAndFund(address token, string memory symbol, uint8 decimals, uint256 linkAmount) internal {
        assertGt(token.code.length, 0, "token not deployed on this fork");
        assertEq(IERC20Metadata(token).decimals(), decimals);
        assertEq(IERC20Metadata(token).symbol(), symbol);

        address[] memory assets = new address[](1);
        assets[0] = token;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        vm.startPrank(owner);
        cashModule.configureWithdrawAssets(assets, yes);
        plm.setTokenAllowed(token, true);
        vm.stopPrank();

        deal(token, address(safe), 10 * linkAmount);
        assertEq(_bal(token, address(safe)), 10 * linkAmount, "deal reached the token's balance slot");
    }

    /// @dev Every token the scripts allow, round-tripped one by one. A failure doesn't stop the
    ///      run, so the log names every token that fails before the test does.
    function test_everyLaunchToken_movesExactAmounts() public {
        address[] memory tokens = new LaunchTokenList().tokens();
        uint256 passed;
        uint256 failures;
        for (uint256 i = 0; i < tokens.length; i++) {
            try this.roundTripAny(tokens[i]) {
                passed++;
            } catch Error(string memory reason) {
                failures++;
                console.log("FAIL", tokens[i], reason);
            } catch {
                failures++;
                console.log("FAIL", tokens[i], "(no reason)");
            }
        }
        assertEq(failures, 0, "launch tokens that don't move exact amounts");
        assertEq(passed, tokens.length);
    }

    /// @dev `_roundTrip` for any token: an odd amount of about 1,234.567 units at the token's own
    ///      decimals, with plain `require`s so `test_everyLaunchToken_movesExactAmounts` can catch a
    ///      failure and carry on. External only so it can run under try/catch.
    function roundTripAny(address token) external {
        require(msg.sender == address(this), "self only");
        uint8 decimals = IERC20Metadata(token).decimals();
        uint256 amount = 1234 * 10 ** decimals + (decimals >= 3 ? 567 * 10 ** (decimals - 3) : 0) + (decimals >= 6 ? 891 : 0);

        address[] memory assets = new address[](1);
        assets[0] = token;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        vm.startPrank(owner);
        cashModule.configureWithdrawAssets(assets, yes);
        plm.setTokenAllowed(token, true);
        vm.stopPrank();
        deal(token, address(safe), 10 * amount);
        require(_bal(token, address(safe)) == 10 * amount, "deal: balance slot");

        Start memory b = Start({ safe: _bal(token, address(safe)), module: _bal(token, address(plm)), recipient: _bal(token, externalRecipient), feeReceiver: _bal(token, plFeeReceiver) });

        (address claimed, uint256 claimedPk) = _fundedLink(token, amount);
        require(_bal(token, address(safe)) == b.safe - amount, "fund: safe debit");
        require(_bal(token, address(plm)) == b.module + amount, "fund: module credit");
        require(plm.getLiabilities(token) == amount, "fund: liabilities");

        uint256 fee = amount * FEE_BPS / 10_000;
        _claim(claimed, claimedPk, externalRecipient);
        require(_status(claimed) == IPaymentLinkModule.LinkStatus.Claimed, "claim: status");
        require(_bal(token, externalRecipient) == b.recipient + amount - fee, "claim: recipient credit");
        require(_bal(token, plFeeReceiver) == b.feeReceiver + fee, "claim: fee credit");
        require(_bal(token, address(plm)) == b.module, "claim: module debit");
        require(plm.getLiabilities(token) == 0, "claim: liabilities");

        (address cancelled,) = _fundedLink(token, amount);
        _cancel(cancelled);
        require(_status(cancelled) == IPaymentLinkModule.LinkStatus.Cancelled, "cancel: status");
        require(_bal(token, address(safe)) == b.safe - amount, "cancel: safe refund");
        require(_bal(token, address(plm)) == b.module, "cancel: module debit");
        require(plm.getLiabilities(token) == 0, "cancel: liabilities");
    }
}
