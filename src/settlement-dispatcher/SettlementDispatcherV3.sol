// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { SettlementDispatcherV2 } from "./SettlementDispatcherV2.sol";
import { MessagingFee, SendParam } from "../interfaces/IOFT.sol";
import { BinSponsor } from "../interfaces/ICashModule.sol";

/**
 * @title SettlementDispatcherV3
 * @author ether.fi
 * @notice Extends SettlementDispatcherV2 with same-chain settlement (no bridging).
 *         Adds a `settle()` function that transfers tokens directly to a per-token
 *         recipient on the same chain. Inherits all V2 functionality (bridging,
 *         Frax redeem, Midas redeem, liquid withdrawal, refund wallet).
 *
 *         Key difference from V2:
 *         - `settle(token, amount)` — direct ERC20 transfer to per-token recipient (no bridge)
 *         - Per-token settlement recipients via `setSettlementRecipients(tokens[], recipients[])`
 *         - V2's `bridge()` still available for cross-chain settlement if needed
 */
contract SettlementDispatcherV3 is SettlementDispatcherV2 {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:etherfi.storage.SettlementDispatcherV3
    struct SettlementDispatcherV3Storage {
        /// @notice Per-token settlement recipient (e.g. Rain for USDC, Reap for USDT)
        mapping(address token => address recipient) settlementRecipient;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.SettlementDispatcherV3")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SettlementDispatcherV3StorageLocation =
        0x6d11ee96cac35ecad8883ed28e44d0b0c4be53c8d438aa0cd81c53334217b000;

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Emitted when tokens are settled (transferred to the per-token recipient)
    event FundsSettled(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when a settlement recipient is configured for a token
    event SettlementRecipientSet(address indexed token, address indexed recipient);

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Thrown when no settlement recipient is configured for the token
    error SettlementRecipientNotSet();

    /// @notice Thrown when a deprecated bridging function is called
    error Deprecated();

    // ═══════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(BinSponsor _binSponsor, address _dataProvider) SettlementDispatcherV2(_binSponsor, _dataProvider) {}

    function _getV3Storage() internal pure returns (SettlementDispatcherV3Storage storage $) {
        assembly {
            $.slot := SettlementDispatcherV3StorageLocation
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                      ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Sets settlement recipients for multiple tokens at once
     * @dev Only callable by the role registry owner. Each token can have a different recipient.
     * @param tokens Array of token addresses to configure
     * @param recipients Array of recipient addresses corresponding to each token
     * @custom:throws InvalidValue If arrays have different lengths or any address is zero
     */
    function setSettlementRecipients(address[] calldata tokens, address[] calldata recipients) external onlyRoleRegistryOwner {
        if (tokens.length != recipients.length) revert InvalidValue();
        SettlementDispatcherV3Storage storage $ = _getV3Storage();
        for (uint256 i = 0; i < tokens.length;) {
            if (tokens[i] == address(0) || recipients[i] == address(0)) revert InvalidValue();
            $.settlementRecipient[tokens[i]] = recipients[i];
            emit SettlementRecipientSet(tokens[i], recipients[i]);
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Returns the settlement recipient configured for a specific token
     * @param token Address of the token to query
     * @return The recipient address for the specified token
     */
    function getSettlementRecipient(address token) external view returns (address) {
        return _getV3Storage().settlementRecipient[token];
    }

    // ═══════════════════════════════════════════════════════════════
    //                   SETTLEMENT (DIRECT TRANSFER)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Settles funds by transferring tokens directly to the per-token settlement recipient
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE when not paused.
     *      Intended for same-chain settlement (e.g. USDC/USDT on Optimism).
     *      For cross-chain settlement, use the inherited bridge() function from V2.
     *      For non-stablecoins, first redeem via redeemFraxToUsdc / withdrawLiquidAsset / redeemMidasToAsset,
     *      then call settle() with the resulting USDC.
     * @param token Address of the token to settle
     * @param amount Amount of tokens to transfer to the recipient
     * @custom:throws InvalidValue If token is zero address or amount is zero
     * @custom:throws SettlementRecipientNotSet If no recipient is configured for this token
     * @custom:throws InsufficientBalance If the contract holds less than the requested amount
     * @custom:emits FundsSettled with token, recipient, and amount
     */
    function settle(address token, uint256 amount) external nonReentrant whenNotPaused onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        if (token == address(0) || amount == 0) revert InvalidValue();

        address recipient = _getV3Storage().settlementRecipient[token];
        if (recipient == address(0)) revert SettlementRecipientNotSet();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();

        IERC20(token).safeTransfer(recipient, amount);
        emit FundsSettled(token, recipient, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                   DEPRECATED (BRIDGING DISABLED)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice [DEPRECATED] Cross-chain bridging is disabled in V3. Use settle() for same-chain settlement.
     * @dev Always reverts. Overrides V2's bridge() to prevent cross-chain transfers.
     */
    function bridge(address, uint256, uint256) external payable override {
        revert Deprecated();
    }

    /**
     * @notice [DEPRECATED] Setting destination data is not needed in V3 (no bridging).
     *         Use setSettlementRecipients() to configure per-token recipients instead.
     * @dev Always reverts. Overrides V2's setDestinationData().
     */
    function setDestinationData(address[] calldata, DestinationData[] calldata) external pure override {
        revert Deprecated();
    }

    /**
     * @notice [DEPRECATED] Destination data is not used in V3 (no bridging).
     * @dev Always reverts. Overrides V2's destinationData().
     */
    function destinationData(address) public view override returns (DestinationData memory) {
        revert Deprecated();
    }

    /**
     * @notice [DEPRECATED] Stargate bridging is not available in V3.
     * @dev Always reverts. Overrides V2's prepareRideBus().
     */
    function prepareRideBus(address, uint256) public view override returns (address, uint256, uint256, SendParam memory, MessagingFee memory) {
        revert Deprecated();
    }

    /**
     * @notice [DEPRECATED] OFT bridging is not available in V3.
     * @dev Always reverts. Overrides V2's prepareOftSend().
     */
    function prepareOftSend(address, uint256) public view override returns (address, uint256, uint256, SendParam memory, MessagingFee memory) {
        revert Deprecated();
    }
}
