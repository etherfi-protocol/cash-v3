// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { MidasLiquifierModule } from "../../src/modules/etherfi/MidasLiquifierModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title LiquidRwaLaunchOP3CP
 * @notice Three Safe bundles that make Liquid RWA spendable and repayable on Optimism prod, plus the
 *         LiquidUSD liquifier upgrade from the same audit (Certora Item 21). Config lives behind two
 *         timelocks with different delays, so the launch lands in three steps:
 *
 *           Step 1 (day 0): schedule both timelock batches.
 *             admin timelock (8h):    setMidasRedemptionVault(liquidRWA, vault) on the 4 dispatchers
 *             upgrade timelock (2d):  MidasLiquifier.setPair(liquidRWA -> USDC), LiquidUSD upgradeToAndCall
 *           Step 2 (>= 8h after step 1 EXECUTES): execute the admin batch, then LendGateway.setSpendAsset.
 *             Spend flips only once every dispatcher can redeem the token it will receive.
 *           Step 3 (>= 2d after step 1 EXECUTES): execute the upgrade batch, then register the Midas
 *             module as a default module and gateway driver. The module is inert until this step: with no
 *             pair set, repay and redeem revert, and it is not yet a module or driver.
 *
 * @dev Both timelock salts are non-zero and specific to this launch so the operation ids are unique;
 *      TimelockController keeps an id `isOperation` forever, so a reused salt could never be re-scheduled.
 *
 * Prerequisites: DeployLiquidRwaLaunchOP has run and recorded MidasLiquifierModule, MidasLiquifierModuleImpl
 * and LiquidUSDLiquifierModuleImpl in deployments/mainnet/10/deployments.json.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates all three steps on the fork):
 *   forge script scripts/gnosis-txs/LiquidRwaLaunchOP3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 *   (--sender: the default script sender cannot `new` on this fork, nothing is sent. --no-isolate: forge 1.8 runs each
 *   top-level script call as its own tx and rejects the Safe as a sender because it has code; the simulation pranks it.)
 */
