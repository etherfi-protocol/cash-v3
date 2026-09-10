// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { LiquidUSDLiquifierOPModule } from "../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { EtherFiTimelock } from "../src/timelock/EtherFiTimelock.sol";
import { TopUpDest } from "../src/top-up/TopUpDest.sol";
import { EtherFiDeployer } from "../src/utils/EtherFiDeployer.sol";
import { Utils } from "./utils/Utils.sol";

/// @title DeployRoleGatingBatch1
/// @notice Batch-1 deployments for the role re-gating rollout (STAKE-1891), Optimism only:
///         the 2-day upgrade EtherFiTimelock plus the audited impls of every contract
///         currently gated on the RoleRegistry owner — RoleRegistry, the four
///         SettlementDispatcherV2 instances (Reap, Rain, PIX, CardOrder), TopUpDest,
///         CashbackDispatcher and LiquidUSDLiquifierOP.
///
///         Deployments only — no roles are granted, no proxy is upgraded and no ownership
///         moves here. That happens in the batch-1 3CP (STAKE-1925).
///
///         Everything deploys through the permissioned EtherFiDeployer (CREATE3), so the
///         script is idempotent: a re-run skips anything already deployed and only
///         re-verifies it. Each impl's immutables are read back and required to match the
///         wiring of the live proxy it will replace.
///
/// Usage (Ledger) — pass --sender so simulation and broadcast agree on the account:
///   forge script scripts/DeployRoleGatingBatch1.s.sol --rpc-url $OPTIMISM_RPC --ledger --sender <ledger-addr> --broadcast
contract DeployRoleGatingBatch1 is Utils {
    /// @dev Permissioned CREATE3 deployer — same address on every cash chain
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    /// @dev Must stay identical across chains so the later multichain rollout lands the
    ///      upgrade timelock at the same address everywhere
    bytes32 constant SALT_UPGRADE_TIMELOCK = keccak256("DeployTimelock.EtherFiUpgradeTimelock");

    uint256 constant TIMELOCK_DELAY = 2 days;

    /// @dev Cash governance multisig (3/6) — sole proposer/executor/canceller of the new timelock
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @dev The live 8h operating timelock — current owner of the Optimism RoleRegistry
    address constant OPERATING_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;

    string outJson = "batch1";

    function run() public {
        require(block.chainid == 10, "DeployRoleGatingBatch1: Optimism only");
        require(address(DEPLOYER).code.length > 0, "EtherFiDeployer not deployed on this chain");

        // ── 1. Resolve live addresses and cross-check the world looks as reviewed ──
        string memory deployments = readDeploymentFile();
        address roleRegistry = readAddr(deployments, "RoleRegistry");
        address dataProvider = readAddr(deployments, "EtherFiDataProvider");
        address debtManager = readAddr(deployments, "DebtManager");
        address topUpDest = readAddr(deployments, "TopUpDest");
        address cashbackDispatcher = readAddr(deployments, "CashbackDispatcher");
        address liquifier = readAddr(deployments, "LiquidUSDLiquifierModule");

        require(RoleRegistry(roleRegistry).owner() == OPERATING_TIMELOCK, "RoleRegistry owner != 8h operating timelock");
        require(address(RoleRegistry(roleRegistry).etherFiDataProvider()) == dataProvider, "dataProvider mismatch vs live registry");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(DEPLOYER.isDeployer(broadcaster), "broadcaster is not in the EtherFiDeployer registry");

        // ── 2. The 2-day upgrade timelock ──
        address timelock = _deployUpgradeTimelock();

        // ── 3. Impls for every contract currently gated on the RoleRegistry owner ──
        address roleRegistryImpl = _deploy("roleRegistryImpl", "RoleGatingBatch1.RoleRegistry", abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(dataProvider)));
        require(address(RoleRegistry(roleRegistryImpl).etherFiDataProvider()) == dataProvider, "registry impl: dataProvider mismatch");

        _deployDispatcherImpl(deployments, "SettlementDispatcherReap", "settlementDispatcherReapImpl", BinSponsor.Reap, dataProvider);
        _deployDispatcherImpl(deployments, "SettlementDispatcherRain", "settlementDispatcherRainImpl", BinSponsor.Rain, dataProvider);
        _deployDispatcherImpl(deployments, "SettlementDispatcherPix", "settlementDispatcherPixImpl", BinSponsor.PIX, dataProvider);
        _deployDispatcherImpl(deployments, "SettlementDispatcherCardOrder", "settlementDispatcherCardOrderImpl", BinSponsor.CardOrder, dataProvider);

        // TopUpDest keeps the live proxy's weth wiring
        address weth = address(TopUpDest(payable(topUpDest)).weth());
        address topUpDestImpl = _deploy("topUpDestImpl", "RoleGatingBatch1.TopUpDest", abi.encodePacked(type(TopUpDest).creationCode, abi.encode(dataProvider, weth)));
        require(address(TopUpDest(payable(topUpDestImpl)).weth()) == weth, "topUpDest impl: weth mismatch");

        address cashbackImpl = _deploy("cashbackDispatcherImpl", "RoleGatingBatch1.CashbackDispatcher", abi.encodePacked(type(CashbackDispatcher).creationCode, abi.encode(dataProvider)));
        require(address(CashbackDispatcher(cashbackImpl).etherFiDataProvider()) == dataProvider, "cashback impl: dataProvider mismatch");
        require(cashbackDispatcher != address(0), "cashback proxy missing");

        // Liquifier keeps the live proxy's debtManager wiring
        require(address(LiquidUSDLiquifierOPModule(liquifier).debtManager()) == debtManager, "liquifier proxy: debtManager mismatch");
        address liquifierImpl = _deploy("liquidUsdLiquifierImpl", "RoleGatingBatch1.LiquidUSDLiquifierOP", abi.encodePacked(type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(debtManager, dataProvider)));
        require(address(LiquidUSDLiquifierOPModule(liquifierImpl).debtManager()) == debtManager, "liquifier impl: debtManager mismatch");

        vm.stopBroadcast();

        // ── 4. Record addresses ──
        vm.serializeAddress(outJson, "upgradeTimelock", timelock);
        vm.serializeUint(outJson, "block", block.number);
        string memory finalJson = vm.serializeString(outJson, "commit", "2aed606 (Certora-approved) + master merge");
        vm.writeJson(finalJson, string.concat(vm.projectRoot(), "/deployments/mainnet/10/role-gating-batch1.json"));

        console.log("=== Batch-1 deployments complete. No state changed on live contracts. ===");
    }

    function _deployUpgradeTimelock() internal returns (address) {
        address[] memory proposers = new address[](1);
        proposers[0] = GOVERNANCE_MULTISIG;
        address[] memory executors = new address[](1);
        executors[0] = GOVERNANCE_MULTISIG;

        bytes memory initCode = abi.encodePacked(type(EtherFiTimelock).creationCode, abi.encode(TIMELOCK_DELAY, proposers, executors, address(0)));

        address predicted = DEPLOYER.getDeterministicAddress(SALT_UPGRADE_TIMELOCK);
        if (predicted.code.length > 0) {
            console.log("  [SKIP] upgrade timelock already deployed:", predicted);
        } else {
            require(DEPLOYER.deploy(SALT_UPGRADE_TIMELOCK, initCode) == predicted, "timelock: deployed != predicted");
            console.log("  [OK] upgrade timelock:", predicted);
        }

        // EtherFiTimelock has no immutables, so the runtime code must match this build exactly
        require(keccak256(predicted.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");

        EtherFiTimelock tl = EtherFiTimelock(payable(predicted));
        require(tl.getMinDelay() == TIMELOCK_DELAY, "delay != 2 days");
        require(tl.hasRole(tl.PROPOSER_ROLE(), GOVERNANCE_MULTISIG), "multisig is not proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), GOVERNANCE_MULTISIG), "multisig is not executor");
        require(tl.hasRole(tl.CANCELLER_ROLE(), GOVERNANCE_MULTISIG), "multisig is not canceller");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), predicted), "timelock is not its own admin");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), GOVERNANCE_MULTISIG), "multisig must not be admin");
        return predicted;
    }

    function _deployDispatcherImpl(string memory deployments, string memory proxyKey, string memory jsonKey, BinSponsor binSponsor, address dataProvider) internal {
        // The impl must carry the same immutables as the live proxy it will replace
        address proxy = readAddr(deployments, proxyKey);
        require(SettlementDispatcherV2(payable(proxy)).binSponsor() == binSponsor, "dispatcher proxy: binSponsor mismatch");

        bytes memory initCode = abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(binSponsor, dataProvider));
        address impl = _deploy(jsonKey, string.concat("RoleGatingBatch1.", proxyKey), initCode);

        require(SettlementDispatcherV2(payable(impl)).binSponsor() == binSponsor, "dispatcher impl: binSponsor mismatch");
        require(address(SettlementDispatcherV2(payable(impl)).dataProvider()) == dataProvider, "dispatcher impl: dataProvider mismatch");
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
