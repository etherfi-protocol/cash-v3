// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { BeaconFactory } from "../beacon-factory/BeaconFactory.sol";
import { IShadowOFTFactory } from "../interfaces/IShadowOFTFactory.sol";
import { EtherFiShadowOFT } from "./EtherFiShadowOFT.sol";

/**
 * @title ShadowOFTFactory
 * @author ether.fi
 * @notice Destination-chain (e.g. Optimism) beacon factory that deploys mintable
 *         iTOKEN ERC-20s per listed asset.
 * @dev Mirror of {OFTAdapterFactory}. Reusing the same CREATE3 `salt` from the
 *      mainnet adapter deployment makes the iTOKEN address deterministic and
 *      one-to-one with its mainnet adapter.
 */
contract ShadowOFTFactory is IShadowOFTFactory, BeaconFactory {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.ShadowOFTFactory
    struct ShadowOFTFactoryStorage {
        /// @notice Set of all deployed iTOKEN proxies
        EnumerableSetLib.AddressSet deployed;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.ShadowOFTFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ShadowOFTFactoryStorageLocation = 0x5edfce9f0811991d096fdc5a05beca8dafe84565a8c195367b86667f48d17d00;

    /// @notice Role required to deploy new Shadow OFTs
    bytes32 public constant SHADOW_OFT_FACTORY_ADMIN_ROLE = keccak256("SHADOW_OFT_FACTORY_ADMIN_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the factory + create the shared beacon
     * @param _roleRegistry Address of the {RoleRegistry}
     * @param _shadowOFTImpl Address of the {EtherFiShadowOFT} implementation
     */
    function initialize(address _roleRegistry, address _shadowOFTImpl) external initializer {
        __BeaconFactory_initialize(_roleRegistry, _shadowOFTImpl);
    }

    /// @inheritdoc IShadowOFTFactory
    function deployShadowOFT(bytes32 salt, string calldata name, string calldata symbol, address delegate)
        external
        whenNotPaused
        returns (address shadowOFT)
    {
        if (!roleRegistry().hasRole(SHADOW_OFT_FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();

        ShadowOFTFactoryStorage storage $ = _getStorage();
        address predicted = getDeterministicAddress(salt);
        if ($.deployed.contains(predicted)) revert ShadowOFTAlreadyExists();

        bytes memory initData = abi.encodeWithSelector(EtherFiShadowOFT.initialize.selector, name, symbol, delegate);
        shadowOFT = _deployBeacon(salt, initData);

        $.deployed.add(shadowOFT);
        emit ShadowOFTDeployed(salt, shadowOFT, name, symbol);
    }

    /// @inheritdoc IShadowOFTFactory
    function getDeployedShadowOFTs(uint256 start, uint256 n) external view returns (address[] memory shadowOFTs) {
        ShadowOFTFactoryStorage storage $ = _getStorage();
        uint256 length = $.deployed.length();
        if (start >= length) revert InvalidStartIndex();
        if (start + n > length) n = length - start;

        shadowOFTs = new address[](n);
        for (uint256 i = 0; i < n;) {
            shadowOFTs[i] = $.deployed.at(start + i);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IShadowOFTFactory
    function numShadowOFTsDeployed() external view returns (uint256) {
        return _getStorage().deployed.length();
    }

    /// @inheritdoc IShadowOFTFactory
    function isShadowOFT(address account) external view returns (bool) {
        return _getStorage().deployed.contains(account);
    }

    function _getStorage() private pure returns (ShadowOFTFactoryStorage storage $) {
        assembly {
            $.slot := ShadowOFTFactoryStorageLocation
        }
    }
}