contract LiquidRwaLaunchOP3CP is Utils, GnosisHelpers {
    using stdJson for string;

    address constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    address constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 constant UPGRADE_DELAY = 2 days;
    uint256 constant ADMIN_DELAY = 8 hours;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT_ADMIN = keccak256("LiquidRwaLaunch.dispatchers");
    bytes32 constant SALT_UPGRADE = keccak256("LiquidRwaLaunch.owner");

    address constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
    address constant LIQUID_RWA_REDEMPTION_VAULT = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    RoleRegistry roleRegistry;
    LendGateway gateway;
    EtherFiDataProvider dataProvider;
    address debtManager;
    address[4] dispatchers;
    MidasLiquifierModule midas;
    address midasImpl;
    address liquidUsdProxy;
    address liquidUsdImpl;

    address[] adminTargets;
    bytes[] adminPayloads;
    address[] upgradeTargets;
    bytes[] upgradePayloads;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();
        _buildBatches();

        string memory step1 = _writeBundle("step1-schedule", string.concat(_getGnosisHeader("10", addressToHex(SAFE)), _scheduleTx(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_ADMIN, ADMIN_DELAY, false), _scheduleTx(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE, UPGRADE_DELAY, true)));
        string memory step2 = _writeBundle("step2-spend", string.concat(_getGnosisHeader("10", addressToHex(SAFE)), _executeTx(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_ADMIN, false), _tx(address(gateway), abi.encodeCall(LendGateway.setSpendAsset, (LIQUID_RWA, true)), true)));
        address[] memory modules = new address[](1);
        modules[0] = address(midas);
        bool[] memory on = new bool[](1);
        on[0] = true;
        string memory step3 = _writeBundle("step3-repay", string.concat(_getGnosisHeader("10", addressToHex(SAFE)), _executeTx(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE, false), _tx(address(dataProvider), abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (modules, on)), false), _tx(address(gateway), abi.encodeCall(LendGateway.setDriver, (address(midas), true)), true)));

        _simulate(step1, step2, step3);
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        roleRegistry = RoleRegistry(d.readAddress(".addresses.RoleRegistry"));
        gateway = LendGateway(d.readAddress(".addresses.LendGateway"));
        dataProvider = EtherFiDataProvider(d.readAddress(".addresses.EtherFiDataProvider"));
        debtManager = d.readAddress(".addresses.DebtManager");
        dispatchers = [d.readAddress(".addresses.SettlementDispatcherRain"), d.readAddress(".addresses.SettlementDispatcherReap"), d.readAddress(".addresses.SettlementDispatcherPix"), d.readAddress(".addresses.SettlementDispatcherCardOrder")];
        midas = MidasLiquifierModule(d.readAddress(".addresses.MidasLiquifierModule"));
        midasImpl = d.readAddress(".addresses.MidasLiquifierModuleImpl");
        liquidUsdProxy = d.readAddress(".addresses.LiquidUSDLiquifierModule");
        liquidUsdImpl = d.readAddress(".addresses.LiquidUSDLiquifierModuleImpl");
    }

    function _checkPreconditions() internal {
        // Governance: owner paths go through the 2d timelock, admin paths through the 8h one, the Safe proposes on both
        require(roleRegistry.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner is not the upgrade timelock");
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _checkTimelock(ADMIN_TIMELOCK, ADMIN_DELAY);
        require(roleRegistry.hasRole(keccak256("LEND_GATEWAY_ADMIN_ROLE"), SAFE), "Safe lacks LEND_GATEWAY_ADMIN_ROLE");
        require(roleRegistry.hasRole(keccak256("DATA_PROVIDER_ADMIN_ROLE"), SAFE), "Safe lacks DATA_PROVIDER_ADMIN_ROLE");

        // State now: reserve listed, spend off, no dispatcher vault, module deployed but unconfigured
        require(gateway.isRegistered(LIQUID_RWA), "liquidRWA is not a gateway reserve");
        require(!gateway.isSpendAsset(LIQUID_RWA), "liquidRWA already a spend asset");
        for (uint256 i = 0; i < 4; i++) {
            require(SettlementDispatcherV2(payable(dispatchers[i])).getMidasRedemptionVault(LIQUID_RWA) == address(0), "dispatcher vault already set");
        }
        require(address(midas.roleRegistry()) == address(roleRegistry), "Midas proxy bound to another RoleRegistry");
        require(midas.pairs(LIQUID_RWA).debtToken == address(0), "Midas pair already set");
        require(!dataProvider.isDefaultModule(address(midas)), "Midas already a default module");
        require(!gateway.isDriver(address(midas)), "Midas already a driver");

        // The recorded implementations must be this repo's audited source, bound to the prod DebtManager and DataProvider
        require(_implOf(address(midas)) == midasImpl, "Midas proxy impl != recorded impl");
        require(_sameCodeIgnoringSelf(midasImpl, address(new MidasLiquifierModule(debtManager, address(dataProvider)))), "Midas impl bytecode != local build");
        require(_implOf(liquidUsdProxy) != liquidUsdImpl, "LiquidUSD already upgraded");
        require(_sameCodeIgnoringSelf(liquidUsdImpl, address(new LiquidUSDLiquifierOPModule(debtManager, address(dataProvider)))), "LiquidUSD impl bytecode != local build");
    }

    function _checkTimelock(address timelock, uint256 delay) internal view {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");
        require(tl.getMinDelay() == delay, "timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), SAFE), "Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Safe is not an executor");
    }

    function _buildBatches() internal {
        for (uint256 i = 0; i < 4; i++) {
            adminTargets.push(dispatchers[i]);
            adminPayloads.push(abi.encodeCall(SettlementDispatcherV2.setMidasRedemptionVault, (LIQUID_RWA, LIQUID_RWA_REDEMPTION_VAULT)));
        }
        upgradeTargets.push(address(midas));
        upgradePayloads.push(abi.encodeCall(MidasLiquifierModule.setPair, (LIQUID_RWA, USDC, LIQUID_RWA_REDEMPTION_VAULT, 0, 0)));
        upgradeTargets.push(liquidUsdProxy);
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", liquidUsdImpl, ""));

        require(!_isOperation(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_ADMIN), "admin batch already scheduled");
        require(!_isOperation(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE), "upgrade batch already scheduled");
    }

    // ── Bundle encoding ────────────────────────────────────────────────────────────

    function _scheduleTx(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt, uint256 delay, bool isLast) internal pure returns (string memory) {
        bytes memory data = abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt, delay);
        return _tx(timelock, data, isLast);
    }

    function _executeTx(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt, bool isLast) internal pure returns (string memory) {
        bytes memory data = abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt);
        return _tx(timelock, data, isLast);
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/LiquidRwaLaunchOP3CP-10-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _isOperation(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt) internal view returns (bool) {
        bytes32 id = EtherFiTimelock(payable(timelock)).hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt);
        return EtherFiTimelock(payable(timelock)).isOperation(id);
    }

    /// @dev UUPSUpgradeable bakes `address(this)` into an implementation (its `__self` immutable), so a local build
    ///      can never hash-match a deployed one. Blank each side's own address, then compare; the other immutables
    ///      (DebtManager, DataProvider, CashModule) are asserted through their getters by the deploy script.
    function _sameCodeIgnoringSelf(address deployed, address local) internal view returns (bool) {
        return keccak256(_blankSelf(deployed.code, deployed)) == keccak256(_blankSelf(local.code, local));
    }

    function _blankSelf(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes20 needle = bytes20(self);
        for (uint256 i = 0; i + 20 <= code.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20 && hit; j++) {
                hit = code[i + j] == needle[j];
            }
            if (hit) {
                for (uint256 j = 0; j < 20; j++) {
                    code[i + j] = 0;
                }
                i += 19;
            }
        }
        return code;
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // ── Fork simulation: the exact three-step lifecycle with end-state asserts ──────

    function _simulate(string memory step1, string memory step2, string memory step3) internal {
        console.log("=== Step 1: schedule both batches ===");
        executeGnosisTransactionBundle(step1);
        require(_isOperation(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_ADMIN), "admin batch not scheduled");
        require(_isOperation(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE), "upgrade batch not scheduled");
        require(!gateway.isSpendAsset(LIQUID_RWA), "spend must stay off after step 1");

        console.log("=== Warp 8h, step 2: dispatcher vaults + spend on ===");
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        executeGnosisTransactionBundle(step2);
        for (uint256 i = 0; i < 4; i++) {
            require(SettlementDispatcherV2(payable(dispatchers[i])).getMidasRedemptionVault(LIQUID_RWA) == LIQUID_RWA_REDEMPTION_VAULT, "dispatcher vault not set");
        }
        require(gateway.isSpendAsset(LIQUID_RWA), "spend not enabled");
        require(midas.pairs(LIQUID_RWA).debtToken == address(0), "pair must not be set before step 3");

        console.log("=== Warp 2d, step 3: pair, LiquidUSD upgrade, module + driver ===");
        vm.warp(block.timestamp + UPGRADE_DELAY + 1);
        executeGnosisTransactionBundle(step3);
        MidasLiquifierModule.Pair memory pair = midas.pairs(LIQUID_RWA);
        require(pair.debtToken == USDC && pair.redemptionVault == LIQUID_RWA_REDEMPTION_VAULT && pair.feeBps == 0 && pair.flatFee == 0, "pair mismatch");
        require(_implOf(liquidUsdProxy) == liquidUsdImpl, "LiquidUSD impl slot != new impl");
        require(dataProvider.isDefaultModule(address(midas)), "Midas not a default module");
        require(gateway.isDriver(address(midas)), "Midas not a driver");
        console.log("Simulation OK: spend live after step 2, repay + LiquidUSD upgrade live after step 3");
    }
}
