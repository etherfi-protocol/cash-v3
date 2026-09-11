// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { LiquidUSDLiquifierOPModule } from "../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { TopUpDest } from "../src/top-up/TopUpDest.sol";
import { EtherFiDeployer } from "../src/utils/EtherFiDeployer.sol";
import { Utils } from "./utils/Utils.sol";

/// @title DeployRoleGatingBatch1
/// @notice Batch-1 impl deployments for the role re-gating rollout (STAKE-1891), Optimism
///         only: the audited impls of every contract currently gated on the RoleRegistry
///         owner — RoleRegistry, the four SettlementDispatcherV2 instances (Reap, Rain,
///         PIX, CardOrder), TopUpDest, CashbackDispatcher and LiquidUSDLiquifierOP.
///         The existing 8h timelock (current RoleRegistry owner) is raised to a 2-day
///         delay in the cutover 3CP; the NEW 8h operating timelock deploys separately
///         via DeployTimelock.s.sol.
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

    /// @dev The live 8h operating timelock — current owner of the Optimism RoleRegistry
    address constant OPERATING_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;

    string outJson = "batch1";

    struct Addrs {
        address roleRegistry;
        address dataProvider;
        address debtManager;
        address topUpDest;
        address liquifier;
        address weth;
    }

    function run() public {
        require(block.chainid == 10, "DeployRoleGatingBatch1: Optimism only");
        require(address(DEPLOYER).code.length > 0, "EtherFiDeployer not deployed on this chain");

        // ── 1. Resolve live addresses and cross-check the world looks as reviewed ──
        string memory deployments = readDeploymentFile();
        Addrs memory a = _resolveAndCheck(deployments);

        vm.startBroadcast();
        {
            (, address broadcaster,) = vm.readCallers();
            require(DEPLOYER.isDeployer(broadcaster), "broadcaster is not in the EtherFiDeployer registry");
        }

        // ── 2. Impls for every contract currently gated on the RoleRegistry owner ──
        _deployRegistryImpl(a);

        _deployDispatcherImpl(deployments, "SettlementDispatcherReap", "settlementDispatcherReapImpl", BinSponsor.Reap, a.dataProvider);
        _deployDispatcherImpl(deployments, "SettlementDispatcherRain", "settlementDispatcherRainImpl", BinSponsor.Rain, a.dataProvider);
        _deployDispatcherImpl(deployments, "SettlementDispatcherPix", "settlementDispatcherPixImpl", BinSponsor.PIX, a.dataProvider);
        _deployDispatcherImpl(deployments, "SettlementDispatcherCardOrder", "settlementDispatcherCardOrderImpl", BinSponsor.CardOrder, a.dataProvider);

        _deployTopUpDestImpl(a);
        _deployCashbackImpl(a);
        _deployLiquifierImpl(a);

        vm.stopBroadcast();

        // ── 3. Record addresses ──
        vm.serializeUint(outJson, "block", block.number);
        string memory finalJson = vm.serializeString(outJson, "commit", "2aed606 (Certora-approved) + master merge");
        vm.writeJson(finalJson, string.concat(vm.projectRoot(), "/deployments/mainnet/10/role-gating-batch1.json"));

        console.log("=== Batch-1 deployments complete. No state changed on live contracts. ===");
    }

    function _resolveAndCheck(string memory deployments) internal view returns (Addrs memory a) {
        a.roleRegistry = readAddr(deployments, "RoleRegistry");
        a.dataProvider = readAddr(deployments, "EtherFiDataProvider");
        a.debtManager = readAddr(deployments, "DebtManager");
        a.topUpDest = readAddr(deployments, "TopUpDest");
        a.liquifier = readAddr(deployments, "LiquidUSDLiquifierModule");
        a.weth = address(TopUpDest(payable(a.topUpDest)).weth());

        require(RoleRegistry(a.roleRegistry).owner() == OPERATING_TIMELOCK, "RoleRegistry owner != 8h operating timelock");
        require(address(RoleRegistry(a.roleRegistry).etherFiDataProvider()) == a.dataProvider, "dataProvider mismatch vs live registry");
        // Liquifier keeps the live proxy's debtManager wiring
        require(address(LiquidUSDLiquifierOPModule(a.liquifier).debtManager()) == a.debtManager, "liquifier proxy: debtManager mismatch");
    }

    function _deployRegistryImpl(Addrs memory a) internal {
        address impl = _deploy("roleRegistryImpl", "RoleGatingBatch1.RoleRegistry", abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(a.dataProvider)));
        require(address(RoleRegistry(impl).etherFiDataProvider()) == a.dataProvider, "registry impl: dataProvider mismatch");
    }

    function _deployTopUpDestImpl(Addrs memory a) internal {
        // TopUpDest keeps the live proxy's weth wiring
        address impl = _deploy("topUpDestImpl", "RoleGatingBatch1.TopUpDest", abi.encodePacked(type(TopUpDest).creationCode, abi.encode(a.dataProvider, a.weth)));
        require(address(TopUpDest(payable(impl)).weth()) == a.weth, "topUpDest impl: weth mismatch");
    }

    function _deployCashbackImpl(Addrs memory a) internal {
        address impl = _deploy("cashbackDispatcherImpl", "RoleGatingBatch1.CashbackDispatcher", abi.encodePacked(type(CashbackDispatcher).creationCode, abi.encode(a.dataProvider)));
        require(address(CashbackDispatcher(impl).etherFiDataProvider()) == a.dataProvider, "cashback impl: dataProvider mismatch");
    }

    function _deployLiquifierImpl(Addrs memory a) internal {
        address impl = _deploy("liquidUsdLiquifierImpl", "RoleGatingBatch1.LiquidUSDLiquifierOP", abi.encodePacked(type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(a.debtManager, a.dataProvider)));
        require(address(LiquidUSDLiquifierOPModule(impl).debtManager()) == a.debtManager, "liquifier impl: debtManager mismatch");
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
