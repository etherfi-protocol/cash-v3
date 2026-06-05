// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOFTAdapterFactory
 * @author ether.fi
 * @notice Interface for the mainnet OFTAdapter beacon factory
 * @dev Each call to {deployAdapter} produces a lock-on-deposit LayerZero OFTAdapter
 *      beacon proxy for a single underlying ERC-20. All adapters share one upgradeable
 *      implementation behind a single beacon, mirroring the EtherFiSafeFactory pattern.
 */
interface IOFTAdapterFactory {
    /**
     * @notice Emitted when a new OFTAdapter beacon proxy is deployed for an underlying token
     * @param salt The CREATE3 salt used for deterministic deployment (should match the OP side)
     * @param underlyingToken The mainnet ERC-20 being wrapped
     * @param adapter The deployed adapter proxy address
     */
    event OFTAdapterDeployed(bytes32 indexed salt, address indexed underlyingToken, address indexed adapter);

    /// @notice Thrown when the caller is not authorised to deploy
    error OnlyAdmin();
    /// @notice Thrown when the underlying token address is zero
    error InvalidUnderlying();
    /// @notice Thrown when an adapter already exists for the supplied salt/underlying
    error AdapterAlreadyExists();
    /// @notice Thrown when the start index passed to {getDeployedAdapters} is out of bounds
    error InvalidStartIndex();

    /**
     * @notice Deploys a new OFTAdapter beacon proxy for `underlyingToken`
     * @dev Caller must hold the factory admin role. Address is deterministic via CREATE3
     *      so the OP-side `ShadowOFTFactory` can mirror it with the same `salt`.
     * @param salt CREATE3 salt; conventionally `keccak256(abi.encode("EtherFiOFT", underlyingToken))`
     * @param underlyingToken The mainnet ERC-20 to wrap
     * @param delegate LayerZero delegate (typically the protocol owner/multisig)
     * @return adapter Address of the deployed adapter proxy
     */
    function deployAdapter(bytes32 salt, address underlyingToken, address delegate) external returns (address adapter);

    /**
     * @notice Returns the adapter deployed for an underlying token, or zero if none
     * @param underlyingToken The mainnet ERC-20
     * @return adapter The adapter proxy address (0 if not deployed)
     */
    function adapterOf(address underlyingToken) external view returns (address adapter);

    /**
     * @notice Returns the underlying token wrapped by a given adapter
     * @param adapter The adapter proxy
     * @return underlyingToken The wrapped ERC-20 address
     */
    function underlyingOf(address adapter) external view returns (address underlyingToken);

    /**
     * @notice Paginated enumeration of deployed adapter addresses
     * @param start Starting index in the deployment set
     * @param n Maximum number of entries to return
     * @return adapters Array of adapter proxy addresses
     */
    function getDeployedAdapters(uint256 start, uint256 n) external view returns (address[] memory adapters);

    /**
     * @notice Total number of adapters deployed by this factory
     * @return Number of deployed adapters
     */
    function numAdaptersDeployed() external view returns (uint256);
}
