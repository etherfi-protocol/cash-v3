// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { BeaconFactory } from "../beacon-factory/BeaconFactory.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { EtherFiSafe } from "../safe/EtherFiSafe.sol";
import { TradingSafe } from "./TradingSafe.sol";

/**
 * @title TradingSafeFactory
 * @author ether.fi
 * @notice Beacon-factory for the mainnet `TradingSafe`. Each user's TradingSafe address is
 *         derived deterministically from their source-chain (OP) safe address via CREATE3 —
 *         so the destination-chain receiver can pre-compute the address before deployment
 *         and the lazy-deploy service can deploy on first need.
 * @dev Mirrors `EtherFiSafeFactory` in shape; differs in the salt-from-source-safe
 *      derivation and in implementing `ITradingSafeFactory.getDeterministicAddress(address)`.
 */
contract TradingSafeFactory is BeaconFactory, ITradingSafeFactory {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.TradingSafeFactory
    struct TradingSafeFactoryStorage {
        /// @notice Set containing addresses of all deployed `TradingSafe` instances.
        EnumerableSetLib.AddressSet deployedAddresses;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TradingSafeFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TradingSafeFactoryStorageLocation = 0x6f73a87d34a1d2cb7f9a2bca7e3a4f9e6f81b41c2a1c1e16e8c11f3a5c8b8800;

    /// @notice Role required to deploy a new `TradingSafe` (held by the BE lazy-deploy
    ///         service or 3CP admin for the misroute path).
    bytes32 public constant TRADING_SAFE_FACTORY_ADMIN_ROLE = keccak256("TRADING_SAFE_FACTORY_ADMIN_ROLE");

    /// @notice Reverts when `deployTradingSafe` is called by an account lacking the admin role.
    error OnlyAdmin();
    /// @notice Reverts when `getDeployedAddresses` is called with an out-of-bounds start index.
    error InvalidStartIndex();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises the factory.
     * @param _roleRegistry Address of the role registry contract.
     * @param _tradingSafeImpl Address of the `TradingSafe` implementation contract used by
     *        the beacon proxy.
     */
    function initialize(address _roleRegistry, address _tradingSafeImpl) external initializer {
        __BeaconFactory_initialize(_roleRegistry, _tradingSafeImpl);
    }

    /**
     * @dev Returns the storage struct for `TradingSafeFactory`.
     * @return $ Reference to the `TradingSafeFactoryStorage` struct.
     */
    function _getTradingSafeFactoryStorage() internal pure returns (TradingSafeFactoryStorage storage $) {
        assembly {
            $.slot := TradingSafeFactoryStorageLocation
        }
    }

    /**
     * @dev Derives the deterministic CREATE3 salt for `sourceSafe`. The salt is namespaced
     *      by the literal string "TradingSafe" so it can't collide with salts from other
     *      factories that also key off `sourceSafe`.
     * @param sourceSafe Source-chain safe address.
     * @return The CREATE3 salt.
     */
    function _saltFor(address sourceSafe) internal pure returns (bytes32) {
        return keccak256(abi.encode("TradingSafe", sourceSafe));
    }

    /**
     * @notice Returns the deterministic deployment address for a `TradingSafe` derived from
     *         `sourceSafe` — usable before the safe is deployed.
     * @param sourceSafe Source-chain (OP) safe address.
     * @return The address at which the `TradingSafe` will be (or has been) deployed.
     */
    function getDeterministicAddress(address sourceSafe) external view returns (address) {
        return BeaconFactory.getDeterministicAddress(_saltFor(sourceSafe));
    }

    /**
     * @notice Deploys a new `TradingSafe` for `sourceSafe`.
     * @dev Only callable by addresses holding `TRADING_SAFE_FACTORY_ADMIN_ROLE`. The deployed
     *      address is deterministic from `sourceSafe`; calling with the same `sourceSafe`
     *      twice will revert at the CREATE3 layer (proxy already deployed).
     * @param sourceSafe Source-chain safe address; drives the deterministic destination address.
     * @param _owners Initial owner set for the TradingSafe.
     * @param _modules Modules to enable at deploy.
     * @param _moduleSetupData Per-module init data; same length as `_modules`.
     * @param _threshold Initial signature threshold.
     * @custom:throws OnlyAdmin if caller lacks the admin role.
     */
    function deployTradingSafe(
        address sourceSafe,
        address[] calldata _owners,
        address[] calldata _modules,
        bytes[] calldata _moduleSetupData,
        uint8 _threshold
    ) external whenNotPaused returns (address) {
        if (!roleRegistry().hasRole(TRADING_SAFE_FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();

        bytes32 salt = _saltFor(sourceSafe);
        bytes memory initData = abi.encodeWithSelector(EtherFiSafe.initialize.selector, _owners, _modules, _moduleSetupData, _threshold);

        address deterministicAddr = BeaconFactory.getDeterministicAddress(salt);
        _getTradingSafeFactoryStorage().deployedAddresses.add(deterministicAddr);

        return _deployBeacon(salt, initData);
    }

    /**
     * @notice Returns a slice of deployed `TradingSafe` addresses.
     * @param start Starting index in the `deployedAddresses` set.
     * @param n Maximum number of addresses to return.
     * @return Array of deployed addresses (length may be less than `n` if near the end).
     * @custom:throws InvalidStartIndex if `start >= length`.
     */
    function getDeployedAddresses(uint256 start, uint256 n) external view returns (address[] memory) {
        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();
        uint256 length = $.deployedAddresses.length();
        if (start >= length) revert InvalidStartIndex();
        if (start + n > length) n = length - start;
        address[] memory addresses = new address[](n);

        for (uint256 i = 0; i < n;) {
            addresses[i] = $.deployedAddresses.at(start + i);
            unchecked {
                ++i;
            }
        }
        return addresses;
    }

    /**
     * @notice Returns the number of `TradingSafe`s deployed by this factory.
     * @return Number of deployed instances.
     */
    function numContractsDeployed() external view returns (uint256) {
        return _getTradingSafeFactoryStorage().deployedAddresses.length();
    }

    /**
     * @notice Checks whether `safeAddr` was deployed by this factory.
     * @dev Named `isEtherFiSafe` (not `isTradingSafe`) so this factory satisfies the
     *      `IEtherFiSafeFactory.isEtherFiSafe(address)` selector that the destination-chain
     *      `EtherFiDataProvider` delegates to. On mainnet, the only EtherFiSafes are
     *      TradingSafes.
     * @param safeAddr The address to check.
     * @return True if the address is a known TradingSafe deployed by this factory.
     */
    function isEtherFiSafe(address safeAddr) external view returns (bool) {
        return _getTradingSafeFactoryStorage().deployedAddresses.contains(safeAddr);
    }
}
