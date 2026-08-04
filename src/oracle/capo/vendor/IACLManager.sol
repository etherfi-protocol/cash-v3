// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IACLManager
 * @notice The slice of Aave V3's `IACLManager` that the vendored price cap adapters actually use.
 * @dev Upstream, the adapters import the full `IACLManager` from `aave-address-book/AaveV3.sol`,
 *      which drags in the whole aave-v3-origin interface tree. The adapters only ever call
 *      `isRiskAdmin` and `isPoolAdmin` (both solely to gate `setCapParameters` / `setPriceCap`), so
 *      this file declares exactly those two and nothing else. Swapping this in for the address-book
 *      import is the ONLY edit made to the vendored files — see PROVENANCE.md.
 *
 *      The ether.fi Cash Aave V4 instance has no V3 ACL manager; `EtherFiCapoAclManager` implements
 *      this interface on top of the instance's AccessManager.
 */
interface IACLManager {
  /// @notice True if `admin` may retune risk parameters (here: the price cap parameters)
  function isRiskAdmin(address admin) external view returns (bool);

  /// @notice True if `admin` is a pool admin
  function isPoolAdmin(address admin) external view returns (bool);
}
