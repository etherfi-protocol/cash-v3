// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBridgeModule } from "../interfaces/IBridgeModule.sol";
import { ICashModule, WithdrawalRequest } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IPaymentLinkModule } from "../interfaces/IPaymentLinkModule.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title PaymentLinkModule
 * @author ether.fi
 * @notice Escrow for payment links on OP. A safe's owners sign ONE request that places a
 *         CashModule withdrawal hold with this module as recipient, keyed by a throwaway
 *         `linkSigner` address whose private key travels in the link URL. The link key signs the
 *         same request, so no safe can take a `linkSigner` without its key. Once the withdrawal
 *         delay matures, the permissionless `fundLink(safe)` pulls the funds in. Whoever holds the
 *         link key can then `claim` to any recipient (fee-free to an EtherFiSafe, `feeBps` to
 *         anything else); the safe's current owners can call `cancel` at any time, including
 *         while paused. Claims and cancels carry a signed minimum payout.
 * @dev The module is whitelisted on the DataProvider and allowed to request withdrawals on the
 *      CashModule, but is never enabled on safes, so it has no `execTransactionFromModule`
 *      authority and cannot use `IEtherFiSafe.useNonce()`. Owner signatures therefore use this
 *      module's own per-safe nonce (`ModuleBase.getNonce` / `_useNonce`), and every digest binds
 *      `block.chainid` and `address(this)`.
 *
 *      Accounting is per token: `liabilities[token]` is the sum of funded, unclaimed and
 *      uncancelled link amounts. Payouts are computed from a snapshot of the module balance and
 *      liabilities taken before any state change. The module's own transfers move exact amounts,
 *      so its balance can only fall below its liabilities through a change outside the module.
 *      Rebasing and other balance-changing tokens are not supported (see the allowlist rule
 *      below); the shortfall path only bounds the damage if such a change happens anyway. In a
 *      shortfall every exit in that token is paid pro rata, new links and funding in it are
 *      refused (`EscrowShortfall`), and other tokens are untouched. An exit that would pay less
 *      than the minimum its signer agreed to reverts (`PayoutBelowMinimum`) and the link stays
 *      as it was.
 *
 *      New links are limited to tokens governance allows here (`setTokenAllowed`), which must also
 *      be on CashModule's withdraw-asset list. Allow only tokens that move exact amounts: the
 *      allowlist is what keeps a sender-taxed token (see below) from being escrowed at all. It
 *      gates `requestLink` only; links already requested or funded keep funding, claiming,
 *      cancelling and reconciling after their token is disallowed. There are no amount caps here;
 *      which tokens and amounts are offered is decided off chain.
 *
 *      Every transfer in and out must move the module's balance by exactly the amount sent
 *      (`BalanceDeltaMismatch` otherwise), so no exit can take more from the pooled escrow than
 *      it pays out. Cancellation stays callable while paused, but a refund still needs a
 *      successful exact-debit transfer. A token that taxes the SENDER passes funding (the safe
 *      pays the tax) and then fails every exit whose transfers are actually taxed: such a link
 *      can be neither claimed nor cancelled while that holds. Transfers the tax rounds to zero,
 *      or that the token exempts, still succeed, and a shortfall exit whose payout is zero
 *      finalizes without transferring when its signed minimum is zero. Only offer tokens that
 *      move exact amounts.
 *
 *      Failed transfers (token blocklists, pauses, taxes): the whole call reverts, so the link
 *      stays `Funded` and liabilities, balances and the owners' cancel nonce are unchanged.
 *      - Blocked recipient: the link key can sign a new claim to another address.
 *      - Blocked fee receiver: claims that owe a fee revert until the admin changes the receiver
 *        with `setFee` (read live at claim); claims to an EtherFiSafe owe no fee.
 *      - Blocked safe: refunds of funded links revert, but the link can still be claimed to
 *        another address. Cancelling a `Requested` link moves no tokens and still works.
 *      - Blocked module: no positive payout can succeed until the token's restrictions change.
 *      - Sender-taxed token: exits stay stuck until exact-debit transfers become possible or
 *        the module is upgraded.
 *
 *      GOVERNANCE RULE: do not remove this module from the DataProvider whitelist or from
 *      CashModule's withdraw-requester list while any link is `Requested`. CashModule decides who
 *      may process or cancel a module's withdrawal from CURRENT list membership, so after removal
 *      (a) anyone can `processWithdrawal` the hold into this module without `fundLink`, leaving
 *      the funds as unrecorded balance: `rescueSurplus` can return them only to the extent the
 *      token has surplus, so if that token is already in a shortfall they first cover the
 *      deficit of funded links and the sender is NOT made whole; and (b) the
 *      owners' `cancel` of that link reverts until they replace the hold with their own
 *      withdrawal and `reconcile`. To stop the module, `pause` it instead: requests, funding and
 *      claims stop, cancels keep working.
 */
