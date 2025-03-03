// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BeaconFactory, UpgradeableBeacon } from "../beacon-factory/BeaconFactory.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { DelegateCallLib } from "../libraries/DelegateCallLib.sol";
import { EtherFiSafe } from "./EtherFiSafe.sol";

/**
 * @title EtherFiSafeFactory
 * @notice Factory contract for deploying EtherFiSafe instances using the beacon proxy pattern
 * @dev Extends BeaconFactory to provide Beacon Proxy deployment functionality
 * @author ether.fi
 */
contract EtherFiSafeFactory is BeaconFactory {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.EtherFiSafeFactory
    struct EtherFiSafeFactoryStorage {
        /// @notice Set containing addresses of all deployed EtherFiSafe instances
        EnumerableSetLib.AddressSet deployedAddresses;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiSafeFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiSafeFactoryStorageLocation = 0x7b68bad825be4cff21b93fb4c3affc217a6332ab2a96b5858e70f2a15d9f4300;

    /// @notice The ADMIN role for the Safe factory
    bytes32 public constant ETHERFI_SAFE_FACTORY_ADMIN_ROLE = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");

    /// @notice Error thrown when a non-admin tries to deploy a EtherFiSafe contract
    error OnlyAdmin();
    /// @notice Error thrown when the start index is invalid
    error InvalidStartIndex();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the EtherFiSafeFactory contract
     * @dev Sets up the role registry, admin, and beacon implementation
     * @param _roleRegistry Address of the role registry contract
     * @param _etherFiSafeImpl Address of the EtherFiSafe implementation contract
     */
    function initialize(address _roleRegistry, address _etherFiSafeImpl) external initializer {
        __BeaconFactory_initialize(_roleRegistry, _etherFiSafeImpl);
    }

    /**
     * @dev Returns the storage struct for EtherFiSafeFactory
     * @return $ Reference to the EtherFiSafeFactoryStorage struct
     */
    function _getEtherFiSafeFactoryStorage() internal pure returns (EtherFiSafeFactoryStorage storage $) {
        assembly {
            $.slot := EtherFiSafeFactoryStorageLocation
        }
    }

    /**
     * @notice Deploys a new EtherFiSafe instance
     * @dev Only callable by addresses with ETHERFI_SAFE_FACTORY_ADMIN_ROLE
     * @param salt The salt value used for deterministic deployment
     * @custom:throws OnlyAdmin if caller doesn't have admin role
     */
    function deployEtherFiSafe(bytes32 salt, address[] calldata _owners, address[] calldata _modules, bytes[] calldata _moduleSetupData, uint8 _threshold) external {
        if (!roleRegistry().hasRole(ETHERFI_SAFE_FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        bytes memory initData = abi.encodeWithSelector(EtherFiSafe.initialize.selector, _owners, _modules, _moduleSetupData, _threshold);

        address deterministicAddr = getDeterministicAddress(salt);
        EtherFiSafeFactoryStorage storage $ = _getEtherFiSafeFactoryStorage();
        $.deployedAddresses.add(deterministicAddr);

        _deployBeacon(salt, initData);
    }

    /**
     * @notice Gets deployed EtherFiSafe addresses
     * @dev Returns an array of EtherFiSafe contracts deployed by this factory
     * @param start Starting index in the deployedAddresses array
     * @param n Number of EtherFiSafe contracts to get
     * @return An array of deployed EtherFiSafe contract addresses
     * @custom:throws InvalidStartIndex if start index is invalid
     */
    function getDeployedAddresses(uint256 start, uint256 n) external view returns (address[] memory) {
        EtherFiSafeFactoryStorage storage $ = _getEtherFiSafeFactoryStorage();
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
     * @notice Checks if an address is a deployed EtherFiSafe contract
     * @dev Returns whether the address is in the deployed addresses set
     * @param safeAddr The address to check
     * @return True if the address is a deployed EtherFiSafe contract, false otherwise
     */
    function isEtherFiSafe(address safeAddr) external view returns (bool) {
        EtherFiSafeFactoryStorage storage $ = _getEtherFiSafeFactoryStorage();
        return $.deployedAddresses.contains(safeAddr);
    }
}
