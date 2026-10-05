// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/// @title Role verification
/// @notice For every RoleRegistry we govern (the cash and the trading registry on each chain) the
///         owner and, for every role listed in deployments/mainnet/<chain>/roles.json, the exact
///         holder set must match the file: same length, every expected holder present. Wallet
///         addresses live only in that file. The two governance timelocks get the same treatment:
///         proposer, executor, canceller and admin must be exactly the configured wallets, checked
///         with hasRole against every address the file mentions (the OpenZeppelin timelock roles
///         are not enumerable), plus the minimum delay.
///
///         Roles that are not listed are not checked: the registry cannot list which role ids
///         exist, and the per-safe admin roles are too numerous to enumerate.
///
/// Usage:
///   ENV=mainnet forge test --match-contract 'VerifyOPRoles|VerifyEthereumRoles' -vv
abstract contract VerifyRolesBase is Test {
    string internal roles;
    string internal cashDeployments;
    string internal tradingDeployments;

    function _fork(string memory rpcEnv, string memory fallbackRpc) internal {
        // CI sets unset secrets to "", which must also fall back
        string memory rpc = vm.envOr(rpcEnv, string(""));
        vm.createSelectFork(bytes(rpc).length > 0 ? rpc : fallbackRpc);
        _load();
    }

    function _load() internal {
        string memory dir = string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid));
        roles = vm.readFile(string.concat(dir, "/roles.json"));
        cashDeployments = vm.readFile(string.concat(dir, "/deployments.json"));
        tradingDeployments = vm.readFile(string.concat(dir, "/trading-account.json"));
    }

    function _cashRegistry() internal view returns (RoleRegistry) {
        return RoleRegistry(stdJson.readAddress(cashDeployments, ".addresses.RoleRegistry"));
    }

    function _tradingRegistry() internal view returns (RoleRegistry) {
        return RoleRegistry(stdJson.readAddress(tradingDeployments, ".RoleRegistry"));
    }

    // ---- Registries ----

    function test_cashRegistry_owner() public view {
        assertEq(_cashRegistry().owner(), stdJson.readAddress(roles, ".cash.owner"), "cash RoleRegistry owner");
    }

    function test_tradingRegistry_owner() public view {
        assertEq(_tradingRegistry().owner(), stdJson.readAddress(roles, ".trading.owner"), "trading RoleRegistry owner");
    }

    function test_cashRegistry_roleHolders() public view {
        _assertRoleHolders(".cash.roles", _cashRegistry());
    }

    function test_tradingRegistry_roleHolders() public view {
        _assertRoleHolders(".trading.roles", _tradingRegistry());
    }

    // ---- Timelocks ----

    function test_operatingTimelock() public view {
        _assertTimelock(".governance.operatingTimelock");
    }

    function test_upgradeTimelock() public view {
        _assertTimelock(".governance.upgradeTimelock");
    }

    // ---- Helpers ----

    function _assertRoleHolders(string memory path, RoleRegistry registry) internal view {
        string[] memory names = vm.parseJsonKeys(roles, path);
        string memory problems;
        for (uint256 i = 0; i < names.length; ++i) {
            address[] memory expected = vm.parseJsonAddressArray(roles, string.concat(path, ".", names[i]));
            address[] memory actual = registry.roleHolders(keccak256(bytes(names[i])));
            if (expected.length != actual.length) {
                problems = string.concat(problems, "\n  ", names[i], ": ", vm.toString(actual.length), " holders on-chain, ", vm.toString(expected.length), " expected");
            }
            for (uint256 j = 0; j < expected.length; ++j) {
                if (!_contains(actual, expected[j])) {
                    problems = string.concat(problems, "\n  ", names[i], ": missing ", vm.toString(expected[j]));
                }
            }
            for (uint256 j = 0; j < actual.length; ++j) {
                if (!_contains(expected, actual[j])) {
                    problems = string.concat(problems, "\n  ", names[i], ": unexpected ", vm.toString(actual[j]));
                }
            }
        }
        assertEq(bytes(problems).length, 0, string.concat("role holder mismatch:", problems));
    }

    function _assertTimelock(string memory path) internal view {
        EtherFiTimelock timelock = EtherFiTimelock(payable(stdJson.readAddress(roles, string.concat(path, ".address"))));
        assertEq(timelock.getMinDelay(), stdJson.readUint(roles, string.concat(path, ".minDelay")), "timelock minDelay");

        address[] memory candidates = _candidates();
        string memory problems;
        (string[4] memory keys, bytes32[4] memory ids) = _timelockRoles(timelock);
        for (uint256 k = 0; k < keys.length; ++k) {
            address[] memory expected = vm.parseJsonAddressArray(roles, string.concat(path, ".", keys[k]));
            for (uint256 c = 0; c < candidates.length; ++c) {
                bool want = _contains(expected, candidates[c]);
                if (timelock.hasRole(ids[k], candidates[c]) != want) {
                    problems = string.concat(problems, "\n  ", keys[k], ": ", vm.toString(candidates[c]), want ? " should hold it" : " must not hold it");
                }
            }
        }
        assertEq(bytes(problems).length, 0, string.concat("timelock role mismatch:", problems));
    }

    function _timelockRoles(EtherFiTimelock t) internal view returns (string[4] memory keys, bytes32[4] memory ids) {
        keys = ["admins", "proposers", "executors", "cancellers"];
        ids = [t.DEFAULT_ADMIN_ROLE(), t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE()];
    }

    /// @dev Every address the roles file names: the governance wallets and every role holder
    function _candidates() internal view returns (address[] memory all) {
        all = new address[](512);
        uint256 n;
        n = _push(all, n, stdJson.readAddress(roles, ".governance.safe"));
        n = _push(all, n, stdJson.readAddress(roles, ".governance.operatingTimelock.address"));
        n = _push(all, n, stdJson.readAddress(roles, ".governance.upgradeTimelock.address"));
        string[2] memory sections = [".cash.roles", ".trading.roles"];
        for (uint256 s = 0; s < sections.length; ++s) {
            string[] memory names = vm.parseJsonKeys(roles, sections[s]);
            for (uint256 i = 0; i < names.length; ++i) {
                address[] memory holders = vm.parseJsonAddressArray(roles, string.concat(sections[s], ".", names[i]));
                for (uint256 j = 0; j < holders.length; ++j) n = _push(all, n, holders[j]);
            }
        }
        assembly { mstore(all, n) }
    }

    function _push(address[] memory list, uint256 n, address a) private pure returns (uint256) {
        for (uint256 i = 0; i < n; ++i) {
            if (list[i] == a) return n;
        }
        list[n] = a;
        return n + 1;
    }

    function _contains(address[] memory list, address a) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}

/// @notice Optimism: cash and trading registries
contract VerifyOPRoles is VerifyRolesBase {
    function setUp() public {
        _fork("OPTIMISM_RPC", "https://mainnet.optimism.io");
    }
}

/// @notice Ethereum: cash and trading registries
contract VerifyEthereumRoles is VerifyRolesBase {
    function setUp() public {
        _fork("MAINNET_RPC", "https://ethereum-rpc.publicnode.com");
    }
}
