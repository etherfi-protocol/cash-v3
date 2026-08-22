// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title CashbackDistributor
 * @author ether.fi
 * @notice On-chain settlement gate for ETHFI cashback claims. Moves cashback from the payout
 *         wallet to the recipient and records the claim as settled, so a claim can be retried
 *         after any failure (network error, unknown broadcast outcome, etc.) without ever
 *         paying twice.
 * @dev Holds no funds: `award`/`awardBatch` move tokens with `transferFrom(msg.sender, ...)`,
 *      so value stays in the payout wallet at all times. There is no balance to secure here,
 *      so there is no `withdrawFunds` and no rescue path. A claim spans multiple sources, so
 *      neither the functions nor the events carry a source field; per-source attribution lives
 *      only in the off-chain ledger.
 */
contract CashbackDistributor is UpgradeableProxy {
    using SafeERC20 for IERC20;

    /// @notice Role authorized to settle cashback claims (granted to the backend relayer).
    bytes32 public constant CASHBACK_DISTRIBUTOR_ROLE = keccak256("CASHBACK_DISTRIBUTOR_ROLE");

    /**
     * @dev Storage structure for CashbackDistributor using the ERC-7201 namespaced diamond storage pattern.
     * @custom:storage-location erc7201:etherfi.storage.CashbackDistributor
     */
    struct CashbackDistributorStorage {
        /// @notice Tracks which claims have already been settled, keyed on `cashback_claim.id`.
        mapping(bytes32 claimId => bool isSettled) settled;
    }

    /**
     * @notice Storage location for CashbackDistributor (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashbackDistributor")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant CashbackDistributorStorageLocation = 0x661a32922cf88012d1662d523c67828e796d955a6aa33bf39e0da3bcf6c7ad00;

    /**
     * @notice Emitted when a single cashback claim is settled.
     * @param claimId The claim identifier (`cashback_claim.id`).
     * @param recipient The account the cashback was paid to.
     * @param token The token paid out.
     * @param amount The amount paid out.
     */
    event CashbackAwarded(bytes32 indexed claimId, address indexed recipient, address indexed token, uint256 amount);

    /**
     * @notice Emitted once per `awardBatch` call, summarizing the batch.
     * @param count Number of claims settled in the batch.
     * @param token The token paid out for every claim in the batch.
     * @param total Sum of amounts paid out across the batch.
     */
    event CashbackBatchAwarded(uint256 count, address token, uint256 total);

    /// @notice Thrown when a claim has already been settled.
    error AlreadySettled(bytes32 claimId);

    /// @notice Thrown when `awardBatch` input arrays have mismatched lengths.
    error ArrayLengthMismatch();

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with the role registry.
     * @param _roleRegistry Address of the role registry contract.
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
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
     * @notice Settles a single cashback claim, moving `amount` of `token` from the caller
     *         (the payout wallet) to `recipient`.
     * @dev Reverts `AlreadySettled` if `claimId` was already settled, so re-broadcasting a
     *      claim whose outcome is unknown is always safe. `amount` of zero is allowed and
     *      still settles the claim.
     * @param claimId The claim identifier (`cashback_claim.id`).
     * @param recipient The account to pay the cashback to.
     * @param token The token to pay out.
     * @param amount The amount to pay out.
     */
    function award(bytes32 claimId, address recipient, address token, uint256 amount) external whenNotPaused onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        _award(claimId, recipient, token, amount);
    }

    /**
     * @notice Settles many cashback claims for the same token in one transaction.
     * @dev `recipients` and `amounts` must be the same length as `claimIds`, or the whole call
     *      reverts `ArrayLengthMismatch`. If any `claimId` in the batch was already settled, the
     *      whole call reverts `AlreadySettled` for that id, so a batch is all-or-nothing.
     * @param claimIds The claim identifiers (`cashback_claim.id`) to settle.
     * @param recipients The accounts to pay the cashback to, one per claim.
     * @param token The token to pay out for every claim in the batch.
     * @param amounts The amounts to pay out, one per claim.
     */
    function awardBatch(bytes32[] calldata claimIds, address[] calldata recipients, address token, uint256[] calldata amounts) external whenNotPaused onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        uint256 len = claimIds.length;
        if (recipients.length != len || amounts.length != len) revert ArrayLengthMismatch();

        uint256 total;
        for (uint256 i = 0; i < len;) {
            _award(claimIds[i], recipients[i], token, amounts[i]);
            total += amounts[i];

            unchecked {
                ++i;
            }
        }

        emit CashbackBatchAwarded(len, token, total);
    }

    /**
     * @dev Settles one claim: marks it settled, moves the tokens, and emits the per-claim event.
     */
    function _award(bytes32 claimId, address recipient, address token, uint256 amount) internal {
        CashbackDistributorStorage storage $ = _getCashbackDistributorStorage();

        if ($.settled[claimId]) revert AlreadySettled(claimId);
        $.settled[claimId] = true;

        IERC20(token).safeTransferFrom(msg.sender, recipient, amount);

        emit CashbackAwarded(claimId, recipient, token, amount);
    }
}
