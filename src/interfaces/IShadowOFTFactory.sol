// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IShadowOFTFactory
 * @author ether.fi
 * @notice Interface for the destination-chain (e.g. Optimism) Shadow OFT beacon factory
 * @dev Mirror of {IOFTAdapterFactory}. The same CREATE3 `salt` used on mainnet must be
 *      reused here so the iTOKEN address mirrors the mainnet adapter address.
 */
interface IShadowOFTFactory {
    /**
     * @notice Emitted when a new Shadow OFT (iTOKEN) beacon proxy is deployed
     * @param salt The CREATE3 salt used (must match the mainnet adapter salt)
     * @param shadowOFT The deployed iTOKEN proxy address
     * @param name The ERC-20 name of the iTOKEN
     * @param symbol The ERC-20 symbol of the iTOKEN
     */
    event ShadowOFTDeployed(bytes32 indexed salt, address indexed shadowOFT, string name, string symbol);

    /// @notice Thrown when the caller is not authorised to deploy
    error OnlyAdmin();
    /// @notice Thrown when a Shadow OFT already exists for the supplied salt
    error ShadowOFTAlreadyExists();
    /// @notice Thrown when the start index passed to {getDeployedShadowOFTs} is out of bounds
    error InvalidStartIndex();

    /**
     * @notice Deploys a new Shadow OFT (iTOKEN) beacon proxy
     * @dev Caller must hold the factory admin role.
     * @param salt CREATE3 salt; must match the mainnet `OFTAdapterFactory.deployAdapter` salt
     * @param name ERC-20 name of the iTOKEN (convention: "EtherFi <NAME>")
     * @param symbol ERC-20 symbol of the iTOKEN (convention: "i<SYMBOL>")
     * @param delegate LayerZero delegate (typically the protocol owner/multisig)
     * @return shadowOFT Address of the deployed iTOKEN proxy
     */
    function deployShadowOFT(bytes32 salt, string calldata name, string calldata symbol, address delegate) external returns (address shadowOFT);

    /**
     * @notice Paginated enumeration of deployed Shadow OFT addresses
     * @param start Starting index in the deployment set
     * @param n Maximum number of entries to return
     * @return shadowOFTs Array of iTOKEN proxy addresses
     */
    function getDeployedShadowOFTs(uint256 start, uint256 n) external view returns (address[] memory shadowOFTs);

    /**
     * @notice Total number of Shadow OFTs deployed by this factory
     * @return Number of deployed iTOKENs
     */
    function numShadowOFTsDeployed() external view returns (uint256);

    /**
     * @notice Returns whether `account` is an iTOKEN deployed by this factory
     * @param account Address to query
     * @return True if `account` was deployed by this factory
     */
    function isShadowOFT(address account) external view returns (bool);
}
