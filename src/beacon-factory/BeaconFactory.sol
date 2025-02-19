// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title BeaconFactory
 * @author ether.fi
 * @notice Factory contract for deploying beacon proxies with deterministic addresses
 * @dev This contract uses CREATE3 for deterministic deployments and implements UUPS upgradeability pattern
 * @custom:security-contact security@ether.fi
 */
contract BeaconFactory is UpgradeableProxy, PausableUpgradeable {
    bytes32 public constant FACTORY_ADMIN_ROLE = keccak256("FACTORY_ADMIN_ROLE");

    /// @custom:storage-location erc7201:etherfi.storage.BeaconFactory
    struct BeaconFactoryStorage {
        /// @notice The address of the beacon contract that stores the implementation
        address beacon;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.BeaconFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BeaconFactoryStorageLocation = 0x644210a929ca6ee03d33c1a1fe361b36b5a9728941782cd06b1139e4cae58200;

    /// @notice Emitted when the beacon address is updated
    /// @param oldBeacon The previous beacon address
    /// @param newBeacon The new beacon address
    event BeaconSet(address oldBeacon, address newBeacon);

    /// @notice Emitted when a new beacon proxy is deployed
    /// @param deployed The address of the newly deployed proxy
    event BeaconProxyDeployed(address deployed);

    /// @notice Thrown when the deployed address doesn't match the predicted address
    error DeployedAddressDifferentFromExpected();

    /**
     * @dev Initializes the contract with required parameters
     * @param _roleRegistry Address of the role registry contract
     * @param _beaconImpl Address of the initial implementation contract
     */
    function __BeaconFactory_initialize(address _roleRegistry, address _beaconImpl) internal {
        __UpgradeableProxy_init(_roleRegistry);
        __Pausable_init();
        BeaconFactoryStorage storage $ = _getBeaconFactoryStorage();
        $.beacon = address(new UpgradeableBeacon(_beaconImpl, address(this)));
    }

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the BeaconFactoryStorage struct
     */
    function _getBeaconFactoryStorage() private pure returns (BeaconFactoryStorage storage $) {
        assembly {
            $.slot := BeaconFactoryStorageLocation
        }
    }

    /**
     * @dev Deploys a new beacon proxy with deterministic address
     * @param salt The salt value used for deterministic deployment
     * @param initData The initialization data for the proxy
     * @return The address of the deployed proxy
     * @custom:restriction Caller must have FACTORY_ADMIN_ROLE
     */
    function _deployBeacon(bytes32 salt, bytes memory initData) internal returns (address) {
        address expectedAddr = this.getDeterministicAddress(salt);
        address deployedAddr = address(CREATE3.deployDeterministic(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon(), initData)), salt));
        if (expectedAddr != deployedAddr) revert DeployedAddressDifferentFromExpected();

        emit BeaconProxyDeployed(deployedAddr);
        return deployedAddr;
    }

    /**
     * @notice Returns the address of the beacon which stores the implementation
     * @return beacon Address of the beacon contract
     */
    function beacon() public view returns (address) {
        BeaconFactoryStorage storage $ = _getBeaconFactoryStorage();
        return $.beacon;
    }

    /**
     * @notice Predicts the deterministic address for a given salt
     * @param salt The salt value used for address prediction
     * @return The predicted deployment address
     */
    function getDeterministicAddress(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by addresses with the pauser role in the role registry
     * @dev Triggers the Paused event from PausableUpgradeable
     * @custom:restriction Caller must have pauser role
     */
    function pause() external {
        roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by addresses with the unpauser role in the role registry
     * @dev Triggers the Unpaused event from PausableUpgradeable
     * @custom:restriction Caller must have unpauser role
     */
    function unpause() external {
        roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }
}
