// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";

/**
 * @title EtherFiOFTAdapter
 * @author ether.fi
 * @notice Lock-on-deposit OFT adapter beacon implementation deployed once per chain
 *         and reused for every wrapped ERC-20 via a {BeaconFactory}-style proxy.
 * @dev Unlike the upstream `OFTAdapterUpgradeable`, the underlying token is held in
 *      ERC-7201 storage rather than as an immutable. This is what lets ONE
 *      implementation back many per-token beacon proxies (the {OFTAdapterFactory}
 *      pattern).
 *
 *      The LayerZero endpoint and shared `decimalConversionRate` are immutable in
 *      {OFTCoreUpgradeable}'s constructor. That is fine for the impl: one endpoint
 *      per chain, and `_localDecimals` is set conservatively (default 18). Tokens
 *      whose mainnet decimals differ from this impl's `_localDecimals` must use a
 *      separate beacon impl.
 *
 *      Per-proxy logic (deposit lock / withdraw unlock) is left as a TODO so this
 *      file remains a compiling skeleton.
 */
contract EtherFiOFTAdapter is OFTCoreUpgradeable {
    /// @custom:storage-location erc7201:etherfi.storage.EtherFiOFTAdapter
    struct EtherFiOFTAdapterStorage {
        /// @notice The underlying ERC-20 locked by this adapter
        address innerToken;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiOFTAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiOFTAdapterStorageLocation = 0x200710ada2aa0ef551cda8c009b7014f4db5ac2e23f395322943d7626f47ff00;

    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();

    /**
     * @dev Constructor fixes the LZ endpoint and local decimals for this beacon impl.
     * @param _lzEndpoint LayerZero endpoint on the local chain
     * @param _localDecimals Local decimal precision the impl supports (e.g. 18)
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint, uint8 _localDecimals) OFTCoreUpgradeable(_localDecimals, _lzEndpoint) {
        if (_lzEndpoint == address(0)) revert InvalidAddress();
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

        _getStorage().innerToken = _innerToken;
    }

    /**
     * @notice Returns the underlying ERC-20 wrapped by this adapter
     * @return The inner token address
     */
    function token() public view returns (address) {
        return _getStorage().innerToken;
    }

    /**
     * @notice Indicates that callers must approve {token()} before sending
     * @return True — lock-on-deposit requires ERC-20 approval
     */
    function approvalRequired() external pure virtual returns (bool) {
        return true;
    }

    /**
     * @dev Lock the caller's underlying tokens before bridging out
     * @param _from Source of funds
     * @param _amountLD Local-decimal amount the user wants to send
     * @param _minAmountLD Minimum acceptable receive amount (slippage)
     * @param _dstEid Destination LayerZero endpoint ID
     * @return amountSentLD Amount actually pulled in local decimals
     * @return amountReceivedLD Amount that will be credited on the remote
     */
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        _from;
        // TODO: IERC20(token()).safeTransferFrom(_from, address(this), amountSentLD);
    }

    /**
     * @dev Unlock and transfer underlying tokens to the recipient on credit
     * @param _to Recipient
     * @param _amountLD Local-decimal amount to release
     * @return amountReceivedLD Amount actually transferred out
     */
    function _credit(address _to, uint256 _amountLD, uint32 /*_srcEid*/ )
        internal
        virtual
        override
        returns (uint256 amountReceivedLD)
    {
        _to;
        // TODO: IERC20(token()).safeTransfer(_to, _amountLD);
        return _amountLD;
    }

    function _getStorage() private pure returns (EtherFiOFTAdapterStorage storage $) {
        assembly {
            $.slot := EtherFiOFTAdapterStorageLocation
        }
    }
}
