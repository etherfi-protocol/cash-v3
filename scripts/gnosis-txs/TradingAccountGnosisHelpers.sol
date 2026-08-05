// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/// @notice Shared Safe-bundle encoding helpers for trading-account configuration scripts.
abstract contract TradingAccountGnosisHelpers is GnosisHelpers {
    function _append(string memory txs, address to, bytes memory data) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", false));
    }

    function _appendRole(string memory txs, address registry, bytes32 role, address account) internal pure returns (string memory) {
        return _append(txs, registry, abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account));
    }
}
