// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { TopUpFactory } from "../src/top-up/TopUpFactory.sol";
import { EtherFiTimelock } from "../src/timelock/EtherFiTimelock.sol";
import { EtherFiDeployer } from "../src/utils/EtherFiDeployer.sol";
import { UpgradeableProxy } from "../src/utils/UpgradeableProxy.sol";
import { Utils } from "./utils/Utils.sol";

/// @title DeployRoleGatingBatch2
/// @notice Batch-2 deployments for the role re-gating rollout, on the five top-up source
///         chains (Ethereum, Arbitrum, Base, BSC, HyperEVM): the 2-day upgrade
///         EtherFiTimelock (future RoleRegistry owner), the 8h operating EtherFiTimelock
///         (future ADMIN_TIMELOCK_ROLE holder), and the audited impls of the two contracts
///         that change — RoleRegistry and TopUpFactory.
///
///         Unlike Optimism (where the registry owner is already a timelock that raises its
///         own delay), the registry owner on these chains is still the governance safe, so
///         batch 2 hands ownership to the freshly deployed 2-day timelock in its 3CP.
///
///         Deployments only — no roles are granted, no proxy is upgraded and no ownership
///         moves here. That happens in the batch-2 3CP.
///
///         Everything deploys through the permissioned EtherFiDeployer (CREATE3), so
///         addresses depend on the salt alone and land identically on every chain
///         (operating timelock salt matches the Optimism deploy → same address as OP),
///         and the script is idempotent: a re-run skips anything already deployed and only
///         re-verifies it. Timelocks require an exact runtime-bytecode match against this
///         build; impl immutables are read back and required to match the live proxy.
///
/// @dev Prerequisite: the EtherFiDeployer (0xFCD9…6f30) must have code on the chain and the
///      broadcasting account must be in its deployer registry (isDeployer) — both true on
///      all five chains as of 2026-09-14. On HyperEVM, deploys over 2M gas need big blocks
///      enabled for the broadcaster on HyperCore (evmUserModify usingBigBlocks).
///
/// Usage (Ledger) — pass --sender so simulation and broadcast agree on the account:
///   forge script scripts/DeployRoleGatingBatch2.s.sol --rpc-url <chain rpc> --ledger --sender <ledger-addr> --broadcast
contract DeployRoleGatingBatch2 is Utils {
    /// @dev Permissioned CREATE3 deployer — same address on every cash chain
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    /// @dev Same salt as the (unused) Optimism deploy so the 2-day timelock lands at the
    ///      same address on every chain (0x120F246e415Ceff6dA7a22AdA1A40ef4beD7d95d)
    bytes32 constant SALT_UPGRADE_TIMELOCK = keccak256("DeployTimelock.EtherFiUpgradeTimelock");

    /// @dev Same salt as the live Optimism operating timelock → same address on every
    ///      chain (0x9AEb8eaa982084219d1A938D8F7B5040a1d47849)
    bytes32 constant SALT_OPERATING_TIMELOCK = keccak256("DeployTimelock.EtherFiOperatingTimelock");

    uint256 constant UPGRADE_DELAY = 2 days;
    uint256 constant OPERATING_DELAY = 8 hours;

    /// @dev Cash governance multisig — RoleRegistry owner on ETH, Arbitrum, Base and BSC
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @dev On HyperEVM the RoleRegistry owner is the cash controller safe instead
    address constant HYPEREVM_CONTROLLER_SAFE = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    string outJson = "batch2";

    function run() public {
        require(
            block.chainid == 1 || block.chainid == 42161 || block.chainid == 8453 || block.chainid == 56 || block.chainid == 999,
            "DeployRoleGatingBatch2: top-up source chains only"
        );
        require(address(DEPLOYER).code.length > 0, "EtherFiDeployer not deployed on this chain: deploy it first");

        // ── 1. Resolve live addresses and cross-check the world looks as reviewed ──
        address governance = block.chainid == 999 ? HYPEREVM_CONTROLLER_SAFE : GOVERNANCE_MULTISIG;

        string memory deployments = readDeploymentFile();
        address roleRegistry = readAddr(deployments, "RoleRegistry");
        address topUpFactory = readAddr(deployments, "TopUpSourceFactory");

        // Owner here is still the governance safe (no timelock yet) — the batch-2 3CP
        // hands ownership to the 2-day timelock deployed below
        require(RoleRegistry(roleRegistry).owner() == governance, "RoleRegistry owner != governance safe");
        // The new registry impl keeps the live wiring: no data provider on top-up chains
        require(address(RoleRegistry(roleRegistry).etherFiDataProvider()) == address(0), "live registry has a data provider, wiring changed");
        require(address(UpgradeableProxy(topUpFactory).roleRegistry()) == roleRegistry, "TopUpFactory proxy: roleRegistry mismatch");

        vm.startBroadcast();
        {
            (, address broadcaster,) = vm.readCallers();
            require(DEPLOYER.isDeployer(broadcaster), "broadcaster is not in the EtherFiDeployer registry");
        }

        // ── 2. Timelocks: the 2-day upgrade timelock (future registry owner) and the 8h
        //       operating timelock (future ADMIN_TIMELOCK_ROLE holder) ──
        _deployTimelock("upgradeTimelock", SALT_UPGRADE_TIMELOCK, UPGRADE_DELAY, governance);
        _deployTimelock("operatingTimelock", SALT_OPERATING_TIMELOCK, OPERATING_DELAY, governance);

        // ── 3. Impls for the two contracts batch 2 upgrades ──
        address registryImpl = _deployRegistryImpl();
        address topUpFactoryImpl = _deploy("topUpFactoryImpl", "RoleGatingBatch2.TopUpFactory", abi.encodePacked(type(TopUpFactory).creationCode));

        vm.stopBroadcast();

        // Full bytecode verification outside the broadcast: both contracts are UUPS, whose
        // only immutable is OZ's `__self = address(this)`, so the deployed code must equal a
        // reference instance's code once each contract's own address is masked out
        _assertCodeMatchesLocalBuild(registryImpl, address(new RoleRegistry(address(0))), "registry impl bytecode != local build");
        _assertCodeMatchesLocalBuild(topUpFactoryImpl, address(new TopUpFactory()), "topUpFactory impl bytecode != local build");

        // ── 4. Record addresses ──
        vm.serializeUint(outJson, "block", block.number);
        string memory finalJson = vm.serializeString(outJson, "commit", "2aed606 (Certora-approved) + master merge");
        vm.writeJson(finalJson, string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid), "/role-gating-batch2.json"));

        console.log("=== Batch-2 deployments complete. No state changed on live contracts. ===");
    }

    function _deployTimelock(string memory jsonKey, bytes32 salt, uint256 delay, address governance) internal {
        address predicted = DEPLOYER.getDeterministicAddress(salt);

        address[] memory proposers = new address[](1);
        proposers[0] = governance;
        address[] memory executors = new address[](1);
        executors[0] = governance;
        bytes memory initCode = abi.encodePacked(type(EtherFiTimelock).creationCode, abi.encode(delay, proposers, executors, address(0)));

        if (predicted.code.length > 0) {
            console.log("  [SKIP] already deployed:", jsonKey, predicted);
        } else {
            require(DEPLOYER.deploy(salt, initCode) == predicted, "timelock: deployed != predicted");
            console.log("  [OK]", jsonKey, predicted);
        }

        // EtherFiTimelock has no immutables, so an exact runtime-bytecode match guarantees
        // the code at the address is this repo's build, whoever deployed it
        require(keccak256(predicted.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");

        (, address broadcaster,) = vm.readCallers();
        EtherFiTimelock tl = EtherFiTimelock(payable(predicted));
        require(tl.getMinDelay() == delay, "timelock: unexpected delay");
        require(tl.hasRole(tl.PROPOSER_ROLE(), governance), "governance is not proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), governance), "governance is not executor");
        require(tl.hasRole(tl.CANCELLER_ROLE(), governance), "governance is not canceller");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), predicted), "timelock is not its own admin");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), governance), "governance must not be admin");
        require(!tl.hasRole(tl.PROPOSER_ROLE(), broadcaster), "deployer must not be proposer");
        require(!tl.hasRole(tl.EXECUTOR_ROLE(), broadcaster), "deployer must not be executor");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), broadcaster), "deployer must not be admin");

        vm.serializeAddress(outJson, jsonKey, predicted);
    }

    function _deployRegistryImpl() internal returns (address impl) {
        // Top-up chains run the registry without a data provider (see the live-wiring check)
        impl = _deploy("roleRegistryImpl", "RoleGatingBatch2.RoleRegistry", abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))));
        require(address(RoleRegistry(impl).etherFiDataProvider()) == address(0), "registry impl: dataProvider mismatch");
    }

    function _assertCodeMatchesLocalBuild(address impl, address localRef, string memory err) internal view {
        bytes32 liveHash = keccak256(_maskSelf(impl.code, impl));
        bytes32 localHash = keccak256(_maskSelf(localRef.code, localRef));
        require(liveHash == localHash, err);
    }

    /// @dev Zeroes every 32-byte word equal to `self` (the UUPS `__self` immutable slots)
    ///      so two instances of the same build deployed at different addresses compare equal
    function _maskSelf(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes32 word = bytes32(uint256(uint160(self)));
        for (uint256 i = 0; i + 32 <= code.length; i++) {
            bytes32 w;
            assembly {
                w := mload(add(add(code, 32), i))
            }
            if (w == word) {
                assembly {
                    mstore(add(add(code, 32), i), 0)
                }
            }
        }
        return code;
    }

    function _deploy(string memory jsonKey, string memory saltString, bytes memory initCode) internal returns (address impl) {
        bytes32 salt = keccak256(bytes(saltString));
        impl = DEPLOYER.getDeterministicAddress(salt);
        if (impl.code.length > 0) {
            console.log("  [SKIP] already deployed:", jsonKey, impl);
        } else {
            require(DEPLOYER.deploy(salt, initCode) == impl, "impl: deployed != predicted");
            console.log("  [OK]", jsonKey, impl);
        }
        vm.serializeAddress(outJson, jsonKey, impl);
    }

    function readAddr(string memory deployments, string memory key) internal pure returns (address) {
        return stdJson.readAddress(deployments, string.concat(".addresses.", key));
    }
}
