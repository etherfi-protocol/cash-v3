// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IPaymentLinkModule } from "../../src/interfaces/IPaymentLinkModule.sol";
import { CashVerificationLib } from "../../src/libraries/CashVerificationLib.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { PlainToken } from "./PaymentLinkMocks.sol";
import { PaymentLinkModuleTestSetup } from "./PaymentLinkModuleTestSetup.t.sol";

/**
 * @title PaymentLinkHandler
 * @notice Drives random sequences of payment-link lifecycle calls against the real CashModule:
 *         owner-signed requests (zero and non-zero withdrawal delay), permissionless funding,
 *         claims to a safe or an external address, owner cancels, owner withdrawals that make
 *         CashModule cancel the pending request through the callback, reconciles, fee changes,
 *         direct donations to the module and governance rescues of that surplus. Every call is bounded to mostly succeed; ghost
 *         variables record what the module should owe so the invariants can check it exactly.
 */
contract PaymentLinkHandler is Test {
    using MessageHashUtils for bytes32;

    PaymentLinkModule internal immutable plm;
    ICashModule internal immutable cashModule;
    EtherFiSafe internal immutable safe;
    address internal immutable admin;
    address internal immutable recipientSafe;
    address internal immutable externalRecipient = makeAddr("invariantExternalRecipient");
    uint256 internal immutable owner1Pk;
    uint256 internal immutable owner2Pk;
    address internal immutable owner1;
    address internal immutable owner2;

    PlainToken[2] internal tokens;

    address[] public linkSigners;
    mapping(address => uint256) public linkPk;

    /// @notice Per token: total funded, total exited (claim gross + cancel refund) and surplus
    ///         (donated minus rescued).
    mapping(address => uint256) public ghostFunded;
    mapping(address => uint256) public ghostExited;
    mapping(address => uint256) public ghostDonated;

    /// @notice Highest status rank ever observed per link, to check transitions never go back.
    mapping(address => uint8) public ghostStatus;

    uint256 public opsExecuted;
    uint256 public fundedCount;
    uint256 public claimedCount;
    uint256 public cancelledCount;
    uint256 public requestCancelledCount;

    constructor(PaymentLinkModule _plm, ICashModule _cashModule, EtherFiSafe _safe, address _admin, address _recipientSafe, PlainToken tokenA, PlainToken tokenB, uint256 _owner1Pk, uint256 _owner2Pk) {
        plm = _plm;
        cashModule = _cashModule;
        safe = _safe;
        admin = _admin;
        recipientSafe = _recipientSafe;
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        owner1Pk = _owner1Pk;
        owner2Pk = _owner2Pk;
        owner1 = vm.addr(_owner1Pk);
        owner2 = vm.addr(_owner2Pk);
    }

    function tokenAt(uint256 i) external view returns (address) {
        return address(tokens[i]);
    }

    function linkCount() external view returns (uint256) {
        return linkSigners.length;
    }

    // ---- actions ----

    function requestLink(uint256 tokenSeed, uint256 amount, bool zeroDelay) external {
        if (plm.getPendingLink(address(safe)) != address(0)) return;
        if (cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length != 0) return;

        PlainToken token = tokens[tokenSeed % 2];
        amount = bound(amount, 1, 1_000_000 ether);
        token.mint(address(safe), amount);

        _setDelay(zeroDelay ? 0 : 1 hours);

        uint256 pk = 0xA11CE + linkSigners.length;
        address linkSigner = vm.addr(pk);
        (uint16 feeBps,) = plm.getFee();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.requestLinkDigest(address(safe), address(token), amount, linkSigner, feeBps));
        plm.requestLink(address(safe), address(token), amount, linkSigner, feeBps, signers, sigs);

        linkSigners.push(linkSigner);
        linkPk[linkSigner] = pk;
        _observe(linkSigner);
        if (plm.getLink(linkSigner).status == IPaymentLinkModule.LinkStatus.Funded) _onFunded(linkSigner);
        opsExecuted++;
    }

    function fundLink() external {
        address linkSigner = plm.getPendingLink(address(safe));
        if (linkSigner == address(0)) return;
        vm.warp(block.timestamp + 1 hours + 1);
        plm.fundLink(address(safe));
        _observe(linkSigner);
        _onFunded(linkSigner);
        opsExecuted++;
    }

    function claim(uint256 linkSeed, bool toSafe) external {
        address linkSigner = _pick(linkSeed);
        if (linkSigner == address(0)) return;
        IPaymentLinkModule.Link memory link = plm.getLink(linkSigner);
        if (link.status != IPaymentLinkModule.LinkStatus.Funded) return;

        address recipient = toSafe ? recipientSafe : externalRecipient;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPk[linkSigner], plm.claimDigest(linkSigner, recipient));
        plm.claim(linkSigner, recipient, abi.encodePacked(r, s, v));

        ghostExited[link.token] += link.amount; // no shortfall with plain tokens: gross == amount
        _observe(linkSigner);
        claimedCount++;
        opsExecuted++;
    }

    function cancel(uint256 linkSeed) external {
        address linkSigner = _pick(linkSeed);
        if (linkSigner == address(0)) return;
        IPaymentLinkModule.Link memory link = plm.getLink(linkSigner);
        if (link.status != IPaymentLinkModule.LinkStatus.Funded && link.status != IPaymentLinkModule.LinkStatus.Requested) return;

        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(plm.cancelLinkDigest(linkSigner));
        plm.cancel(linkSigner, signers, sigs);

        if (link.status == IPaymentLinkModule.LinkStatus.Funded) ghostExited[link.token] += link.amount;
        _observe(linkSigner);
        cancelledCount++;
        opsExecuted++;
    }

    /// @dev The owners place their own CashModule withdrawal, which cancels the link's hold and
    ///      fires `cancelBridgeByCashModule`; the owners then cancel their withdrawal to free the slot.
    function ownerWithdrawalPreemptsLink(uint256 tokenSeed) external {
        address linkSigner = plm.getPendingLink(address(safe));
        if (linkSigner == address(0)) return;

        PlainToken token = tokens[tokenSeed % 2];
        token.mint(address(safe), 1);
        address[] memory wTokens = new address[](1);
        wTokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        bytes32 requestDigest = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(wTokens, amounts, externalRecipient))).toEthSignedMessageHash();
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(requestDigest);
        cashModule.requestWithdrawal(address(safe), wTokens, amounts, externalRecipient, signers, sigs);

        bytes32 cancelDigest = keccak256(abi.encodePacked(CashVerificationLib.CANCEL_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce())).toEthSignedMessageHash();
        (signers, sigs) = _ownerSigs(cancelDigest);
        cashModule.cancelWithdrawal(address(safe), signers, sigs);

        _observe(linkSigner);
        requestCancelledCount++;
        opsExecuted++;
    }

    function reconcile() external {
        address linkSigner = plm.getPendingLink(address(safe));
        plm.reconcile(address(safe));
        if (linkSigner != address(0)) _observe(linkSigner);
        opsExecuted++;
    }

    function setFee(uint16 feeBps, bool clearReceiver) external {
        feeBps = uint16(bound(feeBps, 0, plm.MAX_FEE_BPS()));
        address receiver = clearReceiver && feeBps == 0 ? address(0) : makeAddr("invariantFeeReceiver");
        vm.prank(admin);
        plm.setFee(feeBps, receiver);
        opsExecuted++;
    }

    function donate(uint256 tokenSeed, uint256 amount) external {
        PlainToken token = tokens[tokenSeed % 2];
        amount = bound(amount, 1, 1_000 ether);
        token.mint(address(plm), amount);
        ghostDonated[address(token)] += amount;
        opsExecuted++;
    }

    /// @dev Governance takes some of the surplus (only donations create surplus here).
    function rescue(uint256 tokenSeed, uint256 amount) external {
        PlainToken token = tokens[tokenSeed % 2];
        uint256 surplus = token.balanceOf(address(plm)) - plm.getLiabilities(address(token));
        if (surplus == 0) return;
        amount = bound(amount, 1, surplus);
        vm.prank(admin);
        plm.rescueSurplus(address(token), externalRecipient, amount);
        ghostDonated[address(token)] -= amount;
        opsExecuted++;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    // ---- internals ----

    function _onFunded(address linkSigner) internal {
        IPaymentLinkModule.Link memory link = plm.getLink(linkSigner);
        ghostFunded[link.token] += link.amount;
        fundedCount++;
    }

    function _observe(address linkSigner) internal {
        uint8 status = uint8(plm.getLink(linkSigner).status);
        require(_rank(status) >= _rank(ghostStatus[linkSigner]), "link status went backwards");
        ghostStatus[linkSigner] = status;
    }

    /// @dev None < Requested < Funded < terminal. RequestCancelled and Cancelled-from-Requested
    ///      skip Funded, which is still forward.
    function _rank(uint8 status) internal pure returns (uint8) {
        if (status == uint8(IPaymentLinkModule.LinkStatus.None)) return 0;
        if (status == uint8(IPaymentLinkModule.LinkStatus.Requested)) return 1;
        if (status == uint8(IPaymentLinkModule.LinkStatus.Funded)) return 2;
        return 3;
    }

    function _pick(uint256 seed) internal view returns (address) {
        if (linkSigners.length == 0) return address(0);
        return linkSigners[seed % linkSigners.length];
    }

    function _setDelay(uint64 delay) internal {
        (, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        vm.prank(admin);
        cashModule.setDelays(delay, spendLimitDelay, modeDelay);
    }

    function _ownerSigs(bytes32 digest) internal view returns (address[] memory signers, bytes[] memory sigs) {
        signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);
    }
}

