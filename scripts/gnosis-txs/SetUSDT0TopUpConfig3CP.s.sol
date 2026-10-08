// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { USDT0TopUpConfig } from "../utils/USDT0TopUpConfig.sol";

/**
 * @title SetUSDT0TopUpConfig3CP
 * @author ether.fi
 * @notice PROD bundle generator for the same three USD₮0 top-up rails as
 *         `scripts/top-up/SetUSDT0TopUpConfig.s.sol` (COR-1757 Arbitrum, COR-1759 Ethereum +
 *         HyperEVM). Selects the rail from `block.chainid`, same as the dev script — point
 *         `--rpc-url` at the chain you want a bundle for.
 *
 *         Step 1 (proposer Safe, 1 tx): adminTimelock.schedule(setTokenConfig, 8h)
 *         Step 2 (proposer Safe, 1 tx, >= 8h after step 1 EXECUTES): adminTimelock.execute(setTokenConfig)
 *
 *         The single call the TIMELOCK runs:
 *           TopUpFactory.setTokenConfig([token], [10], [config])
 *
 * @dev WHY THE 8h "ADMIN_TIMELOCK", NOT THE 48h ONE, NOT A DIRECT SAFE CALL.
 *
 *      An earlier version of this script targeted `roleRegistry().owner()`
 *      (`0x9106cD76E10Ac60D1dd16144243416EbD2C64434`, `getMinDelay()==172800` / 48h) as a direct
 *      Safe call, matching this ticket's own framing ("a Gnosis/3CP bundle" against
 *      `onlyRoleRegistryOwner`) and prior art (`TopUpSourceSetEURCMainnet.s.sol`). That bundle's
 *      step 1 (schedule) simulated fine, but step 2 (execute) reverted `OnlyAdminTimelock()` from
 *      inside `RoleRegistry` — a function with no match anywhere in this repo's tracked source
 *      (checked HEAD, `origin/dev`, `origin/master`).
 *
 *      Root cause, confirmed by reading `etherfi-protocol/cash-v3` PR #289 ("STAKE-1889: Re-gate
 *      RoleRegistry-owner functions + consolidate admin roles + add operating-timelock role",
 *      branch `stake-1889`, still OPEN but already deployed to prod — hence the drift from
 *      tracked source): `TopUpFactory.setTokenConfig` moved from `onlyRoleRegistryOwner` to
 *      `onlyAdminTimelock`, which checks `RoleRegistry.hasRole(ADMIN_TIMELOCK_ROLE, msg.sender)` —
 *      a DIFFERENT, newer role from plain registry ownership. Three governance tiers now exist on
 *      every mainnet chain this script touches (1, 10, 999, 42161), confirmed live via
 *      `roleHolders(bytes32)` on 2026-09-23:
 *
 *        | Tier                                    | Address                                    | Delay |
 *        |------------------------------------------|--------------------------------------------|-------|
 *        | RoleRegistry owner (2-day upgrade TL)     | 0x9106cD76E10Ac60D1dd16144243416EbD2C64434  | 48h   |
 *        | ADMIN_TIMELOCK_ROLE (operating TL) [used] | 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849  | 8h    |
 *        | ADMIN_ROLE (fast multisig)                 | per-chain Safe, see `_proposerSafe`        | none  |
 *
 *      `setTokenConfig` is a "trust change" (moves where funds bridge to) per PR #289's own
 *      classification, so it sits behind the 8h operating timelock, not the 48h upgrade one and
 *      not the fast multisig. This script schedules/executes through
 *      `0x9AEb8eaa982084219d1A938D8F7B5040a1d47849` accordingly. `_assertGovernance` checks
 *      `RoleRegistry.hasRole(ADMIN_TIMELOCK_ROLE, ADMIN_TIMELOCK)` live rather than hardcoding
 *      that this address is correct, so a further re-wiring fails loudly instead of producing a
 *      bundle that reverts at execute.
 *
 * @dev PER-CHAIN PROPOSER. The address that PROPOSES/EXECUTES on `ADMIN_TIMELOCK` is the
 *      "admin multisig" (`ADMIN_ROLE` holder), which is NOT the same Safe on every chain:
 *      Ethereum + Arbitrum use `SAFE` (0xA6cf...AAC4); HyperEVM uses a different Safe,
 *      `0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB`. Both confirmed live via
 *      `roleHolders(ADMIN_ROLE)` and `hasRole(PROPOSER_ROLE/EXECUTOR_ROLE, ...)` on the 8h
 *      timelock, 2026-09-23. `_proposerSafe()` selects the right one per `block.chainid` — using
 *      `SAFE` unconditionally would produce a HyperEVM bundle nobody can sign.
 *
 * @dev Prior art still not followed literally: `TopUpSourceSetEURCMainnet.s.sol` /
 *      `TopUpSourceSetUSDTMainnet.s.sol` call the OLD 2-array `setTokenConfig(tokens, config)`
 *      selector, which no longer exists on `TopUpFactory` (current signature takes `chainIds`
 *      too, and PR #289 changed only the modifier, not the signature). Those scripts would not
 *      compile against this repo's current `TopUpFactory` and are stale. This script instead
 *      follows the current, compiling house pattern used by `SetSpyxTopupConfigEthereum.s.sol` /
 *      `GrantStockWithdrawAdminRoleOP3CP.s.sol` (the latter's own OP-only 8h timelock is the same
 *      shape of problem this script solves for three chains, source-unlinked from `RoleRegistry`
 *      because it too pre-dates PR #289's `ADMIN_TIMELOCK_ROLE`).
 *
 * @dev SALT: `TL_SALT` is deliberately NON-ZERO and per-chain (`block.chainid` baked into the
 *      salt derivation): `TimelockController` marks an operation id `isOperation` forever once
 *      scheduled, and the same call signature (`setTokenConfig`) recurs across all three chains
 *      this script targets, so a shared salt would collide.
 *
 * @dev The OPS ORDERING NOTE from the ticket, specific to the HyperEVM leg: before running this
 *      script's HyperEVM (999) bundle, confirm the mainnet TopUpFactory's USDT balance is
 *      drained AND that in-flight LayerZero messages on the HyperEVM -> Ethereum lane (the
 *      two-hop route being replaced) are confirmed zero. Anything mid-route when
 *      `setTokenConfig` executes arrives at a recipient (the Ethereum TopUpSourceFactory) that
 *      the new one-hop-to-OP config no longer expects to receive HyperEVM USDT — the config
 *      change does not affect messages already in flight, only new bridges initiated after it
 *      lands.
 *
 * Prerequisite: `EtherFiOFTBridgeAdapter` recorded in the source chain's
 * deployments/mainnet/<chainId>/deployments.json (already true for 1/999/42161 at time of
 * writing).
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/SetUSDT0TopUpConfig3CP.s.sol --rpc-url $ARBITRUM_RPC  # COR-1757
 *   forge script scripts/gnosis-txs/SetUSDT0TopUpConfig3CP.s.sol --rpc-url $ETHEREUM_RPC  # COR-1759 Ethereum
 *   forge script scripts/gnosis-txs/SetUSDT0TopUpConfig3CP.s.sol --rpc-url $HYPEREVM_RPC  # COR-1759 HyperEVM
 */
