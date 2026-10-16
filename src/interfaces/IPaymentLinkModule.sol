// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IBridgeModule } from "./IBridgeModule.sol";

/**
 * @title IPaymentLinkModule
 * @author ether.fi
 * @notice Escrow for payment links. A safe's owners escrow an ERC-20 from their EtherFiSafe into
 *         the module through a CashModule withdrawal request, keyed by a throwaway `linkSigner`
 *         address whose private key travels in the link. Whoever holds that key can claim the
 *         escrow to any recipient; the safe's owners can cancel at any time.
 * @dev The owner nonce used by `requestLinkDigest` / `cancelLinkDigest` is the module's own
 *      per-safe nonce, readable through `ModuleBase.getNonce(safe)`. It is not declared here
 *      because `ModuleBase.getNonce` is not virtual.
 */
interface IPaymentLinkModule is IBridgeModule {
    /// @notice Lifecycle of a link. Any status other than `None` permanently uses up its `linkSigner`.
    enum LinkStatus {
        None,
        Requested,
        Funded,
        Claimed,
        Cancelled,
        RequestCancelled
    }

    /**
     * @notice A payment link, keyed by its `linkSigner`.
     * @param safe The EtherFiSafe that created the link.
     * @param token The escrowed ERC-20.
     * @param amount The requested amount; equals the amount received once `Funded`.
     * @param feeBps The fee rate snapshotted at request, applied only to claims to non-safe recipients.
     * @param status The link's lifecycle status.
     */
    struct Link {
        address safe;
        address token;
        uint256 amount;
        uint16 feeBps;
        LinkStatus status;
    }

    /**
     * @notice Emitted when a safe's owners request a link and the CashModule withdrawal is placed.
     * @param safe The originating safe.
     * @param linkSigner The link ID.
     * @param token The escrowed token.
     * @param amount The requested amount.
     * @param feeBps The fee rate snapshotted for the link.
     */
    event LinkRequested(address indexed safe, address indexed linkSigner, address token, uint256 amount, uint16 feeBps);

    /**
     * @notice Emitted when the escrow for a link has been received and the link becomes claimable.
     * @param safe The originating safe.
     * @param linkSigner The link ID.
     * @param token The escrowed token.
     * @param amount The amount received.
     */
    event LinkFunded(address indexed safe, address indexed linkSigner, address token, uint256 amount);

    /**
     * @notice Emitted when a requested link's CashModule withdrawal was cancelled outside this module
     *         (for example by a card spend) and the link can no longer be funded.
     * @param safe The originating safe.
     * @param linkSigner The link ID.
     */
    event LinkRequestCancelled(address indexed safe, address indexed linkSigner);

    /**
     * @notice Emitted when a funded link is claimed.
     * @param safe The originating safe.
     * @param linkSigner The link ID.
     * @param recipient The address that received the payout.
     * @param token The escrowed token.
     * @param amountPaid The amount transferred to `recipient`, net of `fee`.
     * @param fee The fee transferred to the fee receiver. `amountPaid + fee` is the gross payout.
     */
    event LinkClaimed(address indexed safe, address indexed linkSigner, address indexed recipient, address token, uint256 amountPaid, uint256 fee);

    /**
     * @notice Emitted when a requested or funded link is cancelled by the safe's owners.
     * @param safe The originating safe.
     * @param linkSigner The link ID.
     * @param token The escrowed token.
     * @param amountRefunded The amount returned to `safe` (zero for a link that was never funded).
     */
    event LinkCancelled(address indexed safe, address indexed linkSigner, address token, uint256 amountRefunded);

    /**
     * @notice Emitted when the fee configuration changes.
     * @param oldFeeBps The previous fee in basis points.
     * @param newFeeBps The new fee in basis points.
     * @param oldFeeReceiver The previous fee receiver.
     * @param newFeeReceiver The new fee receiver.
     */
    event FeeSet(uint16 oldFeeBps, uint16 newFeeBps, address oldFeeReceiver, address newFeeReceiver);

    /**
     * @notice Emitted when governance moves surplus (balance above liabilities) out of the module.
     * @param token The rescued token.
     * @param to The recipient.
     * @param amount The amount transferred.
     */
    event SurplusRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Reverts when the owner signatures do not meet the safe's threshold.
    error InvalidSignatures();
    /// @notice Reverts when the claim signature was not produced by the link's key.
    error InvalidClaimSignature();
    /// @notice Reverts when `linkSigner` has already been used by any link.
    error LinkSignerUsed();
    /// @notice Reverts when the fee the owners signed differs from the current fee.
    error FeeMismatch();
    /// @notice Reverts when a fee above `MAX_FEE_BPS` is configured.
    error FeeTooHigh();
    /// @notice Reverts when CashModule already holds a pending withdrawal for the safe.
    error PendingWithdrawalExists();
    /// @notice Reverts when the safe already has a link waiting to be funded.
    error PendingLinkExists();
    /// @notice Reverts when the safe has no link waiting to be funded.
    error NoPendingLink();
    /// @notice Reverts when CashModule's pending withdrawal does not match the requested link.
    error CannotFindMatchingWithdrawal();
    /// @notice Reverts when processing the withdrawal did not deliver exactly the link amount.
    error BalanceDeltaMismatch();
    /// @notice Reverts when CashModule's response to a link request is neither a matching pending
    ///         request nor an exact inline transfer.
    error UnexpectedWithdrawalOutcome();
    /// @notice Reverts when the module holds less of the token than its outstanding liabilities.
    error EscrowShortfall();
    /// @notice Reverts when claiming a link that is not `Funded`.
    error LinkNotClaimable();
    /// @notice Reverts when cancelling a link that is neither `Requested` nor `Funded`.
    error LinkNotCancellable();
    /// @notice Reverts when a rescue exceeds the module's balance above liabilities.
    error InsufficientSurplus();

