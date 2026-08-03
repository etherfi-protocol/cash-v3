// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../../../src/top-up/TopUpFactory.sol";
import { TimelockMigrationBase } from "./TimelockMigrationBase.s.sol";

/// @title TopUpSourceMigrationBase
/// @notice Shared STAKE-1676 migration flow for the 5 TopUpFactory source chains
///         (Ethereum, BNB, HyperEVM, Base, Arbitrum). Each chain has one re-gated proxy —
///         TopUpSourceFactory — at the same address, and the TopUpFactory impl has no
///         constructor args, so a shared CREATE3 salt yields the same impl address on all
///         5 chains. Concrete per-chain scripts only pin the chain id and RoleRegistry.
abstract contract TopUpSourceMigrationBase is TimelockMigrationBase {
    /// @dev TopUpSourceFactory proxy — same address on all 5 source chains
    address constant TOP_UP_FACTORY_PROXY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;

    /// @dev Shared salt — same TopUpFactory impl address on every source chain
    bytes32 constant SALT_TOP_UP_FACTORY_IMPL = keccak256("TimelockMigration.TopUpFactoryImpl");

    function requiredChainId() internal pure virtual returns (uint256);
    function roleRegistry() internal pure virtual returns (address);

    function run() public {
        address safe = _resolveContext(requiredChainId(), roleRegistry());
        console.log("Safe (RoleRegistry owner):", safe);

        // ── 1. Deploy the new TopUpFactory implementation (deterministic, idempotent) ──
        vm.startBroadcast();
        address[] memory impls = new address[](1);
        impls[0] = deployCreate3(type(TopUpFactory).creationCode, SALT_TOP_UP_FACTORY_IMPL);
        vm.stopBroadcast();

        address[] memory proxies = new address[](1);
        proxies[0] = TOP_UP_FACTORY_PROXY;

        // ── 2. step1 bundle: upgrade + role grant + schedule handover & canceller grant ──
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        txs = string(abi.encodePacked(txs, _upgradeTx(TOP_UP_FACTORY_PROXY, impls[0], false)));
        txs = _appendStep1GovernanceTxs(txs, roleRegistry(), safe);
        string memory step1Path = _writeBundle("step1", txs);

        // ── 3. step2 bundle: execute handover request + complete handover ──
        string memory step2Path = _writeBundle("step2", _buildStep2(roleRegistry(), safe));

        // ── 4. Simulate both bundles on this fork and assert the end state ──
        _simulateAndVerify(step1Path, step2Path, roleRegistry(), safe, proxies, impls);

        // Re-gated function stays fast at the safe after the handover
        address recoveryWallet = TopUpFactory(payable(TOP_UP_FACTORY_PROXY)).getRecoveryWallet();
        if (recoveryWallet != address(0)) {
            vm.prank(safe);
            TopUpFactory(payable(TOP_UP_FACTORY_PROXY)).setRecoveryWallet(recoveryWallet);
            console.log("  [OK] safe can still call re-gated config functions");
        }
    }
}
