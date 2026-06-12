// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";

import { ConfigurableOFTBase } from "./ConfigurableOFTBase.sol";
import { PairwiseRateLimiter } from "./PairwiseRateLimiter.sol";

/**
 * @title EtherFiOFTAdapter
 * @author ether.fi
 * @notice Lock-on-deposit OFT adapter beacon implementation deployed ONCE per chain
 *         and reused for every wrapped ERC-20 via a {BeaconFactory}-style proxy.
 * @dev Option 1 (single beacon for all assets). Both the underlying token AND its
 *      decimal conversion rate live in ERC-7201 per-proxy storage, set in
 *      {initialize}. That is what lets ONE implementation back proxies for tokens
 *      of any decimal precision (6 / 8 / 18 ...), unlike the upstream
 *      `OFTAdapterUpgradeable` which bakes both into immutables.
 *
 *      The LayerZero endpoint stays immutable in {OFTCoreUpgradeable} (constant per
 *      chain, so one beacon impl per chain is correct). The parent's immutable
 *      `decimalConversionRate` is set to a dead placeholder and is fully shadowed
 *      by the storage value via the {_toLD}/{_toSD}/{_removeDust} overrides below.
 *
 *      KNOWN WART: the inherited public getter `decimalConversionRate()` returns the
 *      dead placeholder, not the per-proxy rate. Solidity does not allow overriding
 *      an auto-generated getter. Internal math is correct; external readers should
 *      use {conversionRate()}.
 */
contract EtherFiOFTAdapter is ConfigurableOFTBase, PairwiseRateLimiter {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:etherfi.storage.EtherFiOFTAdapter
    struct EtherFiOFTAdapterStorage {
        /// @notice The underlying ERC-20 locked by this adapter
        address innerToken;
        /// @notice 10 ** (innerToken.decimals() - sharedDecimals()); shadows the parent immutable
        uint256 decimalConversionRate;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiOFTAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiOFTAdapterStorageLocation = 0x200710ada2aa0ef551cda8c009b7014f4db5ac2e23f395322943d7626f47ff00;

    /// @dev Dead placeholder fed to the parent constructor; the real rate lives in storage.
    uint8 private constant PLACEHOLDER_LOCAL_DECIMALS = 18;

    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();
    /// @notice Thrown when the underlying is not a lossless (1-in-1-out) token, e.g. fee-on-transfer
    error NonLosslessTransfer(uint256 expected, uint256 received);

    /**
     * @dev Constructor fixes only the LZ endpoint for this beacon impl. Decimals are
     *      per-proxy (storage), so no per-impl decimals argument is needed.
     * @param _lzEndpoint LayerZero endpoint on the local chain
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint, address _configRegistry) OFTCoreUpgradeable(PLACEHOLDER_LOCAL_DECIMALS, _lzEndpoint) ConfigurableOFTBase(_configRegistry) {
        if (_lzEndpoint == address(0) || _configRegistry == address(0)) revert InvalidAddress();
        _disableInitializers();
    }

    /**
     * @notice Initializes the adapter proxy for a specific underlying token
     * @param _innerToken Underlying ERC-20 to lock on deposit
     * @param _delegate LayerZero delegate (OApp owner; can set peers/options)
     */
    function initialize(address _innerToken, address _delegate) external initializer {
        if (_innerToken == address(0) || _delegate == address(0)) revert InvalidAddress();
        __Ownable_init(_delegate);
        __OFTCore_init(_delegate);
        __Pausable_init();

        uint8 localDecimals = IERC20Metadata(_innerToken).decimals();
        if (localDecimals < sharedDecimals()) revert InvalidLocalDecimals();

        EtherFiOFTAdapterStorage storage $ = _getStorage();
        $.innerToken = _innerToken;
        $.decimalConversionRate = 10 ** (localDecimals - sharedDecimals());
    }

    /// @notice Returns the underlying ERC-20 wrapped by this adapter
    function token() public view returns (address) {
        return _getStorage().innerToken;
    }

    /// @notice The per-proxy decimal conversion rate (use this, not the inherited getter)
    function conversionRate() public view returns (uint256) {
        return _getStorage().decimalConversionRate;
    }

    /// @notice Lock-on-deposit requires ERC-20 approval of {token()}
    function approvalRequired() external pure virtual returns (bool) {
        return true;
    }

    // ---------------------------------------------------------------------
    // Decimal scaling — overridden to read the per-proxy rate from storage
    // instead of the parent's immutable. This is the crux of Option 1.
    // ---------------------------------------------------------------------

    /// @dev SD -> LD: scale up by the per-proxy {conversionRate}.
    function _toLD(uint64 _amountSD) internal view virtual override returns (uint256) {
        return _amountSD * _getStorage().decimalConversionRate;
    }

    /// @dev LD -> SD: scale down by the per-proxy {conversionRate}; reverts if the result exceeds uint64.
    function _toSD(uint256 _amountLD) internal view virtual override returns (uint64) {
        uint256 sd = _amountLD / _getStorage().decimalConversionRate;
        if (sd > type(uint64).max) revert AmountSDOverflowed(sd);
        // casting to 'uint64' is safe because the line above reverts when sd exceeds type(uint64).max
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(sd);
    }

    /// @dev Floors `_amountLD` to a whole multiple of the per-proxy {conversionRate}, dropping sub-SD dust.
    function _removeDust(uint256 _amountLD) internal view virtual override returns (uint256) {
        uint256 rate = _getStorage().decimalConversionRate;
        // Intentional: floors _amountLD to a multiple of `rate`, discarding dust (matches LayerZero OFTCore).
        // forge-lint: disable-next-line(divide-before-multiply)
        return (_amountLD / rate) * rate;
    }

    // ---------------------------------------------------------------------
    // Lock / unlock — read the underlying from storage
    // ---------------------------------------------------------------------

    /**
     * @dev Lock the caller's underlying tokens before bridging out.
     * @dev Enforces a lossless (1-in-1-out) transfer via a pre/post balance check.
     *      Fee-on-transfer assets (e.g. PAXG with the fee switched on) revert here
     *      rather than silently under-collateralizing the shadow supply. Supporting
     *      them (bridging the post-fee amount) is a deliberate per-asset follow-up.
     */
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid) internal virtual override whenNotPaused returns (uint256, uint256) {
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // Meter the dust-removed amount that actually leaves (and is credited on the remote).
        _checkAndUpdateOutboundRateLimit(_dstEid, amountSentLD);

        IERC20 underlying = IERC20(_getStorage().innerToken);
        uint256 balanceBefore = underlying.balanceOf(address(this));
        underlying.safeTransferFrom(_from, address(this), amountSentLD);
        uint256 received = underlying.balanceOf(address(this)) - balanceBefore;
        if (received != amountSentLD) revert NonLosslessTransfer(amountSentLD, received);
        return (amountSentLD, amountReceivedLD);
    }

    /**
     * @dev Unlock and transfer underlying tokens to the recipient on credit.
     * @dev {whenNotPaused} halts receives when paused — the `lzReceive` reverts and the
     *      message becomes retryable on the endpoint, so funds stay locked (not lost) until unpause.
     */
    function _credit(address _to, uint256 _amountLD, uint32 _srcEid) internal virtual override whenNotPaused returns (uint256) {
        _checkAndUpdateInboundRateLimit(_srcEid, _amountLD);
        IERC20(_getStorage().innerToken).safeTransfer(_to, _amountLD);
        return _amountLD;
    }

    function _getStorage() private pure returns (EtherFiOFTAdapterStorage storage $) {
        assembly {
            $.slot := EtherFiOFTAdapterStorageLocation
        }
    }
}
