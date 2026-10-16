// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IPaymentLinkModule } from "../../src/interfaces/IPaymentLinkModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { CashModuleTestSetup } from "../safe/modules/cash/CashModuleTestSetup.t.sol";
import { FalseReturnToken, FeeOnTransferToken, NegativeRebaseToken, PlainToken, ReentrantToken, SenderTaxToken } from "./PaymentLinkMocks.sol";

/**
 * @title PaymentLinkModuleTestSetup
 * @notice Shared fixture for the PaymentLinkModule suites: the full cash stack from
 *         `CashModuleTestSetup` (forked chain, real CashModule, a 2-of-3 EtherFiSafe on the lend
 *         gateway engine), plus the module behind a UUPS proxy, registered whitelist-only on the
 *         DataProvider and allowed to request withdrawals on the CashModule (spec §2 DEFAULT).
 * @dev Run with: TEST_CHAIN=10 TEST_RPC=<optimism rpc> forge test --match-path "test/payment-link/*"
 */
contract PaymentLinkModuleTestSetup is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    PaymentLinkModule internal plm;

    PlainToken internal plainToken;
    FeeOnTransferToken internal fotToken;
    FalseReturnToken internal falseToken;
    NegativeRebaseToken internal rebaseToken;
    ReentrantToken internal reentrantToken;
    SenderTaxToken internal taxedToken;

    address internal plFeeReceiver = makeAddr("plFeeReceiver");
    address internal relayer = makeAddr("relayer");
    address internal externalRecipient = makeAddr("externalRecipient");

    uint16 internal constant FEE_BPS = 30;
    uint64 internal constant WITHDRAWAL_DELAY = 1 hours;

    uint256 internal linkCounter;

    function setUp() public virtual override {
        super.setUp();

        plm = _deployModule();

        plainToken = new PlainToken("Plain", "PLAIN");
        fotToken = new FeeOnTransferToken();
        falseToken = new FalseReturnToken();
        rebaseToken = new NegativeRebaseToken();
        reentrantToken = new ReentrantToken();
        taxedToken = new SenderTaxToken();

        address[] memory mods = new address[](1);
        mods[0] = address(plm);
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        address[] memory assets = new address[](6);
        assets[0] = address(plainToken);
        assets[1] = address(fotToken);
        assets[2] = address(falseToken);
        assets[3] = address(rebaseToken);
        assets[4] = address(reentrantToken);
        assets[5] = address(taxedToken);
        bool[] memory yesAll = new bool[](6);
        for (uint256 i = 0; i < 6; i++) {
            yesAll[i] = true;
        }

        vm.startPrank(owner);
        dataProvider.configureModules(mods, yes);
        cashModule.configureModulesCanRequestWithdraw(mods, yes);
        cashModule.configureWithdrawAssets(assets, yesAll);
        vm.stopPrank();
        _setWithdrawalDelay(WITHDRAWAL_DELAY);

        deal(address(usdc), address(safe), 1_000_000e6);
        plainToken.mint(address(safe), 1_000_000 ether);
        fotToken.mint(address(safe), 1_000_000 ether);
        falseToken.mint(address(safe), 1_000_000 ether);
        rebaseToken.mint(address(safe), 1_000_000 ether);
        reentrantToken.mint(address(safe), 1_000_000 ether);
        taxedToken.mint(address(safe), 1_000_000 ether);
    }

    // ---- deployment ----

    function _deployModule() internal returns (PaymentLinkModule) {
        address impl = address(new PaymentLinkModule(address(dataProvider), address(cashModule)));
        return PaymentLinkModule(address(new UUPSProxy(impl, abi.encodeCall(PaymentLinkModule.initialize, (address(roleRegistry), FEE_BPS, plFeeReceiver)))));
    }

    /// @dev Sets CashModule's withdrawal delay as the admin, keeping the other delays.
    function _setWithdrawalDelay(uint64 delay) internal {
        (, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        vm.prank(owner);
        cashModule.setDelays(delay, spendLimitDelay, modeDelay);
    }

    // ---- keys and signatures ----

    /// @dev A fresh link key per call; the address is the link ID.
    function _newLinkKey() internal returns (address signer, uint256 pk) {
        linkCounter++;
        (signer, pk) = makeAddrAndKey(string.concat("link-", vm.toString(linkCounter)));
    }

    function _ownerSigs(bytes32 digest) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _sigs(digest, owner1, owner1Pk, owner2, owner2Pk);
    }

    function _sigs(bytes32 digest, address a, uint256 aPk, address b, uint256 bPk) internal pure returns (address[] memory signers, bytes[] memory sigs) {
        signers = new address[](2);
        signers[0] = a;
        signers[1] = b;
        sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(aPk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(bPk, digest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);
    }

    function _claimSig(PaymentLinkModule module, uint256 linkPk, address linkSigner, address recipient) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPk, module.claimDigest(linkSigner, recipient));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The request digest rebuilt from the spec formula, independently of the module's view.
    function _specRequestDigest(address module, address safe_, address token, uint256 amount, address linkSigner, uint16 feeBps, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("requestLink"), block.chainid, module, nonce, safe_, abi.encode(token, amount, linkSigner, feeBps))).toEthSignedMessageHash();
    }

    /// @dev The cancel digest rebuilt from the spec formula.
    function _specCancelDigest(address module, address safe_, address linkSigner, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("cancelLink"), block.chainid, module, nonce, safe_, linkSigner)).toEthSignedMessageHash();
    }

    // ---- lifecycle helpers ----

    function _request(address token, uint256 amount, address linkSigner) internal {
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), token, amount, linkSigner, FEE_BPS));
        vm.prank(relayer);
        plm.requestLink(address(safe), token, amount, linkSigner, FEE_BPS, signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 delay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + delay + 1);
    }

    function _fund() internal {
        _warpPastDelay();
        vm.prank(relayer);
        plm.fundLink(address(safe));
    }

    /// @dev Request + fund a fresh link; returns its key.
    function _fundedLink(address token, uint256 amount) internal returns (address linkSigner, uint256 linkPk) {
        (linkSigner, linkPk) = _newLinkKey();
        _request(token, amount, linkSigner);
        _fund();
    }

    function _claim(address linkSigner, uint256 linkPk, address recipient) internal {
        bytes memory sig = _claimSig(plm, linkPk, linkSigner, recipient);
        vm.prank(relayer);
        plm.claim(linkSigner, recipient, sig);
    }

    function _cancel(address linkSigner) internal {
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));
        vm.prank(relayer);
        plm.cancel(linkSigner, signers, sigs);
    }

    function _status(address linkSigner) internal view returns (IPaymentLinkModule.LinkStatus) {
        return plm.getLink(linkSigner).status;
    }

    function _pendingTokensLength() internal view returns (uint256) {
        return cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length;
    }

    function _bal(address token, address account) internal view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }
}
