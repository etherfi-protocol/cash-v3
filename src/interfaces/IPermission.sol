// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum Role {
    Owner,
    Admin
}

interface IPermission {
    function hasPermission(address user, bytes32 operation) external view returns (bool);
    function hasPermission(Role role, bytes32 operation) external view returns (bool);
    function updatePermission(Role role, bytes32 operation, bool set) external;
}