    /**
     * @notice Creates a link for `linkSigner` and places a CashModule withdrawal of `amount` of
     *         `token` from `safe` with this module as recipient. With a zero CashModule withdrawal
     *         delay the link is funded in the same call.
     * @param safe The EtherFiSafe sending the funds.
     * @param token The ERC-20 to escrow.
     * @param amount The amount to escrow.
     * @param linkSigner The address of the link's private key; the link ID.
     * @param feeBps The fee the owners agreed to; must equal the current fee.
     * @param signers Safe owners that signed `requestLinkDigest`.
     * @param signatures Signatures corresponding to `signers`.
     */
    function requestLink(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps, address[] calldata signers, bytes[] calldata signatures) external;

    /**
     * @notice Processes the matured CashModule withdrawal for the safe's pending link and marks it funded.
     * @param safe The EtherFiSafe whose pending link to fund.
     */
    function fundLink(address safe) external;

    /**
     * @notice Pays a funded link to `recipient`, authorized by a signature from the link's key over
     *         `claimDigest(linkSigner, recipient)`.
     * @param linkSigner The link ID.
     * @param recipient The address to pay.
     * @param signature The link key's signature over `claimDigest(linkSigner, recipient)`.
     */
    function claim(address linkSigner, address recipient, bytes calldata signature) external;

    /**
     * @notice Cancels a requested or funded link, signed by the safe's current owners. A funded
     *         link's escrow returns to the safe.
     * @param linkSigner The link ID.
     * @param signers Safe owners that signed `cancelLinkDigest`.
     * @param signatures Signatures corresponding to `signers`.
     */
    function cancel(address linkSigner, address[] calldata signers, bytes[] calldata signatures) external;

    /**
     * @notice Marks the safe's pending link `RequestCancelled` when CashModule no longer holds its
     *         matching withdrawal request. Does nothing otherwise.
     * @param safe The EtherFiSafe whose pending link to reconcile.
     */
    function reconcile(address safe) external;

    /**
     * @notice Sets the fee charged on claims to non-safe recipients and its receiver.
     * @param feeBps The fee in basis points, at most `MAX_FEE_BPS`.
     * @param feeReceiver The fee receiver; may be zero only when `feeBps` is zero.
     */
    function setFee(uint16 feeBps, address feeReceiver) external;

    /**
     * @notice Transfers surplus (balance above liabilities) of `token` to `to`. Governance only.
     * @param token The token to rescue.
     * @param to The recipient.
     * @param amount The amount, at most `balance - liabilities`.
     */
    function rescueSurplus(address token, address to, uint256 amount) external;

    /**
     * @notice Returns the link stored for `linkSigner` (zeroed when unused).
     * @param linkSigner The link ID.
     * @return The stored link.
     */
    function getLink(address linkSigner) external view returns (Link memory);

    /**
     * @notice Returns the safe's link that is waiting to be funded.
     * @param safe The EtherFiSafe to query.
     * @return linkSigner The pending link ID, or zero if none.
     */
    function getPendingLink(address safe) external view returns (address linkSigner);

    /**
     * @notice Returns the sum of funded, unclaimed and uncancelled link amounts for `token`.
     * @param token The token to query.
     * @return The outstanding liabilities in token units.
     */
    function getLiabilities(address token) external view returns (uint256);

    /**
     * @notice Returns the current fee configuration.
     * @return feeBps The fee in basis points.
     * @return feeReceiver The fee receiver.
     */
    function getFee() external view returns (uint16 feeBps, address feeReceiver);

    /**
     * @notice Returns the EIP-712 digest the link key signs to claim to `recipient`.
     * @param linkSigner The link ID.
     * @param recipient The recipient bound into the signature.
     * @return The EIP-712 typed-data digest.
     */
    function claimDigest(address linkSigner, address recipient) external view returns (bytes32);

    /**
     * @notice Returns the EIP-191 digest the safe's owners sign for `requestLink`, at the safe's current module nonce.
     * @param safe The EtherFiSafe sending the funds.
     * @param token The ERC-20 to escrow.
     * @param amount The amount to escrow.
     * @param linkSigner The link ID.
     * @param feeBps The fee the owners agree to.
     * @return The digest to sign.
     */
    function requestLinkDigest(address safe, address token, uint256 amount, address linkSigner, uint16 feeBps) external view returns (bytes32);

    /**
     * @notice Returns the EIP-191 digest the safe's owners sign for `cancel`, at the link safe's current module nonce.
     * @param linkSigner The link ID.
     * @return The digest to sign.
     */
    function cancelLinkDigest(address linkSigner) external view returns (bytes32);

    /**
     * @notice Returns the EIP-712 domain separator used for claim signatures.
     * @return The domain separator for `{name: "EtherFi PaymentLinkModule", version: "1", chainId, verifyingContract: this}`.
     */
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
