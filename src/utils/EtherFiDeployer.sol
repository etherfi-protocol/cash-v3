// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "solady/auth/Ownable.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

/**
 * @title EtherFiDeployer
 * @author ether.fi
 * @notice Permissioned CREATE3 deployer with a registry of authorised deployer addresses.
 */
contract EtherFiDeployer is Ownable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.EtherFiDeployer
    struct EtherFiDeployerStorage {
        /// @notice Set of addresses authorised to call `deploy`.
        EnumerableSetLib.AddressSet deployers;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiDeployer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiDeployerStorageLocation = 0x44fa8530802f2b5a89451304d13ba2a51b584728dd1a53e53ee224e3339d5f00;

    function _getEtherFiDeployerStorage() private pure returns (EtherFiDeployerStorage storage $) {
        assembly {
            $.slot := EtherFiDeployerStorageLocation
        }
    }

    /// @notice Emitted when a new deployer is added to the registry.
    /// @param deployer The newly authorised deployer address.
    event DeployerAdded(address indexed deployer);

    /// @notice Emitted when a deployer is removed from the registry.
    /// @param deployer The deployer address that was removed.
    event DeployerRemoved(address indexed deployer);

    /// @notice Emitted on a successful deterministic deploy.
    /// @param salt The CREATE3 salt that drove the address derivation.
    /// @param deployed The deployed contract address.
    /// @param by The deployer address that initiated the deploy.
    /// @param value Native value forwarded to the new contract's constructor.
    event ContractDeployed(bytes32 indexed salt, address indexed deployed, address indexed by, uint256 value);

    /// @notice Reverts when `deploy` is called by an address not in the deployer registry.
    error OnlyDeployer();

    /// @notice Reverts when `configureDeployers` is passed the zero address.
    error InvalidDeployer();

    /// @notice Reverts when the parallel arrays passed to `configureDeployers` have different lengths.
    error ArrayLengthMismatch();

    /**
     * @param _owner Address that becomes the contract owner. Can manage the deployer set
     *        after deploy via `configureDeployers`.
     * @param initialDeployers Optional initial set of authorised deployer addresses. Each
     *        will be added during construction; the zero address reverts, duplicates are
     *        silently deduped.
     */
    constructor(address _owner, address[] memory initialDeployers) {
        _initializeOwner(_owner);

        uint256 len = initialDeployers.length;
        if (len > 0) {
            bool[] memory shouldAdds = new bool[](len);
            for (uint256 i = 0; i < len; ) {
                shouldAdds[i] = true;
                unchecked { ++i; }
            }
            _configureDeployers(initialDeployers, shouldAdds);
        }
    }

    // ------------------------------------------------------------------
    // Registry admin (owner-only)
    // ------------------------------------------------------------------

    /**
     * @notice Adds and / or removes deployers in one call. Idempotent — entries that are
     *         already in their target state are silently skipped (no event re-emit).
     * @dev Owner-only. Parallel arrays: for each `i`, if `shouldAdd[i]` is true then
     *      `deployers[i]` is added (no-op if already registered); if false it's removed
     *      (no-op if absent). Lets callers re-run the same configuration safely.
     * @param deployers Deployer addresses to toggle.
     * @param shouldAdd Per-entry flag: `true` = add, `false` = remove.
     * @custom:throws ArrayLengthMismatch If the two arrays don't have the same length.
     * @custom:throws InvalidDeployer If any entry is the zero address.
     */
    function configureDeployers(address[] calldata deployers, bool[] calldata shouldAdd) external onlyOwner {
        _configureDeployers(deployers, shouldAdd);
    }

    /**
     * @dev Shared internal worker for `configureDeployers` and the constructor. Takes
     *      memory args so both paths can call it with their respective array sources.
     *      `EnumerableSetLib.add` / `remove` return false on no-op (already present /
     *      already absent); we use that to decide whether to emit, never to revert.
     */
    function _configureDeployers(address[] memory deployers, bool[] memory shouldAdd) internal {
        uint256 len = deployers.length;
        if (len != shouldAdd.length) revert ArrayLengthMismatch();

        EnumerableSetLib.AddressSet storage set = _getEtherFiDeployerStorage().deployers;
        for (uint256 i = 0; i < len; ) {
            address deployer = deployers[i];
            if (deployer == address(0)) revert InvalidDeployer();
            if (shouldAdd[i]) {
                if (set.add(deployer)) emit DeployerAdded(deployer);
            } else {
                if (set.remove(deployer)) emit DeployerRemoved(deployer);
            }
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------
    // Read surface
    // ------------------------------------------------------------------

    /// @notice Returns whether `account` is currently in the deployer registry.
    function isDeployer(address account) external view returns (bool) {
        return _getEtherFiDeployerStorage().deployers.contains(account);
    }

    /**
     * @notice Returns the full list of currently authorised deployer addresses.
     * @dev Order matches `EnumerableSetLib` iteration semantics (insertion order modified
     *      by swap-and-pop on removal).
     */
    function getDeployers() external view returns (address[] memory) {
        return _getEtherFiDeployerStorage().deployers.values();
    }

    /// @notice Returns the number of currently authorised deployer addresses.
    function deployerCount() external view returns (uint256) {
        return _getEtherFiDeployerStorage().deployers.length();
    }

    // ------------------------------------------------------------------
    // Deploy
    // ------------------------------------------------------------------

    /**
     * @notice Deploys a new contract at the deterministic address derived from `salt` and
     *         this contract's address.
     * @dev Callable by any address in the deployer registry. Forwards `msg.value` to the
     *      new contract's constructor via `CREATE3.deployDeterministic`. Reverts (with
     *      solady's CREATE3 error) if the address is already occupied.
     * @param salt CREATE3 salt — must be unique per logical contract per chain.
     * @param initCode Concatenation of creation code + ABI-encoded constructor args.
     * @return deployed The address of the freshly deployed contract.
     * @custom:throws OnlyDeployer If `msg.sender` isn't in the deployer registry.
     */
    function deploy(bytes32 salt, bytes calldata initCode) external payable returns (address deployed) {
        if (!_getEtherFiDeployerStorage().deployers.contains(msg.sender)) revert OnlyDeployer();
        deployed = CREATE3.deployDeterministic(msg.value, initCode, salt);
        emit ContractDeployed(salt, deployed, msg.sender, msg.value);
    }

    /**
     * @notice Returns the deterministic address a `deploy(salt, ...)` call would produce.
     * @param salt The CREATE3 salt.
     * @return The address (may not yet have code).
     */
    function getDeterministicAddress(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }
}
