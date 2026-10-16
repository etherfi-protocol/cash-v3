// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Vm } from "forge-std/Vm.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BinSponsor, Cashback, ICashModule, SafeData } from "../../src/interfaces/ICashModule.sol";
import { IPaymentLinkModule } from "../../src/interfaces/IPaymentLinkModule.sol";
import { IPriceProvider } from "../../src/interfaces/IPriceProvider.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { CashVerificationLib } from "../../src/libraries/CashVerificationLib.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { CashLendLib } from "../../src/modules/cash/CashLendLib.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafeErrors } from "../../src/safe/EtherFiSafeErrors.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { SenderTaxToken } from "./PaymentLinkMocks.sol";
import { PaymentLinkModuleTestSetup } from "./PaymentLinkModuleTestSetup.t.sol";

contract PaymentLinkModuleTest is PaymentLinkModuleTestSetup {
    uint256 internal constant AMOUNT = 100e6; // 100 USDC

    uint256 internal originalChainId;

    // ---- initialize / construction ----

    function test_initialize_setsConfig() public view {
        (uint16 feeBps, address receiver) = plm.getFee();
        assertEq(feeBps, FEE_BPS);
        assertEq(receiver, plFeeReceiver);
        assertEq(address(plm.roleRegistry()), address(roleRegistry));
        assertEq(address(plm.cashModule()), address(cashModule));
        assertEq(address(plm.etherFiDataProvider()), address(dataProvider));
        assertEq(plm.MAX_FEE_BPS(), 100);
        assertEq(plm.HUNDRED_PERCENT_IN_BPS(), 10_000);
        assertEq(plm.REQUEST_LINK_SIG(), keccak256("requestLink"));
        assertEq(plm.CANCEL_LINK_SIG(), keccak256("cancelLink"));
        assertFalse(plm.paused());
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        plm.initialize(address(roleRegistry), 0, address(0));
    }

    function test_implementation_initializersDisabled() public {
        PaymentLinkModule impl = new PaymentLinkModule(address(dataProvider), address(cashModule));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(roleRegistry), 0, address(0));
    }

    function test_constructor_revertsOnZeroOrMismatchedCashModule() public {
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new PaymentLinkModule(address(dataProvider), address(0));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new PaymentLinkModule(address(dataProvider), makeAddr("notTheCashModule"));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new PaymentLinkModule(address(0), address(cashModule));
    }

    function test_initialize_validatesInputs() public {
        address impl = address(new PaymentLinkModule(address(dataProvider), address(cashModule)));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new UUPSProxy(impl, abi.encodeCall(PaymentLinkModule.initialize, (address(0), FEE_BPS, plFeeReceiver)));

        vm.expectRevert(IPaymentLinkModule.FeeTooHigh.selector);
        new UUPSProxy(impl, abi.encodeCall(PaymentLinkModule.initialize, (address(roleRegistry), 101, plFeeReceiver)));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new UUPSProxy(impl, abi.encodeCall(PaymentLinkModule.initialize, (address(roleRegistry), 1, address(0))));

        // Fee disabled with no receiver is a valid launch configuration.
        PaymentLinkModule inert = PaymentLinkModule(address(new UUPSProxy(impl, abi.encodeCall(PaymentLinkModule.initialize, (address(roleRegistry), 0, address(0))))));
        (uint16 feeBps, address receiver) = inert.getFee();
        assertEq(feeBps, 0);
        assertEq(receiver, address(0));
    }

    function test_rejectsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(plm).call{ value: 1 }("");
        assertFalse(ok);
    }

    // ---- digests ----

    function test_requestLinkDigest_matchesSpecFormula() public {
        (address linkSigner,) = _newLinkKey();
        assertEq(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS), _specRequestDigest(address(plm), address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, 0));

        _request(address(usdc), AMOUNT, linkSigner);
        assertEq(plm.getNonce(address(safe)), 1);
        // The view tracks the current module nonce, not the safe's own nonce.
        assertEq(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS), _specRequestDigest(address(plm), address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, 1));
    }

    function test_cancelLinkDigest_matchesSpecFormula() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        assertEq(plm.cancelLinkDigest(linkSigner), _specCancelDigest(address(plm), address(safe), linkSigner, 1));
    }

    function test_claimDigest_isEip712OverClaimStruct() public {
        bytes32 domain = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("EtherFi PaymentLinkModule"), keccak256("1"), block.chainid, address(plm)));
        assertEq(plm.DOMAIN_SEPARATOR(), domain);

        address linkSigner = makeAddr("someLink");
        bytes32 structHash = keccak256(abi.encode(keccak256("Claim(address linkSigner,address recipient)"), linkSigner, externalRecipient));
        assertEq(plm.claimDigest(linkSigner, externalRecipient), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        assertEq(plm.CLAIM_TYPEHASH(), keccak256("Claim(address linkSigner,address recipient)"));
    }

    // ---- requestLink ----

    function test_requestLink_withDelay_staysRequested() public {
        (address linkSigner,) = _newLinkKey();
        uint256 safeBalBefore = _bal(address(usdc), address(safe));

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkRequested(address(safe), linkSigner, address(usdc), AMOUNT, FEE_BPS);
        _request(address(usdc), AMOUNT, linkSigner);

        IPaymentLinkModule.Link memory link = plm.getLink(linkSigner);
        assertEq(link.safe, address(safe));
        assertEq(link.token, address(usdc));
        assertEq(link.amount, AMOUNT);
        assertEq(link.feeBps, FEE_BPS);
        assertEq(uint8(link.status), uint8(IPaymentLinkModule.LinkStatus.Requested));
        assertEq(plm.getPendingLink(address(safe)), linkSigner);
        assertEq(plm.getLiabilities(address(usdc)), 0);
        assertEq(plm.getNonce(address(safe)), 1);

        // CashModule holds the hold with this module as recipient; nothing has moved yet.
        SafeData memory data = cashModule.getData(address(safe));
        assertEq(data.pendingWithdrawalRequest.recipient, address(plm));
        assertEq(data.pendingWithdrawalRequest.tokens.length, 1);
        assertEq(data.pendingWithdrawalRequest.tokens[0], address(usdc));
        assertEq(data.pendingWithdrawalRequest.amounts[0], AMOUNT);
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore);
        assertEq(_bal(address(usdc), address(plm)), 0);
    }

    function test_requestLink_zeroDelay_fundsInline() public {
        _setWithdrawalDelay(0);

        (address linkSigner,) = _newLinkKey();
        uint256 safeBalBefore = _bal(address(usdc), address(safe));

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkRequested(address(safe), linkSigner, address(usdc), AMOUNT, FEE_BPS);
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkFunded(address(safe), linkSigner, address(usdc), AMOUNT);
        _request(address(usdc), AMOUNT, linkSigner);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(plm.getPendingLink(address(safe)), address(0));
        assertEq(plm.getLiabilities(address(usdc)), AMOUNT);
        assertEq(_pendingTokensLength(), 0);
        assertEq(_bal(address(usdc), address(plm)), AMOUNT);
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore - AMOUNT);
    }

    function test_requestLink_revertsOnInvalidInput() public {
        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(bytes32(0));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, address(0), FEE_BPS, signers, sigs);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.requestLink(address(safe), address(usdc), 0, linkSigner, FEE_BPS, signers, sigs);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.requestLink(address(safe), address(0), AMOUNT, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_revertsForNonSafe() public {
        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(bytes32(0));
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        plm.requestLink(makeAddr("notASafe"), address(usdc), AMOUNT, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_revertsOnFeeMismatch() public {
        (address linkSigner,) = _newLinkKey();
        uint16 staleFee = FEE_BPS + 1;
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, staleFee));
        vm.expectRevert(IPaymentLinkModule.FeeMismatch.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, staleFee, signers, sigs);
    }

    function test_requestLink_revertsWhileLinkPending() public {
        (address first,) = _newLinkKey();
        _request(address(usdc), AMOUNT, first);

        (address second,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, second, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.PendingLinkExists.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, second, FEE_BPS, signers, sigs);
    }

    function test_requestLink_revertsWhileCashModuleWithdrawalPending() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.PendingWithdrawalExists.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_revertsOnInvalidSignatures() public {
        (address linkSigner,) = _newLinkKey();
        bytes32 digest = plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS);

        // One valid owner signature and one over a different digest: below threshold.
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(digest);
        (, bytes[] memory wrong) = _ownerSigs(keccak256("something else"));
        sigs[1] = wrong[1];
        vm.expectRevert(IPaymentLinkModule.InvalidSignatures.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, signers, sigs);

        // A non-owner signer is rejected by the safe itself.
        (address[] memory badSigners, bytes[] memory badSigs) = _sigs(digest, owner1, owner1Pk, notOwner, notOwnerPk);
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 1));
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, badSigners, badSigs);
    }

    function test_requestLink_signatureBoundToNonce() public {
        (address linkA,) = _newLinkKey();
        (address linkB,) = _newLinkKey();

        // Owners sign B at nonce 0 but A is submitted first and consumes nonce 0.
        (address[] memory signersB, bytes[] memory sigsB) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkB, FEE_BPS));
        _request(address(usdc), AMOUNT, linkA);
        _cancel(linkA);

        vm.expectRevert(IPaymentLinkModule.InvalidSignatures.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkB, FEE_BPS, signersB, sigsB);
    }

    function test_requestLink_signatureBoundToModule() public {
        PaymentLinkModule other = _deployModule();
        (address linkSigner,) = _newLinkKey();
        // Signed for `other` (same nonce 0, same args) and replayed against `plm`.
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(other.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.InvalidSignatures.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_tombstonesUsedSigners() public {
        // Claimed
        (address claimed, uint256 claimedPk) = _fundedLink(address(usdc), AMOUNT);
        _claim(claimed, claimedPk, externalRecipient);
        _expectSignerUsed(claimed);

        // Cancelled while Funded
        (address cancelledFunded,) = _fundedLink(address(usdc), AMOUNT);
        _cancel(cancelledFunded);
        _expectSignerUsed(cancelledFunded);

        // Cancelled while Requested
        (address cancelledRequested,) = _newLinkKey();
        _request(address(usdc), AMOUNT, cancelledRequested);
        _cancel(cancelledRequested);
        _expectSignerUsed(cancelledRequested);

        // RequestCancelled by an owner withdrawal that pre-empts the link
        (address requestCancelled,) = _newLinkKey();
        _request(address(usdc), AMOUNT, requestCancelled);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        assertEq(uint8(_status(requestCancelled)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        _cancelWithdrawal(tokens, amounts, withdrawRecipient);
        _expectSignerUsed(requestCancelled);

        // A funded, still-live link is used too.
        (address live,) = _fundedLink(address(usdc), AMOUNT);
        _expectSignerUsed(live);
    }

    function _expectSignerUsed(address linkSigner) internal {
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.LinkSignerUsed.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_falseReturningToken_zeroDelay_revertsUnexpectedOutcome() public {
        _setWithdrawalDelay(0);

        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(falseToken), 1 ether, linkSigner, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.UnexpectedWithdrawalOutcome.selector);
        plm.requestLink(address(safe), address(falseToken), 1 ether, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_feeOnTransferToken_zeroDelay_revertsUnexpectedOutcome() public {
        _setWithdrawalDelay(0);

        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(fotToken), 1 ether, linkSigner, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.UnexpectedWithdrawalOutcome.selector);
        plm.requestLink(address(safe), address(fotToken), 1 ether, linkSigner, FEE_BPS, signers, sigs);
    }

    function test_requestLink_revertsForNonWithdrawableToken() public {
        PaymentLinkModuleTestSetupToken unlisted = new PaymentLinkModuleTestSetupToken();
        unlisted.mint(address(safe), 1 ether);
        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(unlisted), 1 ether, linkSigner, FEE_BPS));
        vm.expectRevert(abi.encodeWithSelector(ICashModule.InvalidWithdrawAsset.selector, address(unlisted)));
        plm.requestLink(address(safe), address(unlisted), 1 ether, linkSigner, FEE_BPS, signers, sigs);
    }

    // ---- fundLink ----

    function test_fundLink_fundsAfterDelay() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        uint256 safeBalBefore = _bal(address(usdc), address(safe));

        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        plm.fundLink(address(safe));

        _warpPastDelay();
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkFunded(address(safe), linkSigner, address(usdc), AMOUNT);
        vm.prank(makeAddr("anyKeeper"));
        plm.fundLink(address(safe));

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(plm.getPendingLink(address(safe)), address(0));
        assertEq(plm.getLiabilities(address(usdc)), AMOUNT);
        assertEq(_bal(address(usdc), address(plm)), AMOUNT);
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore - AMOUNT);
        assertEq(_pendingTokensLength(), 0);
    }

    function test_fundLink_revertsWithoutPendingLink() public {
        vm.expectRevert(IPaymentLinkModule.NoPendingLink.selector);
        plm.fundLink(address(safe));

        (address linkSigner,) = _fundedLink(address(usdc), AMOUNT);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        vm.expectRevert(IPaymentLinkModule.NoPendingLink.selector);
        plm.fundLink(address(safe));
    }

    function test_fundLink_revertsForNonSafe() public {
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        plm.fundLink(makeAddr("notASafe"));
    }

    function test_fundLink_revertsWhenCashModuleRequestNoLongerMatches() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);

        // For a hold placed before CashModule recorded module requests, and with the module off the
        // requester list, an owner withdrawal replaces the hold WITHOUT calling back, so the link is
        // still Requested but the request is someone else's.
        _dropWithdrawalRecord();
        _setCanRequestWithdraw(false);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Requested));

        _warpPastDelay();
        vm.expectRevert(IPaymentLinkModule.CannotFindMatchingWithdrawal.selector);
        plm.fundLink(address(safe));
    }

    function test_fundLink_feeOnTransfer_revertsAndLinkStaysCancellable() public {
        (address linkSigner,) = _newLinkKey();
        uint256 safeBalBefore = _bal(address(fotToken), address(safe));
        _request(address(fotToken), 1 ether, linkSigner);

        _warpPastDelay();
        vm.expectRevert(IPaymentLinkModule.BalanceDeltaMismatch.selector);
        plm.fundLink(address(safe));

        _cancel(linkSigner);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(_pendingTokensLength(), 0);
        assertEq(_bal(address(fotToken), address(safe)), safeBalBefore);
        assertEq(plm.getLiabilities(address(fotToken)), 0);
    }

    function test_fundLink_falseReturningToken_reverts() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(falseToken), 1 ether, linkSigner);

        _warpPastDelay();
        vm.expectRevert(IPaymentLinkModule.BalanceDeltaMismatch.selector);
        plm.fundLink(address(safe));

        _cancel(linkSigner);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(_pendingTokensLength(), 0);
    }

    // ---- claim ----

    function test_claim_toEtherFiSafe_requestFundClaimWithoutFee() public {
        address safe2 = _deploySecondSafe();
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkClaimed(address(safe), linkSigner, safe2, address(usdc), AMOUNT, 0);
        _claim(linkSigner, linkPk, safe2);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Claimed));
        assertEq(_bal(address(usdc), safe2), AMOUNT);
        assertEq(_bal(address(usdc), plFeeReceiver), 0);
        assertEq(_bal(address(usdc), address(plm)), 0);
        assertEq(plm.getLiabilities(address(usdc)), 0);
    }

    function test_claim_toExternal_paysSnapshottedFeeRoundedDown() public {
        uint256 amount = 1_000_001; // 30 bps of this is 3000.003, rounded down to 3000
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), amount);

        uint256 expectedFee = 3000;
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkClaimed(address(safe), linkSigner, externalRecipient, address(usdc), amount - expectedFee, expectedFee);
        _claim(linkSigner, linkPk, externalRecipient);

        assertEq(_bal(address(usdc), plFeeReceiver), expectedFee);
        assertEq(_bal(address(usdc), externalRecipient), amount - expectedFee);
        assertEq(_bal(address(usdc), address(plm)), 0);
    }

    function test_claim_usesFeeSnapshottedAtRequest() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);

        vm.prank(owner);
        plm.setFee(100, plFeeReceiver);

        _claim(linkSigner, linkPk, externalRecipient);
        assertEq(_bal(address(usdc), plFeeReceiver), AMOUNT * FEE_BPS / 10_000);
    }

    function test_claim_feeWaivedWhenReceiverCleared() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);

        vm.prank(owner);
        plm.setFee(0, address(0));

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkClaimed(address(safe), linkSigner, externalRecipient, address(usdc), AMOUNT, 0);
        _claim(linkSigner, linkPk, externalRecipient);
        assertEq(_bal(address(usdc), externalRecipient), AMOUNT);
    }

    function test_claim_readsLiveFeeReceiver() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        address newReceiver = makeAddr("newFeeReceiver");
        vm.prank(owner);
        plm.setFee(FEE_BPS, newReceiver);

        _claim(linkSigner, linkPk, externalRecipient);
        assertEq(_bal(address(usdc), newReceiver), AMOUNT * FEE_BPS / 10_000);
        assertEq(_bal(address(usdc), plFeeReceiver), 0);
    }

    function test_claim_replayWithOtherRecipientReverts() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        bytes memory sig = _claimSig(plm, linkPk, linkSigner, externalRecipient);
        vm.expectRevert(IPaymentLinkModule.InvalidClaimSignature.selector);
        plm.claim(linkSigner, makeAddr("attacker"), sig);
    }

    function test_claim_replayWithOtherLinkReverts() public {
        (address linkA, uint256 pkA) = _fundedLink(address(usdc), AMOUNT);
        (address linkB,) = _fundedLink(address(usdc), AMOUNT);

        // A's valid claim signature cannot claim B, and A's key cannot sign for B.
        bytes memory sigForA = _claimSig(plm, pkA, linkA, externalRecipient);
        vm.expectRevert(IPaymentLinkModule.InvalidClaimSignature.selector);
        plm.claim(linkB, externalRecipient, sigForA);

        bytes memory aKeyOverB = _claimSig(plm, pkA, linkB, externalRecipient);
        vm.expectRevert(IPaymentLinkModule.InvalidClaimSignature.selector);
        plm.claim(linkB, externalRecipient, aKeyOverB);
    }

    function test_claim_replayFromOtherChainReverts() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        // Kept in storage: via-IR builds (forge coverage --ir-minimum) may otherwise re-read
        // CHAINID after the cheatcode and "restore" the wrong chain.
        originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        bytes memory otherChainSig = _claimSig(plm, linkPk, linkSigner, externalRecipient);
        vm.chainId(originalChainId);
        assertEq(block.chainid, originalChainId);

        vm.expectRevert(IPaymentLinkModule.InvalidClaimSignature.selector);
        plm.claim(linkSigner, externalRecipient, otherChainSig);
    }

    function test_claim_replayFromOtherContractReverts() public {
        PaymentLinkModule other = _deployModule();
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        bytes memory otherContractSig = _claimSig(other, linkPk, linkSigner, externalRecipient);

        vm.expectRevert(IPaymentLinkModule.InvalidClaimSignature.selector);
        plm.claim(linkSigner, externalRecipient, otherContractSig);
    }

    function test_claim_malformedSignatureReverts() public {
        (address linkSigner,) = _fundedLink(address(usdc), AMOUNT);
        vm.expectRevert(IPaymentLinkModule.InvalidClaimSignature.selector);
        plm.claim(linkSigner, externalRecipient, hex"1234");
    }

    function test_claim_revertsOnZeroOrSelfRecipient() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        bytes memory sig = _claimSig(plm, linkPk, linkSigner, address(0));
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.claim(linkSigner, address(0), sig);

        sig = _claimSig(plm, linkPk, linkSigner, address(plm));
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.claim(linkSigner, address(plm), sig);
    }

    function test_claim_revertsUnlessFunded() public {
        (address unused, uint256 unusedPk) = _newLinkKey();
        bytes memory sig = _claimSig(plm, unusedPk, unused, externalRecipient);
        vm.expectRevert(IPaymentLinkModule.LinkNotClaimable.selector);
        plm.claim(unused, externalRecipient, sig);

        (address requested, uint256 requestedPk) = _newLinkKey();
        _request(address(usdc), AMOUNT, requested);
        sig = _claimSig(plm, requestedPk, requested, externalRecipient);
        vm.expectRevert(IPaymentLinkModule.LinkNotClaimable.selector);
        plm.claim(requested, externalRecipient, sig);
    }

    // ---- claim vs cancel ----

    function test_claimThenCancel_onlyClaimSucceeds() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));

        _claim(linkSigner, linkPk, externalRecipient);

        vm.expectRevert(IPaymentLinkModule.LinkNotCancellable.selector);
        plm.cancel(linkSigner, signers, sigs);
    }

    function test_cancelThenClaim_onlyCancelSucceeds() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), AMOUNT);
        bytes memory claimSig = _claimSig(plm, linkPk, linkSigner, externalRecipient);

        _cancel(linkSigner);

        vm.expectRevert(IPaymentLinkModule.LinkNotClaimable.selector);
        plm.claim(linkSigner, externalRecipient, claimSig);
        assertEq(_bal(address(usdc), externalRecipient), 0);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_claimOrCancel_exactlyOneWinner(bool claimFirst, uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 100_000e6);
        uint256 safeBalBefore = _bal(address(usdc), address(safe));
        (address linkSigner, uint256 linkPk) = _fundedLink(address(usdc), amount);
        bytes memory claimSig = _claimSig(plm, linkPk, linkSigner, externalRecipient);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));

        if (claimFirst) {
            plm.claim(linkSigner, externalRecipient, claimSig);
            vm.expectRevert(IPaymentLinkModule.LinkNotCancellable.selector);
            plm.cancel(linkSigner, signers, sigs);
            assertEq(_bal(address(usdc), externalRecipient) + _bal(address(usdc), plFeeReceiver), amount);
            assertEq(_bal(address(usdc), address(safe)), safeBalBefore - amount);
        } else {
            plm.cancel(linkSigner, signers, sigs);
            vm.expectRevert(IPaymentLinkModule.LinkNotClaimable.selector);
            plm.claim(linkSigner, externalRecipient, claimSig);
            assertEq(_bal(address(usdc), externalRecipient), 0);
            assertEq(_bal(address(usdc), address(safe)), safeBalBefore);
        }
        assertEq(_bal(address(usdc), address(plm)), 0);
        assertEq(plm.getLiabilities(address(usdc)), 0);
    }

    // ---- cancel ----

    function test_cancel_requested_releasesCashModuleHold() public {
        (address linkSigner,) = _newLinkKey();
        uint256 safeBalBefore = _bal(address(usdc), address(safe));
        _request(address(usdc), AMOUNT, linkSigner);

        vm.recordLogs();
        _cancel(linkSigner);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(plm.getPendingLink(address(safe)), address(0));
        assertEq(_pendingTokensLength(), 0);
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore);

        // Exactly one LinkCancelled (refund 0) and no LinkRequestCancelled: CashModule's callback no-ops.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 cancelled;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(plm)) continue;
            assertTrue(logs[i].topics[0] != IPaymentLinkModule.LinkRequestCancelled.selector, "callback must no-op");
            if (logs[i].topics[0] == IPaymentLinkModule.LinkCancelled.selector) {
                cancelled++;
                (address token, uint256 refunded) = abi.decode(logs[i].data, (address, uint256));
                assertEq(token, address(usdc));
                assertEq(refunded, 0);
            }
        }
        assertEq(cancelled, 1);
    }

    function test_cancel_funded_refundsSafe() public {
        uint256 safeBalBefore = _bal(address(usdc), address(safe));
        (address linkSigner,) = _fundedLink(address(usdc), AMOUNT);

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkCancelled(address(safe), linkSigner, address(usdc), AMOUNT);
        _cancel(linkSigner);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(plm.getLiabilities(address(usdc)), 0);
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore);
        assertEq(_bal(address(usdc), address(plm)), 0);
        assertEq(_bal(address(usdc), plFeeReceiver), 0);
    }

    function test_cancel_requestedLinkWhoseHoldWasReplaced() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);

        _dropWithdrawalRecord();
        _setCanRequestWithdraw(false);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // The owners' own withdrawal stays pending; cancelling the link must not touch it.
        _cancel(linkSigner);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        SafeData memory data = cashModule.getData(address(safe));
        assertEq(data.pendingWithdrawalRequest.recipient, withdrawRecipient);
    }

    function test_cancel_worksWhilePaused() public {
        (address funded,) = _fundedLink(address(usdc), AMOUNT);
        (address requested,) = _newLinkKey();
        _request(address(usdc), AMOUNT, requested);

        vm.prank(pauser);
        plm.pause();

        _cancel(funded);
        _cancel(requested);
        assertEq(uint8(_status(funded)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(uint8(_status(requested)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(_pendingTokensLength(), 0);
    }

    function test_cancel_worksWhileOracleReverts() public {
        (address funded,) = _fundedLink(address(usdc), AMOUNT);
        (address requested,) = _newLinkKey();
        _request(address(usdc), AMOUNT, requested);

        vm.mockCallRevert(address(priceProvider), bytes(""), "ORACLE_DOWN");
        vm.mockCallRevert(usdcUsdOracle, bytes(""), "ORACLE_DOWN");
        vm.mockCallRevert(ethUsdcOracle, bytes(""), "ORACLE_DOWN");
        vm.mockCallRevert(weEthWethOracle, bytes(""), "ORACLE_DOWN");
        // Sanity: pricing really is down.
        vm.expectRevert(bytes("ORACLE_DOWN"));
        IPriceProvider(address(priceProvider)).price(address(usdc));

        _cancel(requested);
        _cancel(funded);
        assertEq(uint8(_status(funded)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(uint8(_status(requested)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
    }

    function test_cancel_afterOwnerChange_newOwnersCanCancelOldCannot() public {
        (address linkSigner,) = _fundedLink(address(usdc), AMOUNT);
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");

        // Owner 1 is rotated out for a new owner; threshold stays 2 (owners: 2, 3, new).
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = newOwner;
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = false;
        shouldAdd[1] = true;
        _configureOwners(owners, shouldAdd, 2);

        bytes32 digest = plm.cancelLinkDigest(linkSigner);
        (address[] memory oldSigners, bytes[] memory oldSigs) = _sigs(digest, owner1, owner1Pk, owner2, owner2Pk);
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        plm.cancel(linkSigner, oldSigners, oldSigs);

        (address[] memory newSigners, bytes[] memory newSigs) = _sigs(digest, newOwner, newOwnerPk, owner3, owner3Pk);
        plm.cancel(linkSigner, newSigners, newSigs);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
    }

    function test_cancel_signatureBoundToLinkAndNonce() public {
        (address linkA,) = _fundedLink(address(usdc), AMOUNT);
        (address linkB,) = _fundedLink(address(usdc), AMOUNT);

        (address[] memory signers, bytes[] memory sigsA) = _ownerSigs(plm.cancelLinkDigest(linkA));
        // A's cancel signature cannot cancel B.
        vm.expectRevert(IPaymentLinkModule.InvalidSignatures.selector);
        plm.cancel(linkB, signers, sigsA);

        // The failed attempt reverted, so the nonce is unchanged and A's signature still works once.
        plm.cancel(linkA, signers, sigsA);
        assertEq(uint8(_status(linkA)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
    }

    function test_cancel_revertsOnInvalidSignatures() public {
        (address linkSigner,) = _fundedLink(address(usdc), AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(keccak256("not the cancel digest"));
        vm.expectRevert(IPaymentLinkModule.InvalidSignatures.selector);
        plm.cancel(linkSigner, signers, sigs);
    }

    function test_cancel_revertsUnlessRequestedOrFunded() public {
        (address unused,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(unused));
        vm.expectRevert(IPaymentLinkModule.LinkNotCancellable.selector);
        plm.cancel(unused, signers, sigs);

        (address claimed, uint256 claimedPk) = _fundedLink(address(usdc), AMOUNT);
        _claim(claimed, claimedPk, externalRecipient);
        (signers, sigs) = _ownerSigs(plm.cancelLinkDigest(claimed));
        vm.expectRevert(IPaymentLinkModule.LinkNotCancellable.selector);
        plm.cancel(claimed, signers, sigs);

        (address cancelled,) = _fundedLink(address(usdc), AMOUNT);
        _cancel(cancelled);
        (signers, sigs) = _ownerSigs(plm.cancelLinkDigest(cancelled));
        vm.expectRevert(IPaymentLinkModule.LinkNotCancellable.selector);
        plm.cancel(cancelled, signers, sigs);
    }

    // ---- CashModule callback ----

    function test_cardSpend_cancelsPendingRequest_movesLinkToRequestCancelled() public {
        deal(address(usdc), address(safe), 200e6);
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), 150e6, linkSigner);

        // 100 spent against 200 loose with 150 reserved: CashModule cancels the reservation.
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkRequestCancelled(address(safe), linkSigner);
        _spendUsdc(100e6);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        assertEq(plm.getPendingLink(address(safe)), address(0));
        assertEq(_pendingTokensLength(), 0);

        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));
        vm.expectRevert(IPaymentLinkModule.LinkNotCancellable.selector);
        plm.cancel(linkSigner, signers, sigs);
        vm.expectRevert(IPaymentLinkModule.NoPendingLink.selector);
        plm.fundLink(address(safe));

        // The safe can create a new link right away.
        (address next,) = _newLinkKey();
        _request(address(usdc), 50e6, next);
        assertEq(plm.getPendingLink(address(safe)), next);
    }

    function test_cardSpend_callbackRunsWhileModulePaused() public {
        deal(address(usdc), address(safe), 200e6);
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), 150e6, linkSigner);

        vm.prank(pauser);
        plm.pause();

        // A paused module must never block card spending.
        _spendUsdc(100e6);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
    }

    function test_ownerWithdrawalRequest_cancelsPendingLink() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        assertEq(plm.getPendingLink(address(safe)), address(0));
    }

    function test_cancelBridgeByCashModule_onlyCashModule() public {
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        plm.cancelBridgeByCashModule(address(safe));

        vm.prank(owner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        plm.cancelBridgeByCashModule(address(safe));
    }

    function test_cancelBridgeByCashModule_noopWithoutRequestedLink() public {
        // Nothing pending.
        vm.prank(address(cashModule));
        plm.cancelBridgeByCashModule(address(safe));

        // A funded link is never touched.
        (address funded,) = _fundedLink(address(usdc), AMOUNT);
        vm.prank(address(cashModule));
        plm.cancelBridgeByCashModule(address(safe));
        assertEq(uint8(_status(funded)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(plm.getLiabilities(address(usdc)), AMOUNT);
    }

    // ---- reconcile ----

    function test_reconcile_requestedWithoutMatchingRequest_marksRequestCancelled() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);

        _dropWithdrawalRecord();
        _setCanRequestWithdraw(false);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Requested));

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkRequestCancelled(address(safe), linkSigner);
        vm.prank(makeAddr("anyKeeper"));
        plm.reconcile(address(safe));

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        assertEq(plm.getPendingLink(address(safe)), address(0));
        // The owners' own withdrawal is untouched.
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, withdrawRecipient);
    }

    function test_reconcile_requestedWithMatchingRequest_isNoop() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);

        plm.reconcile(address(safe));
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Requested));
        assertEq(plm.getPendingLink(address(safe)), linkSigner);
    }

    function test_reconcile_fundedAndTerminalLinks_unchanged() public {
        plm.reconcile(address(safe)); // nothing at all

        (address funded,) = _fundedLink(address(usdc), AMOUNT);
        (address claimed, uint256 claimedPk) = _fundedLink(address(usdc), AMOUNT);
        _claim(claimed, claimedPk, externalRecipient);
        (address cancelled,) = _fundedLink(address(usdc), AMOUNT);
        _cancel(cancelled);

        vm.recordLogs();
        plm.reconcile(address(safe));
        assertEq(vm.getRecordedLogs().length, 0);

        assertEq(uint8(_status(funded)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(uint8(_status(claimed)), uint8(IPaymentLinkModule.LinkStatus.Claimed));
        assertEq(uint8(_status(cancelled)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(plm.getLiabilities(address(usdc)), AMOUNT);
    }

    function test_reconcile_worksWhilePaused() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        _setCanRequestWithdraw(false);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        vm.prank(pauser);
        plm.pause();
        plm.reconcile(address(safe));
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
    }

    // ---- governance de-whitelisting and surplus rescue ----

    /// @dev Removing the module from CashModule's requester list, the DataProvider whitelist, or both in
    ///      either order only blocks new links. CashModule records the hold as this module's own, so
    ///      nobody else can process it, `fundLink` still funds it and the owners can still cancel it.
    function test_requesterListRemoved_thirdPartyCannotProcess_linkStillFunds() public {
        _assertHoldStaysTheModules(Removal.RequesterListOnly);
    }

    function test_dataProviderRemoved_thirdPartyCannotProcess_linkStillFunds() public {
        _assertHoldStaysTheModules(Removal.DataProviderOnly);
    }

    function test_removed_requesterListFirst_thirdPartyCannotProcess_linkStillFunds() public {
        _assertHoldStaysTheModules(Removal.RequesterListThenDataProvider);
    }

    function test_removed_dataProviderFirst_thirdPartyCannotProcess_linkStillFunds() public {
        _assertHoldStaysTheModules(Removal.DataProviderThenRequesterList);
    }

    function test_removed_requesterListFirst_cancelRequestedReleasesHold() public {
        _assertOwnersCanCancelRequested(Removal.RequesterListThenDataProvider);
    }

    function test_removed_dataProviderFirst_cancelRequestedReleasesHold() public {
        _assertOwnersCanCancelRequested(Removal.DataProviderThenRequesterList);
    }

    /// @dev A card spend or the owners' own withdrawal still reaches `cancelBridgeByCashModule` after
    ///      removal, so the link moves to RequestCancelled without a `reconcile`.
    function test_removed_requesterListFirst_cardSpendCallbackStillArrives() public {
        _assertCallbackStillArrives(Removal.RequesterListThenDataProvider, true);
    }

    function test_removed_dataProviderFirst_ownerWithdrawalCallbackStillArrives() public {
        _assertCallbackStillArrives(Removal.DataProviderThenRequesterList, false);
    }

    function test_removed_newLinksBlocked() public {
        _remove(Removal.DataProviderThenRequesterList);
        (address linkSigner,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS));
        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, linkSigner, FEE_BPS, signers, sigs);
    }

    // A hold placed before CashModule recorded module requests (this module live before that CashModule
    // upgrade) still follows CURRENT list membership, so the module's governance rule applies to it.

    /// @dev Pre-upgrade hold: removing the module from CashModule's requester list lets anyone process the
    ///      hold into the module without `fundLink`. The funds land as surplus; reconcile marks the link
    ///      RequestCancelled; governance returns them with `rescueSurplus`.
    function test_preUpgradeHold_requesterDeWhitelisted_thirdPartyProcessing_isRecoverableViaRescue() public {
        uint256 safeBalBefore = _bal(address(usdc), address(safe));
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        _dropWithdrawalRecord();

        _setCanRequestWithdraw(false);
        _warpPastDelay();
        vm.prank(makeAddr("anyone"));
        cashModule.processWithdrawal(address(safe));

        assertEq(_bal(address(usdc), address(plm)), AMOUNT, "hold processed into the module");
        assertEq(plm.getLiabilities(address(usdc)), 0, "no liability was recorded");
        vm.expectRevert(IPaymentLinkModule.CannotFindMatchingWithdrawal.selector);
        plm.fundLink(address(safe));

        plm.reconcile(address(safe));
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.SurplusRescued(address(usdc), address(safe), AMOUNT);
        vm.prank(owner);
        plm.rescueSurplus(address(usdc), address(safe), AMOUNT);
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore, "sender made whole");
        assertEq(_bal(address(usdc), address(plm)), 0);
    }

    /// @dev Codex pass 2, pre-upgrade hold: rescue is bounded by surplus, so when the token is already in
    ///      a shortfall a misprocessed hold first covers the deficit and the sender is only partially made
    ///      whole.
    function test_preUpgradeHold_requesterDeWhitelisted_inShortfall_misprocessedFundsCoverDeficitFirst() public {
        (address funded, uint256 fundedPk) = _fundedLink(address(rebaseToken), 100 ether);
        (address requested,) = _newLinkKey();
        _request(address(rebaseToken), 100 ether, requested);
        _dropWithdrawalRecord();

        rebaseToken.rebase(4, 5); // module: 80 held against 100 owed
        _setCanRequestWithdraw(false);
        _warpPastDelay();
        cashModule.processWithdrawal(address(safe)); // the Requested link's 100 lands unrecorded
        plm.reconcile(address(safe));
        assertEq(uint8(_status(requested)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        assertEq(_bal(address(rebaseToken), address(plm)), 180 ether);
        assertEq(plm.getLiabilities(address(rebaseToken)), 100 ether);

        vm.startPrank(owner);
        vm.expectRevert(IPaymentLinkModule.InsufficientSurplus.selector);
        plm.rescueSurplus(address(rebaseToken), address(safe), 80 ether + 1);
        plm.rescueSurplus(address(rebaseToken), address(safe), 80 ether);
        vm.stopPrank();

        // The funded link now exits in full: 20 of the misprocessed 100 covered its deficit.
        address recipient = _deploySecondSafe();
        _claim(funded, fundedPk, recipient);
        assertEq(_bal(address(rebaseToken), recipient), 100 ether);
        assertEq(_bal(address(rebaseToken), address(plm)), 0);
    }

    /// @dev Pre-upgrade hold: removing the module from the DataProvider whitelist makes CashModule refuse
    ///      the module's own cancel, so the owners' `cancel` reverts and the link stays consistent. The
    ///      owners recover by replacing the hold with their own withdrawal, then `reconcile`.
    function test_preUpgradeHold_dataProviderDeWhitelisted_cancelRequestedReverts_ownersRecover() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        _dropWithdrawalRecord();

        _remove(Removal.DataProviderOnly);

        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));
        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        plm.cancel(linkSigner, signers, sigs);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Requested));
        assertEq(plm.getPendingLink(address(safe)), linkSigner);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        plm.reconcile(address(safe));
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
    }

    function _assertHoldStaysTheModules(Removal removal) internal {
        (address linkSigner, uint256 linkPk) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        _remove(removal);
        _warpPastDelay();

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(ICashModule.OnlyModuleThatRequestedCanWithdraw.selector);
        cashModule.processWithdrawal(address(safe));
        assertEq(_bal(address(usdc), address(plm)), 0, "nothing processed into the module");

        vm.prank(relayer);
        plm.fundLink(address(safe));
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(plm.getLiabilities(address(usdc)), AMOUNT);

        address recipient = _deploySecondSafe();
        _claim(linkSigner, linkPk, recipient);
        assertEq(_bal(address(usdc), recipient), AMOUNT);
        assertEq(_bal(address(usdc), address(plm)), 0);
    }

    function _assertOwnersCanCancelRequested(Removal removal) internal {
        uint256 safeBalBefore = _bal(address(usdc), address(safe));
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), AMOUNT, linkSigner);
        _remove(removal);

        _cancel(linkSigner);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));
        assertEq(plm.getPendingLink(address(safe)), address(0));
        assertEq(_pendingTokensLength(), 0, "hold released");
        assertEq(_bal(address(usdc), address(safe)), safeBalBefore);
    }

    function _assertCallbackStillArrives(Removal removal, bool viaCardSpend) internal {
        deal(address(usdc), address(safe), 200e6);
        (address linkSigner,) = _newLinkKey();
        _request(address(usdc), 150e6, linkSigner);
        _remove(removal);

        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkRequestCancelled(address(safe), linkSigner);
        if (viaCardSpend) {
            _spendUsdc(100e6); // 100 against 200 loose with 150 reserved: CashModule cancels the hold
        } else {
            address[] memory tokens = new address[](1);
            tokens[0] = address(usdc);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1e6;
            _requestWithdrawal(tokens, amounts, withdrawRecipient);
        }

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        assertEq(plm.getPendingLink(address(safe)), address(0));
    }

    function test_rescueSurplus_boundedByBalanceAboveLiabilities() public {
        _fundedLink(address(usdc), AMOUNT);
        deal(address(usdc), address(plm), AMOUNT + 5e6); // 5 USDC donated on top of the liability

        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        plm.rescueSurplus(address(usdc), externalRecipient, 1);

        vm.startPrank(owner);
        vm.expectRevert(IPaymentLinkModule.InsufficientSurplus.selector);
        plm.rescueSurplus(address(usdc), externalRecipient, 5e6 + 1);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.rescueSurplus(address(usdc), address(0), 1);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.rescueSurplus(address(usdc), address(plm), 1);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.rescueSurplus(address(usdc), externalRecipient, 0);

        plm.rescueSurplus(address(usdc), externalRecipient, 5e6);
        vm.stopPrank();
        assertEq(_bal(address(usdc), externalRecipient), 5e6);
        assertEq(_bal(address(usdc), address(plm)), plm.getLiabilities(address(usdc)));
    }

    function test_rescueSurplus_refusedInShortfall() public {
        _fundedLink(address(rebaseToken), 100 ether);
        rebaseToken.rebase(9, 10);
        vm.prank(owner);
        vm.expectRevert(IPaymentLinkModule.InsufficientSurplus.selector);
        plm.rescueSurplus(address(rebaseToken), externalRecipient, 1);
    }

    function test_rescueSurplus_rejectsTransferThatEatsIntoLiabilities() public {
        SenderTaxToken taxed = new SenderTaxToken();
        taxed.mint(address(plm), 1000);
        // A 900 liability leaves 100 of surplus (written to `liabilities[taxed]` directly).
        bytes32 slot = keccak256(abi.encode(address(taxed), uint256(0x72f6ddc7d992479425dc8c9c22860bd7f83946c3315c4ff3de0873cbf7571b00) + 2));
        vm.store(address(plm), slot, bytes32(uint256(900)));
        assertEq(plm.getLiabilities(address(taxed)), 900);

        // Rescuing all 100 would cost the module 101 and dip into the liability.
        vm.prank(owner);
        vm.expectRevert(IPaymentLinkModule.EscrowShortfall.selector);
        plm.rescueSurplus(address(taxed), externalRecipient, 100);

        vm.prank(owner);
        plm.rescueSurplus(address(taxed), externalRecipient, 99);
        assertGe(_bal(address(taxed), address(plm)), 900);
    }

    // ---- pause ----

    function test_pause_blocksRequestFundClaim() public {
        (address requested,) = _newLinkKey();
        _request(address(usdc), AMOUNT, requested);
        _cancel(requested);
        (address funded, uint256 fundedPk) = _fundedLink(address(usdc), AMOUNT);
        (address pendingLink,) = _newLinkKey();
        _request(address(usdc), AMOUNT, pendingLink);

        vm.prank(pauser);
        plm.pause();

        (address next,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), AMOUNT, next, FEE_BPS));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        plm.requestLink(address(safe), address(usdc), AMOUNT, next, FEE_BPS, signers, sigs);

        _warpPastDelay();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        plm.fundLink(address(safe));

        bytes memory claimSig = _claimSig(plm, fundedPk, funded, externalRecipient);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        plm.claim(funded, externalRecipient, claimSig);

        vm.prank(unpauser);
        plm.unpause();
        plm.claim(funded, externalRecipient, claimSig);
        plm.fundLink(address(safe));
        assertEq(uint8(_status(pendingLink)), uint8(IPaymentLinkModule.LinkStatus.Funded));
    }

    function test_pause_onlyPauserRoles() public {
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        plm.pause();
        vm.prank(pauser);
        plm.pause();
        vm.expectRevert(RoleRegistry.OnlyUnpauser.selector);
        plm.unpause();
    }

    // ---- reentrancy ----

    function test_reentrancy_onClaim_reverts() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(reentrantToken), 10 ether);
        address attacker = makeAddr("attacker");
        bytes memory attackerSig = _claimSig(plm, linkPk, linkSigner, attacker);
        reentrantToken.arm(address(plm), abi.encodeCall(PaymentLinkModule.claim, (linkSigner, attacker, attackerSig)), true);

        bytes memory sig = _claimSig(plm, linkPk, linkSigner, externalRecipient);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        plm.claim(linkSigner, externalRecipient, sig);

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(plm.getLiabilities(address(reentrantToken)), 10 ether);
    }

    function test_reentrancy_onClaim_swallowedReentryCannotDoublePay() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(reentrantToken), 10 ether);
        address attacker = makeAddr("attacker");
        bytes memory attackerSig = _claimSig(plm, linkPk, linkSigner, attacker);
        reentrantToken.arm(address(plm), abi.encodeCall(PaymentLinkModule.claim, (linkSigner, attacker, attackerSig)), false);

        _claim(linkSigner, linkPk, externalRecipient);

        assertEq(reentrantToken.reentryAttempts(), 1);
        assertFalse(reentrantToken.lastReentrySucceeded());
        assertEq(bytes4(reentrantToken.lastReentryError()), ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        assertEq(_bal(address(reentrantToken), attacker), 0);
        uint256 fee = uint256(10 ether) * FEE_BPS / 10_000;
        assertEq(_bal(address(reentrantToken), externalRecipient), 10 ether - fee);
        assertEq(_bal(address(reentrantToken), address(plm)), 0);
        assertEq(plm.getLiabilities(address(reentrantToken)), 0);
    }

    function test_reentrancy_onCancel_reverts() public {
        (address linkSigner, uint256 linkPk) = _fundedLink(address(reentrantToken), 10 ether);
        address attacker = makeAddr("attacker");
        bytes memory attackerSig = _claimSig(plm, linkPk, linkSigner, attacker);
        // The refund to the safe triggers the hook, which tries to claim the same link.
        reentrantToken.arm(address(plm), abi.encodeCall(PaymentLinkModule.claim, (linkSigner, attacker, attackerSig)), true);

        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        plm.cancel(linkSigner, signers, sigs);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));

        // Swallowed variant: the cancel completes and the attacker gets nothing.
        reentrantToken.arm(address(plm), abi.encodeCall(PaymentLinkModule.claim, (linkSigner, attacker, attackerSig)), false);
        uint256 safeBalBefore = _bal(address(reentrantToken), address(safe));
        plm.cancel(linkSigner, signers, sigs);
        assertFalse(reentrantToken.lastReentrySucceeded());
        assertEq(_bal(address(reentrantToken), attacker), 0);
        assertEq(_bal(address(reentrantToken), address(safe)), safeBalBefore + 10 ether);
    }

    function test_reentrancy_onFund_isBlocked() public {
        (address linkSigner,) = _newLinkKey();
        _request(address(reentrantToken), 10 ether, linkSigner);
        _warpPastDelay();

        // The safe's transfer into the module re-enters fundLink; swallowed so the outer call completes.
        reentrantToken.arm(address(plm), abi.encodeCall(PaymentLinkModule.fundLink, (address(safe))), false);
        plm.fundLink(address(safe));
        assertFalse(reentrantToken.lastReentrySucceeded());
        assertEq(bytes4(reentrantToken.lastReentryError()), ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        assertEq(plm.getLiabilities(address(reentrantToken)), 10 ether);
        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.Funded));
    }

    // ---- shortfall (negative rebase) ----

    function test_negativeRebase_proRataPayoutsAndOtherTokensUnaffected() public {
        (address r1, uint256 r1Pk) = _fundedLink(address(rebaseToken), 100 ether);
        (address r2,) = _fundedLink(address(rebaseToken), 300 ether);
        (address u, uint256 uPk) = _fundedLink(address(usdc), AMOUNT);
        (address p,) = _fundedLink(address(plainToken), 50 ether);

        // -10% for every holder, including the module.
        rebaseToken.rebase(9, 10);
        assertEq(_bal(address(rebaseToken), address(plm)), 360 ether);
        assertEq(plm.getLiabilities(address(rebaseToken)), 400 ether);

        // r1: 100 * 360 / 400 = 90 gross, fee on the gross.
        uint256 r1Gross = Math.mulDiv(100 ether, 360 ether, 400 ether);
        uint256 r1Fee = r1Gross * FEE_BPS / 10_000;
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkClaimed(address(safe), r1, externalRecipient, address(rebaseToken), r1Gross - r1Fee, r1Fee);
        _claim(r1, r1Pk, externalRecipient);
        assertEq(r1Gross, 90 ether);

        // r2: 300 * 270 / 300 = 270, refunded to the safe with no fee.
        uint256 safeBefore = _bal(address(rebaseToken), address(safe));
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.LinkCancelled(address(safe), r2, address(rebaseToken), 270 ether);
        _cancel(r2);
        assertEq(_bal(address(rebaseToken), address(safe)), safeBefore + 270 ether);
        assertEq(plm.getLiabilities(address(rebaseToken)), 0);
        assertEq(_bal(address(rebaseToken), address(plm)), 0);

        // Other tokens pay in full.
        _claim(u, uPk, externalRecipient);
        assertEq(_bal(address(usdc), externalRecipient), AMOUNT - AMOUNT * FEE_BPS / 10_000);
        uint256 safePlainBefore = _bal(address(plainToken), address(safe));
        _cancel(p);
        assertEq(_bal(address(plainToken), address(safe)), safePlainBefore + 50 ether);
    }

    function test_escrowShortfall_blocksNewRequestsAndFunding_cancelStillWorks() public {
        _fundedLink(address(rebaseToken), 100 ether);
        (address requested,) = _newLinkKey();
        _request(address(rebaseToken), 10 ether, requested);

        rebaseToken.rebase(1, 2);

        _warpPastDelay();
        vm.expectRevert(IPaymentLinkModule.EscrowShortfall.selector);
        plm.fundLink(address(safe));

        _cancel(requested);
        assertEq(uint8(_status(requested)), uint8(IPaymentLinkModule.LinkStatus.Cancelled));

        (address next,) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(rebaseToken), 1 ether, next, FEE_BPS));
        vm.expectRevert(IPaymentLinkModule.EscrowShortfall.selector);
        plm.requestLink(address(safe), address(rebaseToken), 1 ether, next, FEE_BPS, signers, sigs);

        // Other tokens are unaffected.
        _request(address(usdc), AMOUNT, next);
        assertEq(plm.getPendingLink(address(safe)), next);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_negativeRebase_proRataNeverOverpays(uint96 a1, uint96 a2, uint96 a3, uint16 keepBps, bool firstClaims) public {
        uint256[3] memory amounts = [bound(a1, 1, 100_000 ether), bound(a2, 1, 100_000 ether), bound(a3, 1, 100_000 ether)];
        keepBps = uint16(bound(keepBps, 0, 10_000));

        address[3] memory signers_;
        uint256[3] memory pks;
        uint256 total;
        for (uint256 i = 0; i < 3; i++) {
            (signers_[i], pks[i]) = _fundedLink(address(rebaseToken), amounts[i]);
            total += amounts[i];
        }
        rebaseToken.rebase(keepBps, 10_000);
        uint256 escrowAfterRebase = _bal(address(rebaseToken), address(plm));

        uint256 paidOut;
        for (uint256 i = 0; i < 3; i++) {
            uint256 balance = _bal(address(rebaseToken), address(plm));
            uint256 liabilities = plm.getLiabilities(address(rebaseToken));
            uint256 expected = balance >= liabilities ? amounts[i] : Math.mulDiv(amounts[i], balance, liabilities);
            uint256 recipientBefore = _bal(address(rebaseToken), address(safe));
            if (i == 0 && firstClaims) {
                address recipient = _deploySecondSafe();
                _claim(signers_[i], pks[i], recipient);
                assertEq(_bal(address(rebaseToken), recipient), expected, "claim to safe pays the pro-rata gross, no fee");
            } else {
                _cancel(signers_[i]);
                assertEq(_bal(address(rebaseToken), address(safe)) - recipientBefore, expected, "cancel refunds the pro-rata gross");
            }
            assertLe(expected, amounts[i]);
            paidOut += expected;
        }
        assertEq(plm.getLiabilities(address(rebaseToken)), 0);
        assertLe(paidOut, escrowAfterRebase, "never pays out more than the escrow holds");
        assertLe(escrowAfterRebase, total);
    }

    // ---- fees ----

    function test_setFee_onlyAdminTimelock() public {
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        plm.setFee(10, plFeeReceiver);

        // ADMIN_ROLE alone is not enough.
        address admin = makeAddr("adminOnly");
        vm.prank(owner);
        roleRegistry.grantRole(keccak256("ADMIN_ROLE"), admin);
        vm.prank(admin);
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        plm.setFee(10, plFeeReceiver);
    }

    function test_setFee_validatesAndEmits() public {
        vm.startPrank(owner);
        vm.expectRevert(IPaymentLinkModule.FeeTooHigh.selector);
        plm.setFee(101, plFeeReceiver);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        plm.setFee(1, address(0));

        address newReceiver = makeAddr("newReceiver");
        vm.expectEmit(true, true, true, true, address(plm));
        emit IPaymentLinkModule.FeeSet(FEE_BPS, 100, plFeeReceiver, newReceiver);
        plm.setFee(100, newReceiver);
        (uint16 feeBps, address receiver) = plm.getFee();
        assertEq(feeBps, 100);
        assertEq(receiver, newReceiver);

        plm.setFee(0, address(0));
        (feeBps, receiver) = plm.getFee();
        assertEq(feeBps, 0);
        assertEq(receiver, address(0));
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_claimFee_roundsDownAndConserves(uint96 rawAmount, uint16 rawFee, bool toSafe) public {
        uint16 feeBps = uint16(bound(rawFee, 0, 100));
        uint256 amount = bound(rawAmount, 1, 500_000e6);
        vm.prank(owner);
        plm.setFee(feeBps, plFeeReceiver);

        (address linkSigner, uint256 linkPk) = _newLinkKey();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(usdc), amount, linkSigner, feeBps));
        plm.requestLink(address(safe), address(usdc), amount, linkSigner, feeBps, signers, sigs);
        _fund();

        address recipient = toSafe ? _deploySecondSafe() : externalRecipient;
        _claim(linkSigner, linkPk, recipient);

        uint256 expectedFee = toSafe ? 0 : amount * feeBps / 10_000;
        assertEq(_bal(address(usdc), plFeeReceiver), expectedFee);
        assertEq(_bal(address(usdc), recipient), amount - expectedFee);
        assertEq(_bal(address(usdc), address(plm)), 0);
    }

    // ---- upgrade ----

    function test_upgrade_onlyRoleRegistryOwner_preservesState() public {
        (address funded,) = _fundedLink(address(usdc), AMOUNT);
        (address requested,) = _newLinkKey();
        _request(address(usdc), AMOUNT, requested);

        address newImpl = address(new PaymentLinkModule(address(dataProvider), address(cashModule)));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        UUPSUpgradeable(address(plm)).upgradeToAndCall(newImpl, "");

        vm.prank(owner);
        UUPSUpgradeable(address(plm)).upgradeToAndCall(newImpl, "");
        assertEq(address(uint160(uint256(vm.load(address(plm), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))), newImpl);

        assertEq(uint8(_status(funded)), uint8(IPaymentLinkModule.LinkStatus.Funded));
        assertEq(plm.getPendingLink(address(safe)), requested);
        assertEq(plm.getLiabilities(address(usdc)), AMOUNT);
        assertEq(plm.getNonce(address(safe)), 2);
        (uint16 feeBps, address receiver) = plm.getFee();
        assertEq(feeBps, FEE_BPS);
        assertEq(receiver, plFeeReceiver);
    }

    // ---- helpers ----

    enum Removal {
        RequesterListOnly,
        DataProviderOnly,
        RequesterListThenDataProvider,
        DataProviderThenRequesterList
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant CASH_MODULE_STORAGE_LOCATION = 0xe000c7adec5855bcf51f74b73aa86172d0a325bc54c3f73cb406d259df90ea00;

    function _remove(Removal removal) internal {
        address[] memory mods = new address[](1);
        mods[0] = address(plm);
        bool[] memory no = new bool[](1);
        vm.startPrank(owner);
        if (removal == Removal.RequesterListOnly) {
            cashModule.configureModulesCanRequestWithdraw(mods, no);
        } else if (removal == Removal.DataProviderOnly) {
            dataProvider.configureModules(mods, no);
        } else if (removal == Removal.RequesterListThenDataProvider) {
            cashModule.configureModulesCanRequestWithdraw(mods, no);
            dataProvider.configureModules(mods, no);
        } else {
            dataProvider.configureModules(mods, no);
            cashModule.configureModulesCanRequestWithdraw(mods, no);
        }
        vm.stopPrank();
    }

    /// @dev Models a hold placed before CashModule recorded module requests (SafeCashConfig slot 17,
    ///      byte 15: withdrawalRequestedByModule). CashModule then applies current list membership to it.
    function _dropWithdrawalRecord() internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(address(safe), CASH_MODULE_STORAGE_LOCATION))) + 17);
        uint256 word = uint256(vm.load(address(cashModule), slot));
        require((word >> 120) & 0xff == 1, "no record to drop");
        vm.store(address(cashModule), slot, bytes32(word & ~(uint256(0xff) << 120)));
    }

    function _setCanRequestWithdraw(bool allowed) internal {
        address[] memory mods = new address[](1);
        mods[0] = address(plm);
        bool[] memory flags = new bool[](1);
        flags[0] = allowed;
        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(mods, flags);
    }

    function _spendUsdc(uint256 amountUsd) internal {
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amountUsd;
        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256(abi.encode("spend", block.timestamp, amountUsd)), BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    uint256 internal safeSaltCounter;

    function _deploySecondSafe() internal returns (address) {
        safeSaltCounter++;
        bytes32 salt = keccak256(abi.encode("payment-link-recipient-safe", safeSaltCounter));
        address[] memory owners = new address[](1);
        owners[0] = makeAddr(string.concat("recipientSafeOwner", vm.toString(safeSaltCounter)));
        vm.prank(owner);
        safeFactory.deployEtherFiSafe(salt, owners, new address[](0), new bytes[](0), 1);
        address deployed = safeFactory.getDeterministicAddress(salt);
        assertTrue(dataProvider.isEtherFiSafe(deployed));
        return deployed;
    }
}

