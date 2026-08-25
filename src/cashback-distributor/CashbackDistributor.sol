// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ILayerZeroTellerWithReferrer } from "../interfaces/ILayerZeroTellerWithReferrer.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title CashbackDistributor
 * @author ether.fi
 * @notice On-chain settlement gate for ETHFI cashback claims. Custodies the payout funds
 *         itself: `award`/`awardBatch` pay from the contract's own balance, and `awardStaked`
 *         stakes ETHFI into the sETHFI liquid vault before paying out the minted shares. Every
 *         path records the claim as settled. 
 */
contract CashbackDistributor is UpgradeableProxy {
    using SafeERC20 for IERC20;

    /// @notice Role authorized to settle cashback claims (granted to the backend relayer).
    bytes32 public constant CASHBACK_DISTRIBUTOR_ROLE = keccak256("CASHBACK_DISTRIBUTOR_ROLE");

    /// @notice Address of the ETHFI token.
    address public immutable ethfi;

    /// @notice Address of the sETHFI liquid-vault share token.
    address public immutable sEthfi;

    /// @notice Data provider used to check that every cashback recipient is an EtherFiSafe.
    IEtherFiDataProvider public immutable etherFiDataProvider;

    /**
     * @dev Storage structure for CashbackDistributor using the ERC-7201 namespaced diamond storage pattern.
     * @custom:storage-location erc7201:etherfi.storage.CashbackDistributor
     */
    struct CashbackDistributorStorage {
        /// @notice Tracks which claims have already been settled, keyed on `cashback_claim.id`.
        mapping(bytes32 claimId => bool isSettled) settled;
        /// @notice Address of the BoringVault-style teller used to stake ETHFI into sETHFI.
        address teller;
    }

    /**
     * @notice Storage location for CashbackDistributor (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashbackDistributor")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant CashbackDistributorStorageLocation = 0x661a32922cf88012d1662d523c67828e796d955a6aa33bf39e0da3bcf6c7ad00;

    /**
     * @notice Emitted when a single cashback claim is settled.
     * @dev For `award`/`awardBatch`, `token`/`amount` are the paid-out token and amount, and
     *      `sEthfiAmount` is always 0. For `awardStaked`, `token` is the sETHFI address,
     *      `amount` is the ETHFI amount deposited, and `sEthfiAmount` is the sETHFI shares
     *      minted and paid to `recipient`. Off-chain consumers (indexer, audit) key on this
     *      exact signature -- do not change its shape without updating them.
     * @param claimId The claim identifier (`cashback_claim.id`).
     * @param recipient The account the cashback was paid to.
     * @param token The token actually delivered to `recipient`.
     * @param amount The underlying token amount: the ETHFI amount deposited for `awardStaked`,
     *        or the paid-out token amount for `award`/`awardBatch`.
     * @param sEthfiAmount The sETHFI shares delivered to `recipient`; 0 unless settled via `awardStaked`.
     */
    event CashbackAwarded(bytes32 indexed claimId, address indexed recipient, address indexed token, uint256 amount, uint256 sEthfiAmount);

    /**
     * @notice Emitted once per `awardBatch`/`awardStakedBatch` call, summarizing the batch.
     * @param count Number of claims settled in the batch.
     * @param token The token paid out for every claim in the batch; the sETHFI address for
     *        `awardStakedBatch`, mirroring the per-claim staked event convention.
     * @param total Sum of amounts paid out across the batch; for `awardStakedBatch` this is
     *        the total ETHFI deposited, not the shares minted.
     */
    event CashbackBatchAwarded(uint256 count, address token, uint256 total);

    /**
     * @notice Emitted when ERC20 tokens accidentally sent to this contract are rescued.
     * @param token The token rescued.
     * @param to The rescue recipient.
     * @param amount The amount rescued.
     */
    event RescueERC20(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted when native ETH accidentally sent to this contract is rescued.
     * @param to The rescue recipient.
     * @param amount The amount rescued.
     */
    event RescueETH(address indexed to, uint256 amount);

    /**
     * @notice Emitted when the teller used by `awardStaked` is set.
     * @param teller The BoringVault-style teller used to stake ETHFI into sETHFI.
     */
    event TellerSet(address indexed teller);

    /// @notice Thrown when a claim has already been settled.
    error AlreadySettled(bytes32 claimId);

    /// @notice Thrown when `awardBatch` input arrays have mismatched lengths.
    error ArrayLengthMismatch();

    /// @notice Thrown when a rescue's recipient is the zero address.
    error InvalidRecipient();

    /// @notice Thrown when a native ETH rescue transfer fails.
    error EthTransferFailed();

    /// @notice Thrown when this contract's own token balance is below the amount required to settle.
    error InsufficientBalance(address token, uint256 required, uint256 available);

    /// @notice Thrown when a constructor argument or setter is called with an invalid (e.g. zero) address.
    error InvalidValue();

    /// @notice Thrown when `awardStaked` is called before the teller has been set.
    error TellerNotSet();

    /// @notice Thrown when the sETHFI shares minted by the teller are below the caller's minimum.
    error InsufficientSharesMinted(uint256 minShares, uint256 minted);

    /// @notice Thrown by `setTeller` when the teller's `shareLockPeriod()` is nonzero.
    error TellerSharesLocked(uint64 lockPeriod);

    /// @notice Thrown by `setTeller` when the teller's `vault()` is not the sETHFI token.
    error TellerVaultMismatch(address expected, address actual);

    /// @notice Thrown when a cashback recipient is not a registered EtherFiSafe.
    error NotAnEtherFiSafe(address recipient);

    /**
     * @dev Sets the immutable ETHFI/sETHFI/data-provider addresses and disables initializers
     *      on the implementation contract.
     * @param _ethfi Address of the ETHFI token.
     * @param _sEthfi Address of the sETHFI liquid-vault share token.
     * @param _dataProvider Address of the EtherFiDataProvider used to check that every
     *        cashback recipient is a registered EtherFiSafe.
     * @custom:throws InvalidValue If any address is the zero address.
     */
    constructor(address _ethfi, address _sEthfi, address _dataProvider) {
        if (_ethfi == address(0) || _sEthfi == address(0) || _dataProvider == address(0)) revert InvalidValue();

        ethfi = _ethfi;
        sEthfi = _sEthfi;
        etherFiDataProvider = IEtherFiDataProvider(_dataProvider);

        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with the role registry and, optionally, the teller.
     * @dev A nonzero `_teller` goes through the exact same validation as `setTeller`
     *      (vault match, no share lock), so a proxy can launch with `awardStaked` live from
     *      its first block. Passing the zero address leaves the teller unset — `awardStaked`
     *      reverts `TellerNotSet` until the role registry owner calls `setTeller`.
     * @param _roleRegistry Address of the role registry contract.
     * @param _teller Address of the BoringVault-style teller used by `awardStaked`, or the
     *        zero address to leave it unset.
     * @custom:throws TellerVaultMismatch If `_teller` is nonzero and its `vault()` is not the sETHFI token.
     * @custom:throws TellerSharesLocked If `_teller` is nonzero and reports a nonzero `shareLockPeriod()`.
     */
    function initialize(address _roleRegistry, address _teller) external initializer {
        __UpgradeableProxy_init(_roleRegistry);

        if (_teller != address(0)) _setTeller(_teller);
    }

    /**
     * @dev Returns the storage struct for CashbackDistributorStorage
     * @return $ Reference to the CashbackDistributorStorage struct
     */
    function _getCashbackDistributorStorage() internal pure returns (CashbackDistributorStorage storage $) {
        assembly {
            $.slot := CashbackDistributorStorageLocation
        }
    }

    /**
     * @notice Returns whether a cashback claim has already been settled.
     * @param claimId The claim identifier (`cashback_claim.id`).
     * @return True if the claim has already been settled.
     */
    function settled(bytes32 claimId) external view returns (bool) {
        return _getCashbackDistributorStorage().settled[claimId];
    }

    /**
     * @notice Returns the teller currently used by `awardStaked` to stake ETHFI into sETHFI.
     * @return The teller address, or the zero address if unset.
     */
    function teller() external view returns (address) {
        return _getCashbackDistributorStorage().teller;
    }

    /**
     * @notice Settles a single cashback claim, moving `amount` of `token` from this contract's
     *         own balance to `recipient`.
     * @dev Reverts `AlreadySettled` if `claimId` was already settled, so re-broadcasting a
     *      claim whose outcome is unknown is always safe. `amount` of zero is allowed and
     *      still settles the claim. Checks this contract's own balance before touching any
     *      state, so a revert here never marks the claim settled and it remains awardable once
     *      the contract is topped up by the treasury.
     * @param claimId The claim identifier (`cashback_claim.id`).
     * @param recipient The account to pay the cashback to.
     * @param token The token to pay out.
     * @param amount The amount to pay out.
     * @custom:throws NotAnEtherFiSafe If `recipient` is not a registered EtherFiSafe.
     * @custom:throws InsufficientBalance If this contract's own `token` balance is below `amount`.
     */
    function award(bytes32 claimId, address recipient, address token, uint256 amount) external whenNotPaused onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        _checkBalance(token, amount);
        _award(claimId, recipient, token, amount);
    }

    /**
     * @notice Settles many cashback claims for the same token in one transaction.
     * @dev `recipients` and `amounts` must be the same length as `claimIds`, or the whole call
     *      reverts `ArrayLengthMismatch`. If any `claimId` in the batch was already settled, the
     *      whole call reverts `AlreadySettled` for that id, so a batch is all-or-nothing. This
     *      contract's own balance is checked against the sum of `amounts` before any claim in
     *      the batch is settled.
     * @param claimIds The claim identifiers (`cashback_claim.id`) to settle.
     * @param recipients The accounts to pay the cashback to, one per claim.
     * @param token The token to pay out for every claim in the batch.
     * @param amounts The amounts to pay out, one per claim.
     * @custom:throws NotAnEtherFiSafe If any recipient in the batch is not a registered EtherFiSafe.
     * @custom:throws InsufficientBalance If this contract's own `token` balance is below the batch total.
     */
    function awardBatch(bytes32[] calldata claimIds, address[] calldata recipients, address token, uint256[] calldata amounts) external whenNotPaused onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        uint256 len = claimIds.length;
        if (recipients.length != len || amounts.length != len) revert ArrayLengthMismatch();

        uint256 total;
        for (uint256 i = 0; i < len;) {
            total += amounts[i];

            unchecked {
                ++i;
            }
        }

        _checkBalance(token, total);

        for (uint256 i = 0; i < len;) {
            _award(claimIds[i], recipients[i], token, amounts[i]);

            unchecked {
                ++i;
            }
        }

        emit CashbackBatchAwarded(len, token, total);
    }

    /**
     * @notice Settles a single cashback claim by staking `ethfiAmount` of ETHFI into the
     *         sETHFI liquid vault and paying the minted shares to `recipient`.
     * @dev Reverts `AlreadySettled` if `claimId` was already settled, and `TellerNotSet` if the
     *      teller has not been set. Checks this contract's own ETHFI balance before touching
     *      any state, so a revert here never marks the claim settled. Approves the teller for
     *      exactly `ethfiAmount`, deposits into the sETHFI liquid vault via
     *      `ILayerZeroTellerWithReferrer.deposit` -- passing `address(0)` as the referral
     *      (hardcoded: cashback deposits are never referred) -- and measures shares minted by
     *      the balance delta of the sETHFI token (rather than trusting the teller's return
     *      value) -- reverting `InsufficientSharesMinted` if the delta is below `minShares`,
     *      though a compliant teller is expected to enforce its own minimum-mint slippage check
     *      and revert first. The ETHFI approval to the teller is reset to zero once the deposit
     *      completes.
     * @param claimId The claim identifier (`cashback_claim.id`).
     * @param recipient The account to pay the minted sETHFI shares to.
     * @param ethfiAmount The amount of ETHFI to stake.
     * @param minShares The minimum acceptable amount of sETHFI shares to mint.
     * @custom:throws NotAnEtherFiSafe If `recipient` is not a registered EtherFiSafe.
     * @custom:throws TellerNotSet If the teller has not been set.
     * @custom:throws InsufficientBalance If this contract's own ETHFI balance is below `ethfiAmount`.
     * @custom:throws InsufficientSharesMinted If the sETHFI shares minted are below `minShares`.
     */
    function awardStaked(bytes32 claimId, address recipient, uint256 ethfiAmount, uint256 minShares) external whenNotPaused onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        address tellerAddr = _getTellerOrRevert();

        _checkBalance(ethfi, ethfiAmount);

        IERC20(ethfi).forceApprove(tellerAddr, ethfiAmount);

        _awardStaked(tellerAddr, claimId, recipient, ethfiAmount, minShares);

        IERC20(ethfi).forceApprove(tellerAddr, 0);
    }

    /**
     * @notice Settles many staked cashback claims in one transaction, staking each claim's
     *         ETHFI into the sETHFI liquid vault and paying the minted shares to its recipient.
     * @dev The batch is all-or-nothing, exactly like `awardBatch`: mismatched array lengths
     *      revert `ArrayLengthMismatch`, an already-settled `claimId` reverts `AlreadySettled`,
     *      and a non-safe recipient reverts `NotAnEtherFiSafe` -- any of them unwinds the whole
     *      batch. This contract's own ETHFI balance is checked against the sum of
     *      `ethfiAmounts` before any claim settles. The teller is approved once for the batch
     *      total, each claim deposits and measures its own sETHFI balance delta against its own
     *      `minShares` (see `awardStaked`), and the approval is reset to zero after the last
     *      deposit. Emits one `CashbackAwarded` per claim plus a single `CashbackBatchAwarded`
     *      carrying the sETHFI address and the total ETHFI deposited -- the same
     *      token/amount convention as the per-claim staked event.
     * @param claimIds The claim identifiers (`cashback_claim.id`) to settle.
     * @param recipients The accounts to pay the minted sETHFI shares to, one per claim.
     * @param ethfiAmounts The amounts of ETHFI to stake, one per claim.
     * @param minShares The minimum acceptable sETHFI shares to mint, one per claim.
     * @custom:throws NotAnEtherFiSafe If any recipient in the batch is not a registered EtherFiSafe.
     * @custom:throws TellerNotSet If the teller has not been set.
     * @custom:throws InsufficientBalance If this contract's own ETHFI balance is below the batch total.
     * @custom:throws InsufficientSharesMinted If any claim's minted shares are below its `minShares`.
     */
    function awardStakedBatch(bytes32[] calldata claimIds, address[] calldata recipients, uint256[] calldata ethfiAmounts, uint256[] calldata minShares) external whenNotPaused onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        uint256 len = claimIds.length;
        if (recipients.length != len || ethfiAmounts.length != len || minShares.length != len) revert ArrayLengthMismatch();

        address tellerAddr = _getTellerOrRevert();

        uint256 total;
        for (uint256 i = 0; i < len;) {
            total += ethfiAmounts[i];

            unchecked {
                ++i;
            }
        }

        _checkBalance(ethfi, total);

        IERC20(ethfi).forceApprove(tellerAddr, total);

        for (uint256 i = 0; i < len;) {
            _awardStaked(tellerAddr, claimIds[i], recipients[i], ethfiAmounts[i], minShares[i]);

            unchecked {
                ++i;
            }
        }

        IERC20(ethfi).forceApprove(tellerAddr, 0);

        emit CashbackBatchAwarded(len, sEthfi, total);
    }

    /**
     * @notice Sets the teller used by `awardStaked` to stake ETHFI into sETHFI.
     * @dev Only callable by the role registry owner. The teller is an operational dependency
     *      that can rotate, so -- unlike ETHFI/sETHFI -- it is mutable storage rather than an
     *      implementation-level immutable. Requires `_teller.vault() == sEthfi`: for this
     *      teller, the BoringVault IS the share token, so its `vault()` must return the same
     *      address as the sETHFI immutable, catching a teller misconfigured against the wrong
     *      vault; reverts `TellerVaultMismatch` otherwise (including if the call itself
     *      reverts, e.g. the address isn't a teller at all). Separately, makes a best-effort
     *      `staticcall` to the teller's `shareLockPeriod()` and reverts `TellerSharesLocked` if
     *      it returns nonzero: `awardStaked` transfers freshly minted shares to the recipient in
     *      the same transaction as the deposit, which the vault itself rejects while shares are
     *      locked. That check is best-effort -- if the `staticcall` itself fails (e.g. the
     *      teller doesn't implement `shareLockPeriod()`), this setter does not block on it,
     *      since it cannot distinguish "unsupported" from "zero" from the outside.
     * @param _teller Address of the BoringVault-style teller.
     * @custom:throws OnlyRoleRegistryOwner If the caller is not the role registry owner.
     * @custom:throws InvalidValue If `_teller` is the zero address.
     * @custom:throws TellerVaultMismatch If the teller's `vault()` is not the sETHFI token.
     * @custom:throws TellerSharesLocked If the teller reports a nonzero `shareLockPeriod()`.
     */
    function setTeller(address _teller) external onlyRoleRegistryOwner {
        if (_teller == address(0)) revert InvalidValue();

        _setTeller(_teller);
    }

    /**
     * @dev Shared teller validation + store, used by both `initialize` and `setTeller` so the
     *      teller passes the same checks no matter which path sets it. See `setTeller` for the
     *      rationale behind each check.
     */
    function _setTeller(address _teller) internal {
        address actualVault = ILayerZeroTellerWithReferrer(_teller).vault();
        if (actualVault != sEthfi) revert TellerVaultMismatch(sEthfi, actualVault);

        (bool success, bytes memory data) = _teller.staticcall(abi.encodeWithSelector(ILayerZeroTellerWithReferrer.shareLockPeriod.selector));
        if (success && data.length >= 32) {
            uint64 lockPeriod = abi.decode(data, (uint64));
            if (lockPeriod != 0) revert TellerSharesLocked(lockPeriod);
        }

        _getCashbackDistributorStorage().teller = _teller;

        emit TellerSet(_teller);
    }

    /**
     * @notice Rescues ERC20 tokens sent to, or left over on, this contract's address.
     * @dev Since this contract now custodies payout funds directly, this recovers dust or
     *      funds sent by mistake; it is not part of the normal `award`/`awardBatch`/
     *      `awardStaked` flow, and is callable only by the role registry owner. Passing
     *      `amount == type(uint256).max` rescues this contract's entire `token` balance,
     *      resolved at execution time (not at call-construction time): the role registry owner
     *      is a timelock, so the balance when a queued rescue executes can differ from the
     *      balance when it was queued. The sentinel lets a queued "drain everything" rescue
     *      still drain everything whenever it actually executes. The emitted event always
     *      carries the resolved amount, never the sentinel.
     * @param token The token to rescue.
     * @param to The address to send the rescued tokens to.
     * @param amount The amount to rescue, or `type(uint256).max` for this contract's entire
     *        `token` balance at execution time.
     * @custom:throws OnlyRoleRegistryOwner If the caller is not the role registry owner.
     * @custom:throws InvalidRecipient If `to` is the zero address.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyRoleRegistryOwner {
        if (to == address(0)) revert InvalidRecipient();

        uint256 resolvedAmount = amount == type(uint256).max ? IERC20(token).balanceOf(address(this)) : amount;

        IERC20(token).safeTransfer(to, resolvedAmount);

        emit RescueERC20(token, to, resolvedAmount);
    }

    /**
     * @notice Rescues native ETH sent to, or left over on, this contract's address.
     * @dev See `rescueERC20`; the same `type(uint256).max` sentinel (resolved at execution time
     *      to this contract's entire ETH balance) and resolved-amount event apply here.
     * @param to The address to send the rescued ETH to.
     * @param amount The amount of ETH to rescue, or `type(uint256).max` for this contract's
     *        entire ETH balance at execution time.
     * @custom:throws OnlyRoleRegistryOwner If the caller is not the role registry owner.
     * @custom:throws InvalidRecipient If `to` is the zero address.
     * @custom:throws EthTransferFailed If the ETH transfer fails.
     */
    function rescueETH(address to, uint256 amount) external onlyRoleRegistryOwner {
        if (to == address(0)) revert InvalidRecipient();

        uint256 resolvedAmount = amount == type(uint256).max ? address(this).balance : amount;

        (bool success,) = payable(to).call{ value: resolvedAmount }("");
        if (!success) revert EthTransferFailed();

        emit RescueETH(to, resolvedAmount);
    }

    /**
     * @dev Settles one claim: marks it settled, moves the tokens from this contract's own
     *      balance, and emits the per-claim event. `sEthfiAmount` is always 0 here; only
     *      `awardStaked` populates it.
     */
    function _award(bytes32 claimId, address recipient, address token, uint256 amount) internal {
        _checkRecipientIsSafe(recipient);

        CashbackDistributorStorage storage $ = _getCashbackDistributorStorage();

        if ($.settled[claimId]) revert AlreadySettled(claimId);
        $.settled[claimId] = true;

        IERC20(token).safeTransfer(recipient, amount);

        emit CashbackAwarded(claimId, recipient, token, amount, 0);
    }

    /**
     * @dev Settles one staked claim: checks the recipient is a safe, marks the claim settled,
     *      deposits `ethfiAmount` into the sETHFI liquid vault via
     *      `ILayerZeroTellerWithReferrer.deposit` -- passing `address(0)` as the referral
     *      (hardcoded: cashback deposits are never referred) -- measures shares minted by the
     *      balance delta of the sETHFI token (rather than trusting the teller's return value),
     *      pays them to `recipient` and emits the per-claim event. The caller is responsible
     *      for the ETHFI balance check and the teller approval/reset, so a batch can approve
     *      its total once instead of once per claim.
     */
    function _awardStaked(address tellerAddr, bytes32 claimId, address recipient, uint256 ethfiAmount, uint256 minShares) internal {
        _checkRecipientIsSafe(recipient);

        CashbackDistributorStorage storage $ = _getCashbackDistributorStorage();

        if ($.settled[claimId]) revert AlreadySettled(claimId);
        $.settled[claimId] = true;

        uint256 sharesBefore = IERC20(sEthfi).balanceOf(address(this));
        ILayerZeroTellerWithReferrer(tellerAddr).deposit(ERC20(ethfi), ethfiAmount, minShares, address(0));
        uint256 sharesMinted = IERC20(sEthfi).balanceOf(address(this)) - sharesBefore;

        if (sharesMinted < minShares) revert InsufficientSharesMinted(minShares, sharesMinted);

        IERC20(sEthfi).safeTransfer(recipient, sharesMinted);

        emit CashbackAwarded(claimId, recipient, sEthfi, ethfiAmount, sharesMinted);
    }

    /// @dev Returns the configured teller, reverting `TellerNotSet` when it is unset.
    function _getTellerOrRevert() internal view returns (address tellerAddr) {
        tellerAddr = _getCashbackDistributorStorage().teller;
        if (tellerAddr == address(0)) revert TellerNotSet();
    }

    /**
     * @dev Reverts if this contract's own `token` balance is below `required`.
     *      Read-only: performs no state changes, so a revert here never affects settlement.
     */
    function _checkBalance(address token, uint256 required) internal view {
        uint256 available = IERC20(token).balanceOf(address(this));
        if (available < required) revert InsufficientBalance(token, required, available);
    }

    /**
     * @dev Reverts `NotAnEtherFiSafe` unless `recipient` is a registered EtherFiSafe on the
     *      data provider. Cashback settles only into EtherFiSafes — never arbitrary addresses —
     *      so a relayer key compromise (or a typo'd recipient) cannot drain the payout funds
     *      outside the protocol.
     */
    function _checkRecipientIsSafe(address recipient) internal view {
        if (!etherFiDataProvider.isEtherFiSafe(recipient)) revert NotAnEtherFiSafe(recipient);
    }
}