contract SetUSDT0TopUpConfig3CP is USDT0TopUpConfig, GnosisHelpers, Test {
    using stdJson for string;

    /// @dev The 8h "operating" timelock — holds `ADMIN_TIMELOCK_ROLE` on `RoleRegistry` on every
    ///      mainnet chain this script targets (same deterministic address everywhere, confirmed
    ///      live 2026-09-23). NOT `RoleRegistry.owner()` — see contract natspec.
    address internal constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    /// @dev Live `getMinDelay()` on `ADMIN_TIMELOCK`, confirmed on chains 1/42161/999 2026-09-23.
    uint256 internal constant TIMELOCK_DELAY = 8 hours;
    bytes32 internal constant TL_PREDECESSOR = bytes32(0);

    /// @dev HyperEVM's admin multisig (`ADMIN_ROLE` holder there) — distinct from `SAFE`
    ///      (Ethereum/Arbitrum), confirmed via `roleHolders(ADMIN_ROLE)` on HyperEVM's
    ///      RoleRegistry 2026-09-23.
    address internal constant HYPEREVM_SAFE = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    RoleRegistry internal roleRegistry;
    TopUpFactory internal factory;
    EtherFiTimelock internal timelockController;
    Rail internal rail;
    address internal bridgeAdapter;
    address internal recipient;
    address internal proposer;

    function run() public {
        require(!_isDev(), "SetUSDT0TopUpConfig3CP: prod only (ENV=mainnet) - dev goes through scripts/top-up/SetUSDT0TopUpConfig.s.sol");

        _loadAndPreflight();

        TopUpFactory.TokenConfig memory config = _tokenConfig(rail, bridgeAdapter, recipient);
        bytes memory callData = abi.encodeCall(TopUpFactory.setTokenConfig, (_asArray(rail.token), _asArray(OP_CHAIN_ID), _asArray(config)));

        (string memory step1Path, string memory step2Path) = _writeBundles(callData);
        _simulateAndVerify(step1Path, step2Path, config);

        console.log("");
        console.log("Sign step 1, wait for it to EXECUTE, then wait", TIMELOCK_DELAY / 1 hours, "hours before signing step 2.");
    }

    // ── Address loading + preconditions ─────────────────────────────────────────

    /// @dev The admin multisig differs by chain (see contract natspec) — unlike `SAFE`, which is
    ///      shared by Ethereum and Arbitrum, HyperEVM uses its own.
    function _proposerSafe() internal view returns (address) {
        if (block.chainid == HYPEREVM_CHAIN_ID) return HYPEREVM_SAFE;
        return SAFE;
    }

    function _loadAndPreflight() internal {
        rail = _rail();
        _assertOftWiring(rail);
        proposer = _proposerSafe();

        string memory deployments = readTopUpSourceDeployment();
        factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        timelockController = EtherFiTimelock(payable(ADMIN_TIMELOCK));

        bridgeAdapter = _bridgeAdapter();
        recipient = _topUpDestOptimism();

        _assertGovernance();

        // Idempotence: refuse to build a bundle that would only repeat the live config.
        TopUpFactory.TokenConfig memory existing = factory.getTokenConfig(rail.token, OP_CHAIN_ID);
        if (existing.bridgeAdapter == bridgeAdapter && existing.recipientOnDestChain == recipient && existing.maxSlippageInBps == MAX_SLIPPAGE_BPS && keccak256(existing.additionalData) == keccak256(abi.encode(rail.oftAdapter, OP_EID))) {
            revert("config already matches the target - nothing to change");
        }
    }

    /// @dev Bytecode alone does not prove configuration — delay, role membership and proposer
    ///      wiring all live in storage. Every check here is read live, not assumed from natspec.
    function _assertGovernance() internal view {
        require(ADMIN_TIMELOCK.code.length > 0, "ADMIN_TIMELOCK not deployed on this chain");
        require(keccak256(ADMIN_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "ADMIN_TIMELOCK bytecode != local EtherFiTimelock build");
        require(timelockController.getMinDelay() == TIMELOCK_DELAY, "ADMIN_TIMELOCK minDelay != 8 hours - re-check TIMELOCK_DELAY before signing anything");
        require(timelockController.hasRole(timelockController.PROPOSER_ROLE(), proposer), "proposer Safe is not a timelock proposer - cannot sign step 1");
        require(timelockController.hasRole(timelockController.EXECUTOR_ROLE(), proposer) || timelockController.hasRole(timelockController.EXECUTOR_ROLE(), address(0)), "proposer Safe is not a timelock executor - cannot sign step 2");

        // The call is executed BY the timelock, so it must actually hold ADMIN_TIMELOCK_ROLE, or
        // the bundle cannot work and must not be signed. `setTokenConfig` is `onlyAdminTimelock`
        // (PR #289 / STAKE-1889), NOT `onlyRoleRegistryOwner` — see contract natspec.
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), ADMIN_TIMELOCK), "ADMIN_TIMELOCK does not hold ADMIN_TIMELOCK_ROLE - governance wiring has moved again, re-check before signing");
        require(!timelockController.isOperation(_operationId()), "this operation id is already scheduled - step 1 has already landed");
    }

    // ── Operation construction ────────────────────────────────────────────────────

    /// @dev Per-chain salt: the payload shape (`setTokenConfig` on a `TopUpFactory`) recurs
    ///      across all three chains this script targets, so `block.chainid` must be baked in or
    ///      the derived operation ids collide.
    function _tlSalt() internal view returns (bytes32) {
        return keccak256(abi.encode("COR-1757-1759.USDT0TopUp", block.chainid));
    }

    function _operationId(bytes memory callData) internal view returns (bytes32) {
        return timelockController.hashOperation(address(factory), 0, callData, TL_PREDECESSOR, _tlSalt());
    }

    /// @dev Overload used before `callData` exists yet (the idempotence pre-check needs the id
    ///      shape but not a specific payload — recomputed with the real payload in `run()`).
    function _operationId() internal view returns (bytes32) {
        bytes memory placeholder = abi.encodeCall(TopUpFactory.setTokenConfig, (_asArray(rail.token), _asArray(OP_CHAIN_ID), _asArray(_tokenConfig(rail, bridgeAdapter, recipient))));
        return _operationId(placeholder);
    }

    function _writeBundles(bytes memory callData) internal returns (string memory step1Path, string memory step2Path) {
        string memory chainId = vm.toString(block.chainid);
        bytes32 tlSalt = _tlSalt();

        string memory scheduleData = iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", address(factory), 0, callData, TL_PREDECESSOR, tlSalt, TIMELOCK_DELAY));
        string memory step1 = _getGnosisHeader(chainId, addressToHex(proposer));
        step1 = string.concat(step1, _getGnosisTransaction(addressToHex(ADMIN_TIMELOCK), scheduleData, "0", true));
        step1Path = _writeBundle(chainId, "step1-schedule", step1);

        string memory executeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", address(factory), 0, callData, TL_PREDECESSOR, tlSalt));
        string memory step2 = _getGnosisHeader(chainId, addressToHex(proposer));
        step2 = string.concat(step2, _getGnosisTransaction(addressToHex(ADMIN_TIMELOCK), executeData, "0", true));
        step2Path = _writeBundle(chainId, "step2-execute", step2);

        console.log("");
        console.log("Rail:", rail.name);
        console.log("Proposer Safe:", proposer);
        console.log("Timelock operation id:");
        console.logBytes32(_operationId(callData));
    }

    function _writeBundle(string memory chainId, string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/SetUSDT0TopUpConfig3CP-", chainId, "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory step1Path, string memory step2Path, TopUpFactory.TokenConfig memory expected) internal {
        address ownerBefore = roleRegistry.owner();
        bytes memory callData = abi.encodeCall(TopUpFactory.setTokenConfig, (_asArray(rail.token), _asArray(OP_CHAIN_ID), _asArray(expected)));
        bytes32 opId = _operationId(callData);

        console.log("");
        console.log("=== Simulating step 1 (schedule) ===");
        executeGnosisTransactionBundle(step1Path);

        require(timelockController.isOperationPending(opId), "SIM FAILED: operation not pending after schedule");
        require(!timelockController.isOperationReady(opId), "SIM FAILED: operation ready before the delay elapsed");
        TopUpFactory.TokenConfig memory beforeExecute = factory.getTokenConfig(rail.token, OP_CHAIN_ID);
        require(keccak256(abi.encode(beforeExecute)) != keccak256(abi.encode(expected)), "SIM FAILED: config already matches target after step 1 - the delay did nothing");

        console.log("=== Warping past the", TIMELOCK_DELAY / 1 hours, "hour timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        require(timelockController.isOperationReady(opId), "SIM FAILED: operation not ready after the delay");

        console.log("=== Simulating step 2 (execute) ===");
        executeGnosisTransactionBundle(step2Path);

        require(timelockController.isOperationDone(opId), "SIM FAILED: timelock operation not done");

        TopUpFactory.TokenConfig memory stored = factory.getTokenConfig(rail.token, OP_CHAIN_ID);
        assertEq(stored.bridgeAdapter, expected.bridgeAdapter, "SIM FAILED: bridgeAdapter mismatch");
        assertEq(stored.recipientOnDestChain, expected.recipientOnDestChain, "SIM FAILED: recipientOnDestChain mismatch");
        assertEq(uint256(stored.maxSlippageInBps), uint256(expected.maxSlippageInBps), "SIM FAILED: maxSlippageInBps mismatch");
        assertEq(stored.additionalData, expected.additionalData, "SIM FAILED: additionalData mismatch");

        // Collateral damage: this bundle must not touch governance.
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");

        console.log("");
        console.log("  [OK] %s -> Optimism top-up config stored and read back identical.", rail.name);
        console.log("  [OK] bridgeAdapter:", stored.bridgeAdapter);
        console.log("  [OK] recipientOnDestChain:", stored.recipientOnDestChain);
        console.log("3CP simulation passed for chainId", block.chainid);
    }
}
