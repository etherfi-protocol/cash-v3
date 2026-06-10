// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

import { ConfigurableOFTBase } from "./ConfigurableOFTBase.sol";

/**
 * @title EtherFiShadowOFT
 * @author ether.fi
 * @notice Mintable iTOKEN beacon implementation deployed ONCE per destination chain
 *         (e.g. Optimism) and reused for every listed asset via the
 *         {ShadowOFTFactory}. Each proxy is its own ERC-20 (distinct name/symbol/
 *         decimals) but shares this single implementation behind a beacon.
 * @dev Option 1 (single beacon for all assets). The local decimals and the decimal
 *      conversion rate live in ERC-7201 per-proxy storage, set in {initialize}, so
 *      ONE implementation serves iTOKENs of any precision and each mirrors its
 *      underlying's `decimals()` exactly (the COR-699 requirement).
 *
 *      The parent's immutable `decimalConversionRate` is shadowed by the storage
 *      value via the {_toLD}/{_toSD}/{_removeDust} overrides. {decimals} is read
 *      from storage; before initialization it returns a safe placeholder so the
 *      parent constructor (which reads `decimals()`) does not revert.
 */
contract EtherFiShadowOFT is OFTUpgradeable, ConfigurableOFTBase {
    /// @custom:storage-location erc7201:etherfi.storage.EtherFiShadowOFT
    struct EtherFiShadowOFTStorage {
        /// @notice Local decimals, mirrors the mainnet underlying
        uint8 localDecimals;
        /// @notice 10 ** (localDecimals - sharedDecimals())
        uint256 decimalConversionRate;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiShadowOFT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiShadowOFTStorageLocation = 0xacd5171b564d1e274f93f0efa9a43f5c85ba6a0cbb05f0ccd0a8bb49c007b800;

    /// @dev Returned by {decimals} before initialization so the parent constructor's
    ///      `decimals()` read passes the `>= sharedDecimals()` check.
    uint8 private constant PLACEHOLDER_LOCAL_DECIMALS = 18;

    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint, address _configRegistry) OFTUpgradeable(_lzEndpoint) ConfigurableOFTBase(_configRegistry) {
        if (_lzEndpoint == address(0) || _configRegistry == address(0)) revert InvalidAddress();
        _disableInitializers();
    }

    /**
     * @notice Initializes a Shadow OFT proxy as a fresh ERC-20 + OApp
     * @param _name ERC-20 name (convention: "EtherFi <NAME>")
     * @param _symbol ERC-20 symbol (convention: "i<SYMBOL>")
     * @param _localDecimals Decimals to mirror from the mainnet underlying
     * @param _delegate LayerZero delegate (OApp owner; can set peers/options)
     */
    function initialize(string memory _name, string memory _symbol, uint8 _localDecimals, address _delegate) external initializer {
        if (_delegate == address(0)) revert InvalidAddress();
        if (_localDecimals < sharedDecimals()) revert InvalidLocalDecimals();

        __Ownable_init(_delegate);
        __OFT_init(_name, _symbol, _delegate);

        EtherFiShadowOFTStorage storage $ = _getStorage();
        $.localDecimals = _localDecimals;
        $.decimalConversionRate = 10 ** (_localDecimals - sharedDecimals());
    }

    /// @notice iTOKEN decimals, mirroring the underlying. Placeholder until initialized.
    function decimals() public view override returns (uint8) {
        uint8 d = _getStorage().localDecimals;
        return d == 0 ? PLACEHOLDER_LOCAL_DECIMALS : d;
    }

    /// @notice The per-proxy decimal conversion rate (use this, not the inherited getter)
    function conversionRate() public view returns (uint256) {
        return _getStorage().decimalConversionRate;
    }

    // ---------------------------------------------------------------------
    // Decimal scaling — overridden to read the per-proxy rate from storage
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

    function _getStorage() private pure returns (EtherFiShadowOFTStorage storage $) {
        assembly {
            $.slot := EtherFiShadowOFTStorageLocation
        }
    }
}
