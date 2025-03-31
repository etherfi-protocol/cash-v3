// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IEtherFiSafeFactory {
    /**
    * @notice Deploys a new EtherFiSafe instance
    * @dev Only callable by addresses with ETHERFI_SAFE_FACTORY_ADMIN_ROLE
    * @param salt The salt value used for deterministic deployment
    * @param _owners Array of addresses that will be owners of the safe
    * @param _modules Array of module addresses to be enabled on the safe
    * @param _moduleSetupData Array of setup data corresponding to each module
    * @param _threshold Number of required confirmations for safe transactions
    * @custom:throws OnlyAdmin if caller doesn't have admin role
    * @custom:throws ArrayLengthMismatch if modules and moduleSetupData arrays have different lengths
    */
    function deployEtherFiSafe(bytes32 salt, address[] calldata _owners, address[] calldata _modules, bytes[] calldata _moduleSetupData, uint8 _threshold) external;

    /**
     * @notice Gets deployed EtherFiSafe addresses
     * @dev Returns an array of EtherFiSafe contracts deployed by this factory
     * @param start Starting index in the deployedAddresses array
     * @param n Number of EtherFiSafe contracts to get
     * @return An array of deployed EtherFiSafe contract addresses
     * @custom:throws InvalidStartIndex if start index is invalid
     */
    function getDeployedAddresses(uint256 start, uint256 n) external view returns (address[] memory);

    /**
     * @notice Checks if an address is a deployed EtherFiSafe contract
     * @dev Returns whether the address is in the deployed addresses set
     * @param safeAddr The address to check
     * @return True if the address is a deployed EtherFiSafe contract, false otherwise
     */
    function isEtherFiSafe(address safeAddr) external view returns (bool);

    /**
     * @notice Predicts the deterministic address for a given salt
     * @param salt The salt value used for address prediction
     * @return The predicted deployment address
     */
    function getDeterministicAddress(bytes32 salt) external view returns (address);
}