contract PaymentLinkModule is ModuleBase, UpgradeableProxy, IBridgeModule, IPaymentLinkModule {
    using MessageHashUtils for bytes32;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:etherfi.storage.PaymentLinkModule
    struct PaymentLinkModuleStorage {
        /// @notice Link per `linkSigner`. A status other than `None` means the signer is used forever.
        mapping(address linkSigner => Link link) links;
        /// @notice The safe's single `Requested` link, if any.
        mapping(address safe => address linkSigner) pendingLink;
        /// @notice Sum of `Funded`, unclaimed and uncancelled link amounts per token.
        mapping(address token => uint256 amount) liabilities;
        /// @notice Fee in basis points snapshotted into new links.
        uint16 feeBps;
        /// @notice Receiver of claim fees. Zero waives the fee on every claim.
        address feeReceiver;
        /// @notice Tokens new links may escrow. Checked only by `requestLink`.
        mapping(address token => bool allowed) allowedTokens;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PaymentLinkModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PaymentLinkModuleStorageLocation = 0x72f6ddc7d992479425dc8c9c22860bd7f83946c3315c4ff3de0873cbf7571b00;

    /// @notice CashModule that holds, delays and processes the withdrawal requests.
    ICashModule public immutable cashModule;

    /// @notice 100% in basis points.
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;
    /// @notice Maximum claim fee (1%).
    uint16 public constant MAX_FEE_BPS = 100;

    /// @notice Prefix of the owner digest for `requestLink`.
    bytes32 public constant REQUEST_LINK_SIG = keccak256("requestLink");
    /// @notice Prefix of the owner digest for `cancel`.
    bytes32 public constant CANCEL_LINK_SIG = keccak256("cancelLink");

    /// @notice EIP-712 type hash of the claim the link key signs.
    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(address linkSigner,address recipient,uint256 minAmount)");
    /// @dev EIP-712 domain type hash.
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev `keccak256("EtherFi PaymentLinkModule")`, the EIP-712 domain name.
    bytes32 private constant EIP712_NAME_HASH = keccak256("EtherFi PaymentLinkModule");
    /// @dev `keccak256("1")`, the EIP-712 domain version.
    bytes32 private constant EIP712_VERSION_HASH = keccak256("1");

    /**
     * @dev Immutables (`etherFiDataProvider`, `cashModule`) live in the IMPLEMENTATION's code;
     *      every upgrade impl must be constructed with the same pair. `cashModule` must be the
     *      DataProvider's CashModule, so swapped or mismatched arguments fail at deploy.
     * @param _etherFiDataProvider The EtherFiDataProvider of the cash stack this module serves.
     * @param _cashModule The CashModule registered on `_etherFiDataProvider`.
     * @custom:throws InvalidInput If `_cashModule` is zero or not the DataProvider's CashModule.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _etherFiDataProvider, address _cashModule) ModuleBase(_etherFiDataProvider) {
        if (_cashModule == address(0) || _cashModule != IEtherFiDataProvider(_etherFiDataProvider).getCashModule()) revert InvalidInput();
        cashModule = ICashModule(_cashModule);
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy with its role registry and fee configuration.
     * @param _roleRegistry Role registry (upgrade authority, pause control, admin roles).
     * @param _feeBps Claim fee in basis points, at most `MAX_FEE_BPS`.
     * @param _feeReceiver Fee receiver; may be zero only when `_feeBps` is zero.
     * @custom:throws InvalidInput If `_roleRegistry` is zero, `_feeReceiver` is zero with a non-zero
     *                fee, or `_feeReceiver` is this module.
     * @custom:throws FeeTooHigh If `_feeBps` exceeds `MAX_FEE_BPS`.
     */
    function initialize(address _roleRegistry, uint16 _feeBps, address _feeReceiver) external initializer {
        if (_roleRegistry == address(0)) revert InvalidInput();
        __UpgradeableProxy_init(_roleRegistry);
        _setFee(_feeBps, _feeReceiver);
    }

    // ---- Lifecycle ----

    /**
     * @notice Creates a link for `linkSigner` and places a CashModule withdrawal of `amount` of
     *         `token` from `safe` with this module as recipient. With a zero CashModule withdrawal
     *         delay CashModule transfers inline and the link is `Funded` in this call; otherwise it
     *         stays `Requested` until `fundLink`.
     * @dev The owners and the link key both sign `requestLinkDigest(safe, token, amount,
     *      linkSigner, feeBps)` at the module's current nonce for `safe`. The link key's signature
     *      proves the request comes from whoever holds that key, so another safe cannot take a
     *      `linkSigner` it has only seen; the digest binds the chain, module, safe, nonce and
     *      every request parameter, so the signature cannot be reused for a different request.
     * @param safe The EtherFiSafe sending the funds.
     * @param token The ERC-20 to escrow (allowed here and on CashModule's withdraw-asset list).
     * @param amount The amount to escrow.
     * @param linkSigner The address of the link's private key; the link ID.
     * @param feeBps The fee the owners agreed to; must equal the current fee.
     * @param linkSignature The link key's signature over the request digest (65-byte r || s || v,
     *        made over the prefixed digest itself, i.e. `personal_sign` over the inner hash).
     * @param signers Safe owners that signed the request digest.
     * @param signatures Signatures corresponding to `signers`.
     * @custom:throws OnlyEtherFiSafe If `safe` is not an EtherFiSafe.
     * @custom:throws InvalidInput If `token`, `linkSigner` or `amount` is zero.
     * @custom:throws TokenNotAllowed If `token` is not on this module's allowlist.
     * @custom:throws EscrowShortfall If the module already holds less `token` than its liabilities.
     * @custom:throws LinkSignerUsed If `linkSigner` was used by any earlier link.
     * @custom:throws FeeMismatch If `feeBps` differs from the current fee.
     * @custom:throws PendingLinkExists If the safe already has a `Requested` link.
     * @custom:throws PendingWithdrawalExists If CashModule holds a pending withdrawal for the safe.
     * @custom:throws InvalidSignatures If the signatures don't meet the safe's threshold.
     * @custom:throws InvalidLinkSignature If `linkSignature` was not made by `linkSigner` over the request digest.
     * @custom:throws UnexpectedWithdrawalOutcome If CashModule neither holds a matching pending
     *                request nor transferred exactly `amount` inline.
     */
    function requestLink(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps, bytes calldata linkSignature, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused nonReentrant onlyEtherFiSafe(safe) {
        _validateRequest(safe, token, amount, linkSigner, feeBps);

        uint256 nonce = _useNonce(safe);
        bytes32 digest = _requestLinkDigest(safe, token, amount, linkSigner, feeBps, nonce);
        _checkOwnerSignatures(safe, digest, signers, signatures);
        _checkLinkSignature(digest, linkSigner, linkSignature);

        _storeRequest(safe, token, amount, linkSigner, feeBps);
        _placeWithdrawal(safe, token, amount, linkSigner);
    }

    /**
     * @notice Processes the matured CashModule withdrawal for the safe's pending link and marks
     *         the link `Funded`.
     * @dev Permissionless: the caller only replays what the owners signed. CashModule enforces
     *      the withdrawal delay inside `processWithdrawal`. The received balance must equal the
     *      link amount exactly, so fee-on-transfer and non-transferring tokens revert here and
     *      the link stays cancellable.
     * @param safe The EtherFiSafe whose pending link to fund.
     * @custom:throws OnlyEtherFiSafe If `safe` is not an EtherFiSafe.
     * @custom:throws NoPendingLink If the safe has no `Requested` link.
     * @custom:throws EscrowShortfall If the module holds less of the token than its liabilities.
     * @custom:throws CannotFindMatchingWithdrawal If CashModule's pending request doesn't match the link.
     * @custom:throws BalanceDeltaMismatch If the module did not receive exactly the link amount.
     */
    function fundLink(address safe) external whenNotPaused nonReentrant onlyEtherFiSafe(safe) {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        address linkSigner = $.pendingLink[safe];
        if (linkSigner == address(0) || $.links[linkSigner].status != LinkStatus.Requested) revert NoPendingLink();

        address token = $.links[linkSigner].token;
        uint256 amount = $.links[linkSigner].amount;

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        if (balanceBefore < $.liabilities[token]) revert EscrowShortfall();
        if (!_matchesPendingWithdrawal(safe, token, amount)) revert CannotFindMatchingWithdrawal();

        cashModule.processWithdrawal(safe);
        if (IERC20(token).balanceOf(address(this)) != balanceBefore + amount) revert BalanceDeltaMismatch();

        _markFunded($, safe, linkSigner, token, amount);
    }

    /**
     * @notice Pays a funded link to `recipient`. Authorized by the link key's EIP-712 signature
     *         over `Claim(linkSigner, recipient, minAmount)`, so a relayed signature cannot be
     *         redirected or executed below the payout its signer agreed to.
     * @dev Permissionless submission. The fee is the link's snapshotted rate, rounded down, and
     *      is waived when `recipient` is an EtherFiSafe or no fee receiver is configured; both
     *      are read at execution. In a shortfall the gross payout is pro rata (see `_grossPayout`).
     *      `minAmount` bounds the NET amount `recipient` receives (gross minus fee), checked after
     *      the fee is computed and before any state change. A zero `minAmount` accepts any payout,
     *      including a zero payout in a severe shortfall.
     * @param linkSigner The link ID.
     * @param recipient The address to pay.
     * @param minAmount The least `recipient` must receive after the fee.
     * @param signature The link key's signature over `claimDigest(linkSigner, recipient, minAmount)`.
     * @custom:throws LinkNotClaimable If the link is not `Funded`.
     * @custom:throws InvalidInput If `recipient` is zero or this module.
     * @custom:throws InvalidClaimSignature If the signature was not made by `linkSigner`.
     * @custom:throws PayoutBelowMinimum If `recipient` would receive less than `minAmount`.
     * @custom:throws BalanceDeltaMismatch If a payout moved the module's balance by more or less
     *                than the amount sent (for example a token that taxes the sender).
     */
    function claim(address linkSigner, address recipient, uint256 minAmount, bytes calldata signature) external whenNotPaused nonReentrant {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        Link storage link = $.links[linkSigner];
        if (link.status != LinkStatus.Funded) revert LinkNotClaimable();
        if (recipient == address(0) || recipient == address(this)) revert InvalidInput();
        _checkClaimSignature(linkSigner, recipient, minAmount, signature);

        address token = link.token;
        uint256 amount = link.amount;
        uint256 gross = _grossPayout($, token, amount);
        address feeReceiver = $.feeReceiver;
        uint256 fee = (feeReceiver == address(0) || etherFiDataProvider.isEtherFiSafe(recipient)) ? 0 : gross.mulDiv(link.feeBps, HUNDRED_PERCENT_IN_BPS);
        if (gross - fee < minAmount) revert PayoutBelowMinimum();

        link.status = LinkStatus.Claimed;
        $.liabilities[token] -= amount;

        if (fee > 0) _transferOut(token, feeReceiver, fee);
        if (gross > fee) _transferOut(token, recipient, gross - fee);

        emit LinkClaimed(link.safe, linkSigner, recipient, token, gross - fee, fee);
    }

    /**
     * @notice Cancels a `Requested` or `Funded` link, signed by the safe's CURRENT owners. A
     *         requested link releases its CashModule hold; a funded link's escrow returns to the
     *         safe (pro rata in a shortfall, never with a fee).
     * @dev Deliberately not gated by pause: cancellation remains callable while paused, and a
     *      funded link's refund requires a successful exact-debit transfer (see the contract notes
     *      on failed transfers). A `Requested` link moves no tokens; its state is cleared BEFORE
     *      `cancelWithdrawalByModule`, so CashModule's `cancelBridgeByCashModule` callback finds
     *      nothing to do.
     *
     *      `minRefund` bounds what the safe gets back. A funded link refunds its gross payout
     *      (pro rata in a shortfall); a requested link's tokens never left the safe, so its
     *      refund is the full link amount and any `minRefund` up to that amount passes. The
     *      owners sign the minimum without knowing which state the link will be in when the
     *      cancel executes.
     * @param linkSigner The link ID.
     * @param minRefund The least the safe must get back.
     * @param signers Safe owners that signed `cancelLinkDigest(linkSigner, minRefund)`.
     * @param signatures Signatures corresponding to `signers`.
     * @custom:throws LinkNotCancellable If the link is neither `Requested` nor `Funded`.
     * @custom:throws InvalidSignatures If the signatures don't meet the safe's threshold.
     * @custom:throws PayoutBelowMinimum If the refund would be less than `minRefund`.
     * @custom:throws BalanceDeltaMismatch If a funded link's refund moved the module's balance by
     *                more or less than the amount refunded.
     */
    function cancel(address linkSigner, uint256 minRefund, address[] calldata signers, bytes[] calldata signatures) external nonReentrant {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        Link storage link = $.links[linkSigner];
        LinkStatus status = link.status;
        if (status != LinkStatus.Requested && status != LinkStatus.Funded) revert LinkNotCancellable();

        address safe = link.safe;
        _checkOwnerSignatures(safe, _cancelLinkDigest(safe, linkSigner, minRefund, _useNonce(safe)), signers, signatures);

        if (status == LinkStatus.Requested) _cancelRequested($, link, safe, linkSigner, minRefund);
        else _cancelFunded($, link, safe, linkSigner, minRefund);
    }

    /**
     * @notice Marks the safe's pending link `RequestCancelled` when CashModule no longer holds its
     *         matching withdrawal request. Does nothing when there is no pending link or the
     *         request still matches; never touches `Funded` or terminal links.
     * @dev Permissionless. Covers a CashModule cancellation that did not reach
     *      `cancelBridgeByCashModule` (CashModule skips the callback when this module is not
     *      whitelisted on both the DataProvider and its withdraw-requester list).
     * @param safe The EtherFiSafe whose pending link to reconcile.
     */
    function reconcile(address safe) external nonReentrant {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        address linkSigner = $.pendingLink[safe];
        if (linkSigner == address(0)) return;

        Link storage link = $.links[linkSigner];
        if (link.status != LinkStatus.Requested) return;
        if (_matchesPendingWithdrawal(safe, link.token, link.amount)) return;

        _markRequestCancelled($, safe, linkSigner);
    }

    /**
     * @notice Hook called by CashModule whenever it cancels a pending withdrawal whose recipient is
     *         this module (card spend, a new withdrawal request, liquidation, or our own `cancel`).
     *         Marks the safe's pending link `RequestCancelled`; no-op when there is none.
     * @dev Only CashModule. NOT `nonReentrant`, because CashModule calls it back during our own
     *      `cancel`; it therefore makes no external calls. It must never revert for CashModule,
     *      or the card spend that triggered it would revert too.
     * @param safe The EtherFiSafe whose withdrawal was cancelled.
     * @custom:throws Unauthorized If the caller is not the CashModule.
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        address linkSigner = $.pendingLink[safe];
        if (linkSigner == address(0) || $.links[linkSigner].status != LinkStatus.Requested) return;

        _markRequestCancelled($, safe, linkSigner);
    }

    // ---- Admin ----

    /**
     * @notice Sets the claim fee snapshotted into new links and its receiver. Links already
     *         requested keep their snapshotted rate; the receiver is read live at claim.
     * @param _feeBps The fee in basis points, at most `MAX_FEE_BPS`.
     * @param _feeReceiver The fee receiver; may be zero only when `_feeBps` is zero.
     * @custom:throws OnlyAdminTimelock If the caller lacks `ADMIN_TIMELOCK_ROLE`.
     * @custom:throws FeeTooHigh If `_feeBps` exceeds `MAX_FEE_BPS`.
     * @custom:throws InvalidInput If `_feeReceiver` is zero while `_feeBps` is non-zero, or is this module.
     */
    function setFee(uint16 _feeBps, address _feeReceiver) external onlyAdminTimelock {
        _setFee(_feeBps, _feeReceiver);
    }

    /**
     * @notice Allows or disallows `token` for new links.
     * @dev Gates `requestLink` only. Disallowing a token never strands a link: links already
     *      requested still fund (their owners signed while it was allowed), and funded links still
     *      claim, cancel and reconcile. Allow only tokens that transfer exact amounts.
     * @param token The ERC-20 to configure.
     * @param allowed Whether new links may escrow `token`.
     * @custom:throws OnlyAdminTimelock If the caller lacks `ADMIN_TIMELOCK_ROLE`.
     * @custom:throws InvalidInput If `token` is zero.
     */
    function setTokenAllowed(address token, bool allowed) external onlyAdminTimelock {
        if (token == address(0)) revert InvalidInput();
        _getPaymentLinkModuleStorage().allowedTokens[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    /**
     * @notice Transfers `amount` of `token` that the module holds ABOVE its liabilities to `to`.
     * @dev Surplus is owed to no link: donations, or a CashModule withdrawal processed into the
     *      module without `fundLink` (see the governance rule above). The
     *      transfer must lower the balance by exactly `amount <= balance - liabilities`, so no
     *      outstanding link can ever be paid less because of a rescue. It is NOT a guaranteed
     *      recovery: in a token that is in shortfall, misprocessed funds first cover the deficit.
     *      Gated by ADMIN_TIMELOCK_ROLE (the 8h operating timelock on Optimism), not by the 2-day
     *      upgrade authority. Not gated by pause.
     * @param token The token to rescue.
     * @param to The recipient (for a misprocessed withdrawal, the safe it came from).
     * @param amount The amount to transfer.
     * @custom:throws OnlyAdminTimelock If the caller lacks `ADMIN_TIMELOCK_ROLE`.
     * @custom:throws InvalidInput If `to` is zero or this module, or `amount` is zero.
     * @custom:throws InsufficientSurplus If `amount` exceeds `balance - liabilities`.
     * @custom:throws BalanceDeltaMismatch If the transfer moved the balance by more or less than `amount`.
     */
    function rescueSurplus(address token, address to, uint256 amount) external onlyAdminTimelock nonReentrant {
        if (to == address(0) || to == address(this) || amount == 0) revert InvalidInput();
        uint256 liabilities = _getPaymentLinkModuleStorage().liabilities[token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < liabilities || amount > balance - liabilities) revert InsufficientSurplus();

        _transferOut(token, to, amount);

        emit SurplusRescued(token, to, amount);
    }

    // ---- Views ----

    /**
     * @notice Returns the link stored for `linkSigner` (zeroed when unused).
     * @param linkSigner The link ID.
     * @return The stored link.
     */
    function getLink(address linkSigner) external view returns (Link memory) {
        return _getPaymentLinkModuleStorage().links[linkSigner];
    }

    /**
     * @notice Returns the safe's link that is waiting to be funded.
     * @param safe The EtherFiSafe to query.
     * @return linkSigner The pending link ID, or zero if none.
     */
    function getPendingLink(address safe) external view returns (address linkSigner) {
        return _getPaymentLinkModuleStorage().pendingLink[safe];
    }

    /**
     * @notice Returns the sum of funded, unclaimed and uncancelled link amounts for `token`.
     * @param token The token to query.
     * @return The outstanding liabilities in token units.
     */
    function getLiabilities(address token) external view returns (uint256) {
        return _getPaymentLinkModuleStorage().liabilities[token];
    }

    /**
     * @notice Returns the current fee configuration.
     * @return feeBps The fee in basis points.
     * @return feeReceiver The fee receiver.
     */
    function getFee() external view returns (uint16 feeBps, address feeReceiver) {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        return ($.feeBps, $.feeReceiver);
    }

    /**
     * @notice Returns whether new links may escrow `token`.
     * @param token The token to query.
     * @return True if `token` is allowed.
     */
    function isTokenAllowed(address token) external view returns (bool) {
        return _getPaymentLinkModuleStorage().allowedTokens[token];
    }

    /**
     * @notice Returns the EIP-712 digest the link key signs to claim to `recipient`.
     * @param linkSigner The link ID.
     * @param recipient The recipient bound into the signature.
     * @param minAmount The least `recipient` must receive after the fee.
     * @return The EIP-712 typed-data digest.
     */
    function claimDigest(address linkSigner, address recipient, uint256 minAmount) external view returns (bytes32) {
        return _claimDigest(linkSigner, recipient, minAmount);
    }

    /**
     * @notice Returns the EIP-191 digest the safe's owners and the link key sign for
     *         `requestLink`, at the module's current nonce for `safe`.
     * @dev This is the prefixed hash `checkSignatures` and the link-key check verify, i.e. what
     *      `personal_sign` over the 32-byte inner hash produces. Sign it as is, without adding
     *      the prefix again.
     * @param safe The EtherFiSafe sending the funds.
     * @param token The ERC-20 to escrow.
     * @param amount The amount to escrow.
     * @param linkSigner The link ID.
     * @param feeBps The fee the owners agree to.
     * @return The digest to sign.
     */
    function requestLinkDigest(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps) external view returns (bytes32) {
        return _requestLinkDigest(safe, token, amount, linkSigner, feeBps, getNonce(safe));
    }

    /**
     * @notice Returns the EIP-191 digest the safe's owners sign for `cancel`, at the module's
     *         current nonce for the link's safe.
     * @dev Same prefixed form as `requestLinkDigest`. Computed even for an unused `linkSigner`
     *      (with a zero safe), which `cancel` would reject.
     * @param linkSigner The link ID.
     * @param minRefund The least the safe must get back.
     * @return The digest to sign.
     */
    function cancelLinkDigest(address linkSigner, uint256 minRefund) external view returns (bytes32) {
        address safe = _getPaymentLinkModuleStorage().links[linkSigner].safe;
        return _cancelLinkDigest(safe, linkSigner, minRefund, getNonce(safe));
    }

    /**
     * @notice Returns the EIP-712 domain separator for claim signatures, computed for the
     *         current chain and this proxy's address.
     * @return The domain separator.
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, EIP712_VERSION_HASH, block.chainid, address(this)));
    }

    // ---- Internals ----

    /// @dev Request preconditions, split out of `requestLink` to stay under the legacy stack limit.
    function _validateRequest(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps) internal view {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        if (token == address(0) || linkSigner == address(0) || amount == 0) revert InvalidInput();
        if (!$.allowedTokens[token]) revert TokenNotAllowed();
        // A new link must never absorb an existing deficit in its token.
        if (IERC20(token).balanceOf(address(this)) < $.liabilities[token]) revert EscrowShortfall();
        if ($.links[linkSigner].status != LinkStatus.None) revert LinkSignerUsed();
        // The owners signed `feeBps`; a fee change between quote and submit fails instead of applying silently.
        if (feeBps != $.feeBps) revert FeeMismatch();
        if ($.pendingLink[safe] != address(0)) revert PendingLinkExists();
        if (cashModule.getData(safe).pendingWithdrawalRequest.tokens.length != 0) revert PendingWithdrawalExists();
    }

    /**
     * @dev Places the CashModule withdrawal for a just-stored `Requested` link and classifies the
     *      outcome. The safe's module transfer path checks call success, not ERC-20 return values,
     *      so the balance delta is the only reliable evidence of what arrived. Exactly one outcome
     *      is accepted:
     *        - CashModule holds the matching pending request and nothing arrived: stays `Requested`.
     *        - CashModule holds no request and exactly `amount` arrived (zero withdrawal delay,
     *          processed inline): `Funded`.
     */
    function _placeWithdrawal(address safe, address token, uint256 amount, address linkSigner) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        cashModule.requestWithdrawalByModule(safe, token, amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        if (cashModule.getData(safe).pendingWithdrawalRequest.tokens.length == 0) {
            if (balanceAfter != balanceBefore + amount) revert UnexpectedWithdrawalOutcome();
            _markFunded(_getPaymentLinkModuleStorage(), safe, linkSigner, token, amount);
        } else if (balanceAfter != balanceBefore || !_matchesPendingWithdrawal(safe, token, amount)) {
            revert UnexpectedWithdrawalOutcome();
        }
    }

    /// @dev Stores a new `Requested` link and marks it as the safe's pending link.
    function _storeRequest(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps) internal {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        $.links[linkSigner] = Link({ safe: safe, token: token, amount: amount, feeBps: feeBps, status: LinkStatus.Requested });
        $.pendingLink[safe] = linkSigner;
        emit LinkRequested(safe, linkSigner, token, amount, feeBps);
    }

    /// @dev Reverts unless `signers` meet the safe's CURRENT owner threshold for `digest`. The safe
    ///      itself reverts on malformed input (unknown or duplicate signers, too few signers).
    function _checkOwnerSignatures(address safe, bytes32 digest, address[] calldata signers, bytes[] calldata signatures) internal view {
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();
    }

    /// @dev Reverts unless `signature` is `linkSigner`'s raw ECDSA signature over the (already
    ///      prefixed) request `digest`.
    function _checkLinkSignature(bytes32 digest, address linkSigner, bytes calldata signature) internal pure {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != linkSigner) revert InvalidLinkSignature();
    }

    /// @dev Reverts unless `signature` is `linkSigner`'s signature over `claimDigest(linkSigner, recipient, minAmount)`.
    function _checkClaimSignature(address linkSigner, address recipient, uint256 minAmount, bytes calldata signature) internal view {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(_claimDigest(linkSigner, recipient, minAmount), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != linkSigner) revert InvalidClaimSignature();
    }

    /// @dev `Requested` → `Funded`: the escrow is now a liability.
    function _markFunded(PaymentLinkModuleStorage storage $, address safe, address linkSigner, address token, uint256 amount) internal {
        $.links[linkSigner].status = LinkStatus.Funded;
        $.liabilities[token] += amount;
        delete $.pendingLink[safe];
        emit LinkFunded(safe, linkSigner, token, amount);
    }

    /// @dev `Requested` → `RequestCancelled`. State only, no external calls (see `cancelBridgeByCashModule`).
    function _markRequestCancelled(PaymentLinkModuleStorage storage $, address safe, address linkSigner) internal {
        $.links[linkSigner].status = LinkStatus.RequestCancelled;
        delete $.pendingLink[safe];
        emit LinkRequestCancelled(safe, linkSigner);
    }

    /// @dev `Requested` → `Cancelled`. Clears state first, then releases CashModule's hold if it is
    ///      still the link's own request; its callback then no-ops. The tokens never left the
    ///      safe, so the refund counted against `minRefund` is the full link amount.
    function _cancelRequested(PaymentLinkModuleStorage storage $, Link storage link, address safe, address linkSigner, uint256 minRefund) internal {
        if (link.amount < minRefund) revert PayoutBelowMinimum();
        link.status = LinkStatus.Cancelled;
        delete $.pendingLink[safe];

        address token = link.token;
        if (_matchesPendingWithdrawal(safe, token, link.amount)) cashModule.cancelWithdrawalByModule(safe);

        emit LinkCancelled(safe, linkSigner, token, 0);
    }

    /// @dev `Funded` → `Cancelled`. The refund is computed from the pre-mutation snapshot, carries
    ///      no fee and only ever goes to the link's own safe.
    function _cancelFunded(PaymentLinkModuleStorage storage $, Link storage link, address safe, address linkSigner, uint256 minRefund) internal {
        address token = link.token;
        uint256 amount = link.amount;
        uint256 gross = _grossPayout($, token, amount);
        if (gross < minRefund) revert PayoutBelowMinimum();

        link.status = LinkStatus.Cancelled;
        $.liabilities[token] -= amount;

        if (gross > 0) _transferOut(token, safe, gross);

        emit LinkCancelled(safe, linkSigner, token, gross);
    }

    /// @dev The only way tokens leave the module. Reverts unless the module's balance fell by
    ///      exactly `amount`: a token that charges the sender more (or rebases inside the transfer)
    ///      would otherwise take the difference from other links' escrow in the same token.
    function _transferOut(address token, address to, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        if (IERC20(token).balanceOf(address(this)) + amount != balanceBefore) revert BalanceDeltaMismatch();
    }

    /**
     * @dev Gross payout for exiting a funded link of `amount`, from a snapshot of the module's
     *      balance and liabilities in `token` taken before any state change. In a shortfall
     *      (`balance < liabilities`) every exit is paid `amount * balance / liabilities`, rounded
     *      down. An exit therefore never lowers the remaining balance-to-liabilities ratio: before
     *      rounding it is unchanged, and rounding down can only raise it, by a lot on a tiny
     *      balance (2 held against 3 owed pays a 1-unit exit nothing and leaves 2 against 2).
     *      Other tokens are never touched.
     */
    function _grossPayout(PaymentLinkModuleStorage storage $, address token, uint256 amount) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 liabilities = $.liabilities[token];
        if (balance >= liabilities) return amount;
        return amount.mulDiv(balance, liabilities);
    }

    /// @dev Whether CashModule's pending withdrawal for `safe` is this module's single-token request for `amount` of `token`.
    function _matchesPendingWithdrawal(address safe, address token, uint256 amount) internal view returns (bool) {
        WithdrawalRequest memory pending = cashModule.getData(safe).pendingWithdrawalRequest;
        return pending.recipient == address(this) && pending.tokens.length == 1 && pending.tokens[0] == token && pending.amounts[0] == amount;
    }

    /// @dev EIP-191 digest for `requestLink`, signed by the owners and the link key, bound to chain,
    ///      module, nonce, safe and every request parameter.
    function _requestLinkDigest(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(REQUEST_LINK_SIG, block.chainid, address(this), nonce, safe, abi.encode(token, amount, linkSigner, feeBps))).toEthSignedMessageHash();
    }

    /// @dev EIP-191 owner digest for `cancel`, bound to chain, module, nonce, safe, link and minimum refund.
    function _cancelLinkDigest(address safe, address linkSigner, uint256 minRefund, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(CANCEL_LINK_SIG, block.chainid, address(this), nonce, safe, linkSigner, minRefund)).toEthSignedMessageHash();
    }

    /// @dev EIP-712 digest of `Claim(linkSigner, recipient, minAmount)` under this module's domain.
    function _claimDigest(address linkSigner, address recipient, uint256 minAmount) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR(), keccak256(abi.encode(CLAIM_TYPEHASH, linkSigner, recipient, minAmount)));
    }

    /// @dev Shared by `initialize` and `setFee`. Zero bps disables the fee (the receiver may then
    ///      be zero too); a non-zero fee requires a real receiver. The module itself is never a
    ///      receiver: a fee "paid" to itself would fail `_transferOut` and block external claims.
    function _setFee(uint16 _feeBps, address _feeReceiver) internal {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if ((_feeBps > 0 && _feeReceiver == address(0)) || _feeReceiver == address(this)) revert InvalidInput();
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        emit FeeSet($.feeBps, _feeBps, $.feeReceiver, _feeReceiver);
        $.feeBps = _feeBps;
        $.feeReceiver = _feeReceiver;
    }

    /// @dev Returns the storage struct from the ERC-7201 namespaced slot.
    function _getPaymentLinkModuleStorage() internal pure returns (PaymentLinkModuleStorage storage $) {
        assembly {
            $.slot := PaymentLinkModuleStorageLocation
        }
    }
}
