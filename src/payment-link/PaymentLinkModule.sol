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
 *         `linkSigner` address whose private key travels in the link URL. Once the withdrawal
 *         delay matures, the permissionless `fundLink(safe)` pulls the funds in. Whoever holds the
 *         link key can then `claim` to any recipient (fee-free to an EtherFiSafe, `feeBps` to
 *         anything else); the safe's current owners can `cancel` at any time, paused or not.
 * @dev The module is whitelisted on the DataProvider and allowed to request withdrawals on the
 *      CashModule, but is never enabled on safes, so it has no `execTransactionFromModule`
 *      authority and cannot use `IEtherFiSafe.useNonce()`. Owner signatures therefore use this
 *      module's own per-safe nonce (`ModuleBase.getNonce` / `_useNonce`), and every digest binds
 *      `block.chainid` and `address(this)`.
 *
 *      Accounting is per token: `liabilities[token]` is the sum of funded, unclaimed and
 *      uncancelled link amounts. Payouts are computed from a snapshot of the module balance and
 *      liabilities taken before any state change. When a token's balance falls below its
 *      liabilities (for example after a negative rebase), every exit in that token is paid
 *      pro rata and new links in it are refused (`EscrowShortfall`); other tokens are untouched.
 *
 *      No token allowlist and no amount caps live here: CashModule's withdraw-asset list bounds
 *      what can be requested, and the backend decides what is offered.
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
    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(address linkSigner,address recipient)");
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
     * @custom:throws InvalidInput If `_roleRegistry` is zero, or `_feeReceiver` is zero with a non-zero fee.
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
     * @dev The owners sign `requestLinkDigest(safe, token, amount, linkSigner, feeBps)` at the
     *      module's current nonce for `safe`.
     * @param safe The EtherFiSafe sending the funds.
     * @param token The ERC-20 to escrow (must be on CashModule's withdraw-asset list).
     * @param amount The amount to escrow.
     * @param linkSigner The address of the link's private key; the link ID.
     * @param feeBps The fee the owners agreed to; must equal the current fee.
     * @param signers Safe owners that signed the request digest.
     * @param signatures Signatures corresponding to `signers`.
     * @custom:throws OnlyEtherFiSafe If `safe` is not an EtherFiSafe.
     * @custom:throws InvalidInput If `token`, `linkSigner` or `amount` is zero.
     * @custom:throws EscrowShortfall If the module already holds less `token` than its liabilities.
     * @custom:throws LinkSignerUsed If `linkSigner` was used by any earlier link.
     * @custom:throws FeeMismatch If `feeBps` differs from the current fee.
     * @custom:throws PendingLinkExists If the safe already has a `Requested` link.
     * @custom:throws PendingWithdrawalExists If CashModule holds a pending withdrawal for the safe.
     * @custom:throws InvalidSignatures If the signatures don't meet the safe's threshold.
     * @custom:throws UnexpectedWithdrawalOutcome If CashModule neither holds a matching pending
     *                request nor transferred exactly `amount` inline.
     */
    function requestLink(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused nonReentrant onlyEtherFiSafe(safe) {
        _validateRequest(safe, token, amount, linkSigner, feeBps);

        uint256 nonce = _useNonce(safe);
        bytes32 digest = _requestLinkDigest(safe, token, amount, linkSigner, feeBps, nonce);
        _checkOwnerSignatures(safe, digest, signers, signatures);

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
     *         over `Claim(linkSigner, recipient)`, so a relayed signature cannot be redirected.
     * @dev Permissionless submission. The fee is the link's snapshotted rate, rounded down, and
     *      is waived when `recipient` is an EtherFiSafe or no fee receiver is configured. In a
     *      shortfall the gross payout is pro rata (see `_grossPayout`).
     * @param linkSigner The link ID.
     * @param recipient The address to pay.
     * @param signature The link key's signature over `claimDigest(linkSigner, recipient)`.
     * @custom:throws LinkNotClaimable If the link is not `Funded`.
     * @custom:throws InvalidInput If `recipient` is zero or this module.
     * @custom:throws InvalidClaimSignature If the signature was not made by `linkSigner`.
     */
    function claim(address linkSigner, address recipient, bytes calldata signature) external whenNotPaused nonReentrant {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        Link storage link = $.links[linkSigner];
        if (link.status != LinkStatus.Funded) revert LinkNotClaimable();
        if (recipient == address(0) || recipient == address(this)) revert InvalidInput();

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(_claimDigest(linkSigner, recipient), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != linkSigner) revert InvalidClaimSignature();

        address token = link.token;
        uint256 amount = link.amount;
        uint256 gross = _grossPayout($, token, amount);
        address feeReceiver = $.feeReceiver;
        uint256 fee = (feeReceiver == address(0) || etherFiDataProvider.isEtherFiSafe(recipient)) ? 0 : gross.mulDiv(link.feeBps, HUNDRED_PERCENT_IN_BPS);

        link.status = LinkStatus.Claimed;
        $.liabilities[token] -= amount;

        if (fee > 0) IERC20(token).safeTransfer(feeReceiver, fee);
        if (gross > fee) IERC20(token).safeTransfer(recipient, gross - fee);

        emit LinkClaimed(link.safe, linkSigner, recipient, token, gross - fee, fee);
    }

    /**
     * @notice Cancels a `Requested` or `Funded` link, signed by the safe's CURRENT owners. A
     *         requested link releases its CashModule hold; a funded link's escrow returns to the
     *         safe (pro rata in a shortfall, never with a fee).
     * @dev Deliberately not gated by pause, so a sender can always get their funds back. For a
     *      `Requested` link the state is cleared BEFORE `cancelWithdrawalByModule`, so CashModule's
     *      `cancelBridgeByCashModule` callback finds nothing to do.
     * @param linkSigner The link ID.
     * @param signers Safe owners that signed `cancelLinkDigest(linkSigner)`.
     * @param signatures Signatures corresponding to `signers`.
     * @custom:throws LinkNotCancellable If the link is neither `Requested` nor `Funded`.
     * @custom:throws InvalidSignatures If the signatures don't meet the safe's threshold.
     */
    function cancel(address linkSigner, address[] calldata signers, bytes[] calldata signatures) external nonReentrant {
        PaymentLinkModuleStorage storage $ = _getPaymentLinkModuleStorage();
        Link storage link = $.links[linkSigner];
        LinkStatus status = link.status;
        if (status != LinkStatus.Requested && status != LinkStatus.Funded) revert LinkNotCancellable();

        address safe = link.safe;
        uint256 nonce = _useNonce(safe);
        _checkOwnerSignatures(safe, _cancelLinkDigest(safe, linkSigner, nonce), signers, signatures);

        if (status == LinkStatus.Requested) _cancelRequested($, link, safe, linkSigner);
        else _cancelFunded($, link, safe, linkSigner);
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
     * @custom:throws InvalidInput If `_feeReceiver` is zero while `_feeBps` is non-zero.
     */
    function setFee(uint16 _feeBps, address _feeReceiver) external onlyAdminTimelock {
        _setFee(_feeBps, _feeReceiver);
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
     * @notice Returns the EIP-712 digest the link key signs to claim to `recipient`.
     * @param linkSigner The link ID.
     * @param recipient The recipient bound into the signature.
     * @return The EIP-712 typed-data digest.
     */
    function claimDigest(address linkSigner, address recipient) external view returns (bytes32) {
        return _claimDigest(linkSigner, recipient);
    }

    /**
     * @notice Returns the EIP-191 digest the safe's owners sign for `requestLink`, at the
     *         module's current nonce for `safe`.
     * @dev This is the prefixed hash `checkSignatures` verifies, i.e. what `personal_sign` over
     *      the 32-byte inner hash produces.
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
     * @return The digest to sign.
     */
    function cancelLinkDigest(address linkSigner) external view returns (bytes32) {
        address safe = _getPaymentLinkModuleStorage().links[linkSigner].safe;
        return _cancelLinkDigest(safe, linkSigner, getNonce(safe));
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
    ///      still the link's own request; its callback then no-ops.
    function _cancelRequested(PaymentLinkModuleStorage storage $, Link storage link, address safe, address linkSigner) internal {
        link.status = LinkStatus.Cancelled;
        delete $.pendingLink[safe];

        address token = link.token;
        if (_matchesPendingWithdrawal(safe, token, link.amount)) cashModule.cancelWithdrawalByModule(safe);

        emit LinkCancelled(safe, linkSigner, token, 0);
    }

    /// @dev `Funded` → `Cancelled`. The refund is computed from the pre-mutation snapshot, carries
    ///      no fee and only ever goes to the link's own safe.
    function _cancelFunded(PaymentLinkModuleStorage storage $, Link storage link, address safe, address linkSigner) internal {
        address token = link.token;
        uint256 amount = link.amount;
        uint256 gross = _grossPayout($, token, amount);

        link.status = LinkStatus.Cancelled;
        $.liabilities[token] -= amount;

        if (gross > 0) IERC20(token).safeTransfer(safe, gross);

        emit LinkCancelled(safe, linkSigner, token, gross);
    }

    /**
     * @dev Gross payout for exiting a funded link of `amount`, from a snapshot of the module's
     *      balance and liabilities in `token` taken before any state change. In a shortfall
     *      (`balance < liabilities`) every exit is paid `amount * balance / liabilities`, rounded
     *      down, which keeps the remaining ratio unchanged (floor rounding slightly favours later
     *      exits). Other tokens are never touched.
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

    /// @dev EIP-191 owner digest for `requestLink`, bound to chain, module, nonce and safe.
    function _requestLinkDigest(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(REQUEST_LINK_SIG, block.chainid, address(this), nonce, safe, abi.encode(token, amount, linkSigner, feeBps))).toEthSignedMessageHash();
    }

    /// @dev EIP-191 owner digest for `cancel`, bound to chain, module, nonce, safe and link.
    function _cancelLinkDigest(address safe, address linkSigner, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(CANCEL_LINK_SIG, block.chainid, address(this), nonce, safe, linkSigner)).toEthSignedMessageHash();
    }

    /// @dev EIP-712 digest of `Claim(linkSigner, recipient)` under this module's domain.
    function _claimDigest(address linkSigner, address recipient) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR(), keccak256(abi.encode(CLAIM_TYPEHASH, linkSigner, recipient)));
    }

    /// @dev Shared by `initialize` and `setFee`. Zero bps disables the fee (the receiver may then
    ///      be zero too); a non-zero fee requires a real receiver.
    function _setFee(uint16 _feeBps, address _feeReceiver) internal {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_feeBps > 0 && _feeReceiver == address(0)) revert InvalidInput();
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