/**
 * @title PaymentLinkModuleInvariantTest
 * @notice For every non-rebasing token: module balance >= outstanding liabilities, and in fact
 *         balance == liabilities + donations exactly, liabilities == the sum of `Funded` link
 *         amounts, and at most one link per safe is `Requested` (the one in `pendingLink`).
 * @dev Run with: TEST_CHAIN=10 TEST_RPC=<optimism rpc> forge test --match-path "test/payment-link/PaymentLinkModuleInvariant.t.sol"
 *      Every handler action is bounded so it should not revert, so the campaign fails on any revert.
 *      Senders are pinned: the handler ignores msg.sender, and random senders would each cost the
 *      fork an RPC account fetch.
 */
contract PaymentLinkModuleInvariantTest is PaymentLinkModuleTestSetup {
    PaymentLinkHandler internal handler;
    PlainToken internal tokenB;

    function setUp() public override {
        super.setUp();

        tokenB = new PlainToken("Plain B", "PLAINB");
        address[] memory assets = new address[](1);
        assets[0] = address(tokenB);
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        vm.prank(owner);
        cashModule.configureWithdrawAssets(assets, yes);

        address recipientSafe = _deployRecipientSafe();
        handler = new PaymentLinkHandler(plm, cashModule, safe, owner, recipientSafe, plainToken, tokenB, owner1Pk, owner2Pk);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = PaymentLinkHandler.requestLink.selector;
        selectors[1] = PaymentLinkHandler.fundLink.selector;
        selectors[2] = PaymentLinkHandler.claim.selector;
        selectors[3] = PaymentLinkHandler.cancel.selector;
        selectors[4] = PaymentLinkHandler.ownerWithdrawalPreemptsLink.selector;
        selectors[5] = PaymentLinkHandler.reconcile.selector;
        selectors[6] = PaymentLinkHandler.setFee.selector;
        selectors[7] = PaymentLinkHandler.donate.selector;
        selectors[8] = PaymentLinkHandler.warp.selector;
        selectors[9] = PaymentLinkHandler.rescue.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetSender(makeAddr("invariantSenderA"));
        targetSender(makeAddr("invariantSenderB"));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balanceCoversLiabilities() external view {
        for (uint256 i = 0; i < 2; i++) {
            address token = handler.tokenAt(i);
            assertGe(IERC20(token).balanceOf(address(plm)), plm.getLiabilities(token), "module balance below liabilities");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_exactAccounting() external view {
        for (uint256 i = 0; i < 2; i++) {
            address token = handler.tokenAt(i);
            uint256 liabilities = plm.getLiabilities(token);
            assertEq(liabilities, handler.ghostFunded(token) - handler.ghostExited(token), "liabilities != funded - exited");
            assertEq(IERC20(token).balanceOf(address(plm)), liabilities + handler.ghostDonated(token), "balance != liabilities + donations");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_liabilitiesEqualFundedLinks() external view {
        uint256[2] memory funded;
        uint256 requested;
        address pending = plm.getPendingLink(address(safe));
        uint256 n = handler.linkCount();
        for (uint256 j = 0; j < n; j++) {
            IPaymentLinkModule.Link memory link = plm.getLink(handler.linkSigners(j));
            if (link.status == IPaymentLinkModule.LinkStatus.Funded) funded[link.token == handler.tokenAt(0) ? 0 : 1] += link.amount;
            if (link.status == IPaymentLinkModule.LinkStatus.Requested) {
                requested++;
                assertEq(handler.linkSigners(j), pending, "Requested link is not the pending link");
            }
        }
        assertLe(requested, 1, "more than one Requested link for the safe");
        if (requested == 0) assertEq(pending, address(0), "pendingLink set without a Requested link");
        assertEq(funded[0], plm.getLiabilities(handler.tokenAt(0)));
        assertEq(funded[1], plm.getLiabilities(handler.tokenAt(1)));
    }

    /// @notice Proves the handler drives real transitions, so the invariants above do not pass vacuously.
    function test_handlerDrivesEveryTransition() public {
        handler.requestLink(0, 10 ether, false);
        handler.fundLink();
        handler.claim(0, false);
        handler.requestLink(1, 5 ether, true);
        handler.cancel(1);
        handler.requestLink(0, 3 ether, false);
        handler.ownerWithdrawalPreemptsLink(0);
        handler.donate(1, 1 ether);
        handler.rescue(1, 0.4 ether);
        assertEq(handler.ghostDonated(handler.tokenAt(1)), 0.6 ether);
        assertEq(handler.fundedCount(), 2);
        assertEq(handler.claimedCount(), 1);
        assertEq(handler.cancelledCount(), 1);
        assertEq(handler.requestCancelledCount(), 1);
        assertEq(uint8(plm.getLink(handler.linkSigners(2)).status), uint8(IPaymentLinkModule.LinkStatus.RequestCancelled));
        this.invariant_balanceCoversLiabilities();
        this.invariant_exactAccounting();
        this.invariant_liabilitiesEqualFundedLinks();
    }

    function _deployRecipientSafe() internal returns (address) {
        bytes32 salt = keccak256("payment-link-invariant-recipient");
        address[] memory owners = new address[](1);
        owners[0] = makeAddr("invariantRecipientOwner");
        vm.prank(owner);
        safeFactory.deployEtherFiSafe(salt, owners, new address[](0), new bytes[](0), 1);
        return safeFactory.getDeterministicAddress(salt);
    }
}
