// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { BeaconFactory } from "../beacon-factory/BeaconFactory.sol";
import { IConfigurableOFT } from "../interfaces/IConfigurableOFT.sol";
import { IOFTAdapterFactory } from "../interfaces/IOFTAdapterFactory.sol";
import { IOFTConfigRegistry } from "../interfaces/IOFTConfigRegistry.sol";
import { EtherFiOFTAdapter } from "./EtherFiOFTAdapter.sol";

/**
 * @title OFTAdapterFactory
 * @author ether.fi
 * @notice Mainnet beacon factory that deploys lock-on-deposit OFT adapters
 *         per listed ERC-20.
 * @dev Mirrors the {EtherFiSafeFactory} pattern: all adapters share one
 *      {EtherFiOFTAdapter} implementation behind a single {UpgradeableBeacon},
 *      and per-token instances are cheap CREATE3 beacon proxies. A CREATE3
 *      address is deterministic in `(factory, salt)`, so an adapter's address is
 *      predictable on its own chain. Matching the mainnet adapter and OP iTOKEN
 *      addresses one-to-one is a non-goal (it would also require both factories
 *      at the same address per chain); the `salt` is about per-chain
 *      predictability, not cross-chain mirroring.
 */
contract OFTAdapterFactory is IOFTAdapterFactory, BeaconFactory {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.OFTAdapterFactory
    struct OFTAdapterFactoryStorage {
        /// @notice Set of all deployed adapter proxies
        EnumerableSetLib.AddressSet deployed;
        /// @notice Underlying ERC-20 -> adapter proxy
        mapping(address underlying => address adapter) adapterOfUnderlying;
        /// @notice Adapter proxy -> underlying ERC-20
        mapping(address adapter => address underlying) underlyingOfAdapter;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OFTAdapterFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OFTAdapterFactoryStorageLocation = 0x8d1ded4181573371055a42da694667a7d5e090d925c0648033c160cf77d25f00;

    /// @notice Role required to deploy new adapters
    bytes32 public constant OFT_ADAPTER_FACTORY_ADMIN_ROLE = keccak256("OFT_ADAPTER_FACTORY_ADMIN_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the factory + create the shared beacon
     * @param _roleRegistry Address of the {RoleRegistry}
     * @param _adapterImpl Address of the {EtherFiOFTAdapter} implementation
     */
    function initialize(address _roleRegistry, address _adapterImpl) external initializer {
        __BeaconFactory_initialize(_roleRegistry, _adapterImpl);
    }

    /**
     * @notice Deploys a new OFTAdapter beacon proxy for `underlyingToken`
     * @dev Caller must hold the factory admin role. Address is deterministic via CREATE3
     *      so the OP-side `ShadowOFTFactory` can mirror it with the same `salt`.
     * @param salt CREATE3 salt; conventionally `keccak256(abi.encode("EtherFiOFT", underlyingToken))`
     * @param underlyingToken The mainnet ERC-20 to wrap
     * @param delegate LayerZero delegate (typically the protocol owner/multisig)
     * @return adapter Address of the deployed adapter proxy
     */
    function deployAdapter(bytes32 salt, address underlyingToken, address delegate) external whenNotPaused returns (address) {
        if (!roleRegistry().hasRole(OFT_ADAPTER_FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        if (underlyingToken == address(0)) revert InvalidUnderlying();

        OFTAdapterFactoryStorage storage $ = _getStorage();
        if ($.adapterOfUnderlying[underlyingToken] != address(0)) revert AdapterAlreadyExists();

        bytes memory initData = abi.encodeWithSelector(EtherFiOFTAdapter.initialize.selector, underlyingToken, delegate);

        address adapter = _deployBeacon(salt, initData);

        $.deployed.add(adapter);
        $.adapterOfUnderlying[underlyingToken] = adapter;
        $.underlyingOfAdapter[adapter] = underlyingToken;

        emit OFTAdapterDeployed(salt, underlyingToken, adapter);

        // Auto-register + pull canonical LZ config so the new bridge is live without
        // manual setup. Reverts if the factory lacks CONFIG_REGISTRAR_ROLE or the
        // registry is unreachable (fail-hard: never leave a bridge unregistered).
        address registry = IConfigurableOFT(adapter).configRegistry();
        IOFTConfigRegistry(registry).registerBridge(adapter);
        // syncConfig only accepts calls from the registry, so route the post-deploy sync through it.
        IOFTConfigRegistry(registry).syncBridge(adapter, IOFTConfigRegistry(registry).activeDstEids());
        return adapter;
    }

    /**
     * @notice Returns the adapter deployed for an underlying token, or zero if none
     * @param underlyingToken The mainnet ERC-20
     * @return adapter The adapter proxy address (0 if not deployed)
     */
    function adapterOf(address underlyingToken) external view returns (address) {
        return _getStorage().adapterOfUnderlying[underlyingToken];
    }

    /**
     * @notice Returns the underlying token wrapped by a given adapter
     * @param adapter The adapter proxy
     * @return underlyingToken The wrapped ERC-20 address
     */
    function underlyingOf(address adapter) external view returns (address) {
        return _getStorage().underlyingOfAdapter[adapter];
    }

    /**
     * @notice Paginated enumeration of deployed adapter addresses
     * @param start Starting index in the deployment set
     * @param n Maximum number of entries to return
     * @return adapters Array of adapter proxy addresses
     */
    function getDeployedAdapters(uint256 start, uint256 n) external view returns (address[] memory) {
        OFTAdapterFactoryStorage storage $ = _getStorage();
        uint256 length = $.deployed.length();
        if (start >= length) return new address[](0);
        if (start + n > length) n = length - start;

        address[] memory adapters = new address[](n);
        for (uint256 i = 0; i < n;) {
            adapters[i] = $.deployed.at(start + i);
            unchecked {
                ++i;
            }
        }
        return adapters;
    }

    /**
     * @notice Total number of adapters deployed by this factory
     * @return Number of deployed adapters
     */
    function numAdaptersDeployed() external view returns (uint256) {
        return _getStorage().deployed.length();
    }

    function _getStorage() private pure returns (OFTAdapterFactoryStorage storage $) {
        assembly {
            $.slot := OFTAdapterFactoryStorageLocation
        }
    }
}