/// @dev A token that is NOT on CashModule's withdraw-asset list.
contract PaymentLinkModuleTestSetupToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// @dev The link is requested and the module removed from both whitelists in setUp, a transaction before each
///      test, so the callback writes persisted storage starting cold: what it costs when a cancel lands later.
contract PaymentLinkModuleCallbackGasTest is PaymentLinkModuleTestSetup {
    using MessageHashUtils for bytes32;

    address internal linkSigner;

    function setUp() public override {
        super.setUp();
        (linkSigner,) = _newLinkKey();
        _request(address(usdc), 100e6, linkSigner);

        address[] memory mods = new address[](1);
        mods[0] = address(plm);
        bool[] memory no = new bool[](1);
        vm.startPrank(owner);
        cashModule.configureModulesCanRequestWithdraw(mods, no);
        dataProvider.configureModules(mods, no);
        vm.stopPrank();
    }

    /// @dev CashModule caps the gas it gives a removed module's callback; ours must fit with room to spare.
    function test_cancelBridgeByCashModule_fitsRemovedModuleGasCap() public {
        vm.prank(address(cashModule));
        uint256 gasBefore = gasleft();
        plm.cancelBridgeByCashModule(address(safe));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        assertLt(gasUsed, CashLendLib.REMOVED_MODULE_CALLBACK_GAS / 2, "callback too close to CashModule's cap");
    }

    /// @dev Whoever relays the owners' replacement withdrawal picks its gas limit, but cannot make CashModule's
    ///      capped callback into this removed module run out of gas while the replacement succeeds. Finds a cheap
    ///      successful limit, then sweeps every limit from far below it to 100k above it in 1k steps: each one that
    ///      succeeds must have moved the link to RequestCancelled. Past that range a successful call leaves the
    ///      callback the full cap.
    function test_removedModuleCallback_notStarvableByOuterGasLimit() public {
        bytes memory replacement = _ownerWithdrawalCall(1e6);
        uint256 snapshot = vm.snapshotState();

        uint256 lo = 50_000;
        uint256 hi = 5_000_000;
        assertTrue(_probe(replacement, hi));
        vm.revertToState(snapshot);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_probe(replacement, mid)) hi = mid;
            else lo = mid;
            vm.revertToState(snapshot);
        }

        uint256 successes;
        for (uint256 gasLimit = 50_000; gasLimit <= hi + 100_000; gasLimit += 1_000) {
            if (_probe(replacement, gasLimit)) successes++;
            vm.revertToState(snapshot);
        }
        assertGt(successes, 0);
    }

    function _probe(bytes memory callData, uint256 gasLimit) internal returns (bool ok) {
        (ok,) = address(cashModule).call{ gas: gasLimit }(callData);
        if (ok) assertEq(uint8(_status(linkSigner)), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled), "replacement succeeded with the callback starved");
    }

    /// @dev Owner-signed CashModule requestWithdrawal of `amount` USDC to withdrawRecipient, as calldata
    function _ownerWithdrawalCall(uint256 amount) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(digest);
        return abi.encodeCall(ICashModule.requestWithdrawal, (address(safe), tokens, amounts, withdrawRecipient, signers, sigs));
    }
}
