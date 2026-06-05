// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

/**
 * @title EtherFiShadowOFT
 * @author ether.fi
 * @notice Mintable iTOKEN beacon implementation deployed once per destination chain
 *         (e.g. Optimism) and reused for every listed asset via the
 *         {ShadowOFTFactory}. Each proxy is its own ERC-20 with a distinct
 *         name/symbol, but shares this single implementation behind a beacon.
 * @dev The LayerZero endpoint and `decimalConversionRate` are immutable per impl.
 *      Tokens with non-standard decimals should use a separate impl/beacon.
 */
contract EtherFiShadowOFT is OFTUpgradeable {
    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();

    /**
     * @dev Constructor fixes the LZ endpoint for this beacon impl.
     * @param _lzEndpoint LayerZero endpoint on the local chain
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {
        if (_lzEndpoint == address(0)) revert InvalidAddress();
        _disableInitializers();
    }

    /**
     * @notice Initializes a Shadow OFT proxy as a fresh ERC-20 + OApp
     * @param _name ERC-20 name (convention: "EtherFi <NAME>")
     * @param _symbol ERC-20 symbol (convention: "i<SYMBOL>")
     * @param _delegate LayerZero delegate (OApp owner; can set peers/options)
     */
    function initialize(string memory _name, string memory _symbol, address _delegate) external initializer {
        if (_delegate == address(0)) revert InvalidAddress();
        __Ownable_init(_delegate);
        __OFT_init(_name, _symbol, _delegate);
    }
}
