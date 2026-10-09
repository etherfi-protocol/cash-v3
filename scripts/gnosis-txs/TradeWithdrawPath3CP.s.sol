// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title TradeWithdrawPath3CP
 * @notice Activates the trade recipient guard and the separate trading withdraw path deployed by
 *         DeployTradeWithdrawPathImplsProd. Each Safe transaction is a single timelock call.
 *
 *         Optimism, after 3CP-724 makes the new Safes timelock operators:
 *           upgrade Safe, 2d upgrade timelock: CashModule core + setters, CashEventEmitter, Across, Enso
 *           admin Safe, 8h admin timelock:     5s withdrawal delay for Across and Enso, register the new
 *                                              OpenOcean module as a default module and gateway driver
 *         The admin batch calls `configureModuleWithdrawalDelay`, which only exists on the new setters,
 *         so its execute reverts until the upgrade batch has executed.
 *
 *         Ethereum: AAC4 on the 2d upgrade timelock upgrades Across and Enso.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates on the fork):
 *   forge script scripts/gnosis-txs/TradeWithdrawPath3CP.s.sol --rpc-url $OPTIMISM_RPC \
 *     --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 *   forge script scripts/gnosis-txs/TradeWithdrawPath3CP.s.sol --rpc-url $MAINNET_RPC \
 *     --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 */
contract TradeWithdrawPath3CP is Utils, GnosisHelpers {
    using stdJson for string;

    address constant AAC4 = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant ADMIN_SAFE = 0x47992A4E7920EE57eb3dD06131C1a086963b240B;
    address constant UPGRADE_SAFE = 0xBAf0E1af05c5ab8Bb709d13e1B6DeDd53b492588;
    address constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    address constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 constant UPGRADE_DELAY = 2 days;
    uint256 constant ADMIN_DELAY = 8 hours;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT_OP_UPGRADE = keccak256("3CP.TradeWithdrawPath.op.upgrade");
    bytes32 constant SALT_OP_ADMIN = keccak256("3CP.TradeWithdrawPath.op.admin");
    bytes32 constant SALT_ETH_UPGRADE = keccak256("3CP.TradeWithdrawPath.eth.upgrade");
    bytes32 constant SALT_724_ADMIN = keccak256("3CP.AddTimelockOperators.admin");
    bytes32 constant SALT_724_UPGRADE = keccak256("3CP.AddTimelockOperators.upgrade");

    uint64 constant TRADING_DELAY = 5;
    uint64 constant GLOBAL_DELAY = 10;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address across;
    address enso;
    address acrossImpl;
    address ensoImpl;
    address dataProvider;

    ICashModule cashModule;
    address cashEventEmitter;
    LendGateway gateway;
    address oldOpenOcean;
    address coreImpl;
    address settersImpl;
    address emitterImpl;
    address openOcean;

    address[] upgradeTargets;
    bytes[] upgradePayloads;
    address[] adminTargets;
    bytes[] adminPayloads;

    function run() public {
        require(block.chainid == 1 || block.chainid == 10, "unsupported chain");
        string memory chainId = vm.toString(block.chainid);
        string memory root = vm.projectRoot();
        string memory trading = vm.readFile(string.concat(root, "/deployments/mainnet/", chainId, "/trading-account.json"));
        string memory manifest = vm.readFile(string.concat(root, "/deployments/mainnet/", chainId, "/trade-withdraw-path.json"));
        across = trading.readAddress(".AcrossSwapModule");
        enso = trading.readAddress(".EnsoSwapModule");
        acrossImpl = manifest.readAddress(".AcrossSwapModuleImpl");
        ensoImpl = manifest.readAddress(".EnsoSwapModuleImpl");
        dataProvider = address(AcrossSwapModule(across).etherFiDataProvider());

        require(address(AcrossSwapModule(acrossImpl).etherFiDataProvider()) == dataProvider, "Across impl data provider mismatch");
        require(address(EnsoSwapModule(ensoImpl).etherFiDataProvider()) == dataProvider, "Enso impl data provider mismatch");
        require(_implOf(across) != acrossImpl && _implOf(enso) != ensoImpl, "swap modules already upgraded");

        if (block.chainid == 10) _runOptimism(manifest);
        else _runEthereum();
    }

    // ── Optimism ───────────────────────────────────────────────────────────────────

    function _runOptimism(string memory manifest) internal {
        string memory d = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
        cashModule = ICashModule(d.readAddress(".addresses.CashModule"));
        cashEventEmitter = d.readAddress(".addresses.CashEventEmitter");
        gateway = LendGateway(d.readAddress(".addresses.LendGateway"));
        oldOpenOcean = d.readAddress(".addresses.OpenOceanSwapModule");
        require(d.readAddress(".addresses.EtherFiDataProvider") == dataProvider, "data provider mismatch");
        coreImpl = manifest.readAddress(".CashModuleCoreImpl");
        settersImpl = manifest.readAddress(".CashModuleSettersImpl");
        emitterImpl = manifest.readAddress(".CashEventEmitterImpl");
        openOcean = manifest.readAddress(".OpenOceanSwapModule");

        _checkOptimismPreconditions();

        upgradeTargets.push(address(cashModule));
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", coreImpl, ""));
        upgradeTargets.push(address(cashModule));
        upgradePayloads.push(abi.encodeCall(CashModuleCore.setCashModuleSettersAddress, (settersImpl)));
        upgradeTargets.push(cashEventEmitter);
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", emitterImpl, ""));
        upgradeTargets.push(across);
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", acrossImpl, ""));
        upgradeTargets.push(enso);
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", ensoImpl, ""));

        adminTargets.push(address(cashModule));
        adminPayloads.push(abi.encodeCall(ICashModule.configureModuleWithdrawalDelay, (across, TRADING_DELAY, true)));
        adminTargets.push(address(cashModule));
        adminPayloads.push(abi.encodeCall(ICashModule.configureModuleWithdrawalDelay, (enso, TRADING_DELAY, true)));
        address[] memory modules = new address[](1);
        modules[0] = openOcean;
        bool[] memory on = new bool[](1);
        on[0] = true;
        adminTargets.push(dataProvider);
        adminPayloads.push(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (modules, on)));
        adminTargets.push(address(gateway));
        adminPayloads.push(abi.encodeCall(LendGateway.setDriver, (openOcean, true)));

        require(!_isOperation(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_OP_UPGRADE), "upgrade batch already scheduled");
        require(!_isOperation(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_OP_ADMIN), "admin batch already scheduled");

        string memory upSchedule = _writeBundle("optimism-upgrade-schedule", UPGRADE_SAFE, _scheduleTx(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_OP_UPGRADE, UPGRADE_DELAY));
        string memory upExecute = _writeBundle("optimism-upgrade-execute", UPGRADE_SAFE, _executeTx(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_OP_UPGRADE));
        string memory adSchedule = _writeBundle("optimism-admin-schedule", ADMIN_SAFE, _scheduleTx(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_OP_ADMIN, ADMIN_DELAY));
        string memory adExecute = _writeBundle("optimism-admin-execute", ADMIN_SAFE, _executeTx(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_OP_ADMIN));

        _simulateOptimism(upSchedule, upExecute, adSchedule, adExecute);
    }

    function _checkOptimismPreconditions() internal view {
        RoleRegistry registry = RoleRegistry(address(EtherFiDataProvider(dataProvider).roleRegistry()));
        require(registry.owner() == UPGRADE_TIMELOCK, "cash RoleRegistry owner is not the upgrade timelock");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _checkTimelock(ADMIN_TIMELOCK, ADMIN_DELAY);

        require(EtherFiDataProvider(dataProvider).getCashModule() == address(cashModule), "data provider cash module mismatch");
        require(_implOf(address(cashModule)) != coreImpl, "CashModule already upgraded");
        require(_implOf(cashEventEmitter) != emitterImpl, "CashEventEmitter already upgraded");
        require(address(CashModuleCore(coreImpl).etherFiDataProvider()) == dataProvider, "core impl data provider mismatch");
        require(OpenOceanSwapModule(openOcean).swapRouter() == OpenOceanSwapModule(oldOpenOcean).swapRouter(), "OpenOcean router mismatch");
        require(address(OpenOceanSwapModule(openOcean).etherFiDataProvider()) == dataProvider, "OpenOcean data provider mismatch");
        require(!EtherFiDataProvider(dataProvider).isWhitelistedModule(openOcean), "new OpenOcean already registered");
        require(!gateway.isDriver(openOcean), "new OpenOcean already a driver");
        require(gateway.isDriver(oldOpenOcean), "old OpenOcean is not a driver");

        (uint64 withdrawalDelay, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        require(withdrawalDelay == GLOBAL_DELAY && spendLimitDelay == GLOBAL_DELAY && modeDelay == GLOBAL_DELAY, "unexpected global delays");
    }

    /// @dev Finishes 3CP-724 on the fork if it has not executed yet: its scheduled grant batches make the
    ///      new Safes proposers and executors. Runs the queued batch as AAC4 once its delay has elapsed.
    function _apply724() internal {
        _execute724(ADMIN_TIMELOCK, ADMIN_SAFE, SALT_724_ADMIN);
        _execute724(UPGRADE_TIMELOCK, UPGRADE_SAFE, SALT_724_UPGRADE);
    }

    function _execute724(address timelock, address safe, bytes32 salt) internal {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        if (tl.hasRole(tl.PROPOSER_ROLE(), safe)) return;

        address[] memory targets = new address[](3);
        bytes[] memory payloads = new bytes[](3);
        bytes32[3] memory roles = [tl.PROPOSER_ROLE(), tl.EXECUTOR_ROLE(), tl.CANCELLER_ROLE()];
        for (uint256 i = 0; i < 3; i++) {
            targets[i] = timelock;
            payloads[i] = abi.encodeWithSignature("grantRole(bytes32,address)", roles[i], safe);
        }
        bytes32 id = tl.hashOperationBatch(targets, new uint256[](3), payloads, TL_PREDECESSOR, salt);
        require(tl.isOperationPending(id), "3CP-724 batch is not scheduled");
        uint256 readyAt = tl.getTimestamp(id);
        if (block.timestamp < readyAt) vm.warp(readyAt);
        vm.prank(AAC4);
        tl.executeBatch(targets, new uint256[](3), payloads, TL_PREDECESSOR, salt);
        console.log("Applied 3CP-724 grants on timelock", timelock);
    }

    function _simulateOptimism(string memory upSchedule, string memory upExecute, string memory adSchedule, string memory adExecute) internal {
        console.log("=== 3CP-724: new Safes become timelock operators ===");
        _apply724();
        _checkOperator(UPGRADE_TIMELOCK, UPGRADE_SAFE);
        _checkOperator(ADMIN_TIMELOCK, ADMIN_SAFE);

        console.log("=== Schedule both batches ===");
        executeGnosisTransactionBundle(upSchedule);
        executeGnosisTransactionBundle(adSchedule);
        require(_isOperation(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_OP_UPGRADE), "upgrade batch not scheduled");
        require(_isOperation(ADMIN_TIMELOCK, adminTargets, adminPayloads, SALT_OP_ADMIN), "admin batch not scheduled");

        console.log("=== Warp 8h: admin execute must revert before the upgrade ===");
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(ADMIN_SAFE);
        (bool executedEarly,) = ADMIN_TIMELOCK.call(abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", adminTargets, new uint256[](adminTargets.length), adminPayloads, TL_PREDECESSOR, SALT_OP_ADMIN));
        require(!executedEarly, "admin batch executed before the upgrade");

        console.log("=== Warp 2d: execute upgrade, then admin ===");
        vm.warp(block.timestamp + UPGRADE_DELAY);
        executeGnosisTransactionBundle(upExecute);
        require(_implOf(address(cashModule)) == coreImpl, "CashModule impl mismatch");
        require(CashModuleCore(address(cashModule)).getCashModuleSetters() == settersImpl, "setters pointer mismatch");
        require(_implOf(cashEventEmitter) == emitterImpl, "CashEventEmitter impl mismatch");
        require(_implOf(across) == acrossImpl, "Across impl mismatch");
        require(_implOf(enso) == ensoImpl, "Enso impl mismatch");
        require(cashModule.getWithdrawalDelayForModule(across) == GLOBAL_DELAY, "Across must use the global delay before the admin batch");

        executeGnosisTransactionBundle(adExecute);
        require(cashModule.getWithdrawalDelayForModule(across) == TRADING_DELAY, "Across delay mismatch");
        require(cashModule.getWithdrawalDelayForModule(enso) == TRADING_DELAY, "Enso delay mismatch");
        (uint64 withdrawalDelay, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        require(withdrawalDelay == GLOBAL_DELAY && spendLimitDelay == GLOBAL_DELAY && modeDelay == GLOBAL_DELAY, "global delays changed");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(openOcean), "new OpenOcean not default");
        require(gateway.isDriver(openOcean), "new OpenOcean not a driver");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(oldOpenOcean) && gateway.isDriver(oldOpenOcean), "old OpenOcean changed");
        require(address(AcrossSwapModule(across).cashModule()) == address(cashModule), "Across cash module binding mismatch");
        require(address(EnsoSwapModule(enso).cashModule()) == address(cashModule), "Enso cash module binding mismatch");
        address[] memory withdrawModules = cashModule.getWhitelistedModulesCanRequestWithdraw();
        require(_contains(withdrawModules, across) && _contains(withdrawModules, enso), "swap modules cannot request withdrawals");
        console.log("Simulation OK: Optimism upgraded, 5s trading delay set, new OpenOcean registered");
    }

    function _checkOperator(address timelock, address safe) internal view {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe) && tl.hasRole(tl.EXECUTOR_ROLE(), safe), "Safe is not a timelock operator");
    }

    // ── Ethereum ───────────────────────────────────────────────────────────────────

    function _runEthereum() internal {
        RoleRegistry registry = RoleRegistry(address(AcrossSwapModule(across).roleRegistry()));
        require(registry.owner() == UPGRADE_TIMELOCK, "trading RoleRegistry owner is not the upgrade timelock");
        require(address(EnsoSwapModule(enso).roleRegistry()) == address(registry), "swap modules use different registries");
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        EtherFiTimelock tl = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
        require(tl.hasRole(tl.PROPOSER_ROLE(), AAC4) && tl.hasRole(tl.EXECUTOR_ROLE(), AAC4), "AAC4 is not an upgrade timelock operator");

        upgradeTargets.push(across);
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", acrossImpl, ""));
        upgradeTargets.push(enso);
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", ensoImpl, ""));
        require(!_isOperation(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_ETH_UPGRADE), "upgrade batch already scheduled");

        string memory schedule = _writeBundle("ethereum-upgrade-schedule", AAC4, _scheduleTx(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_ETH_UPGRADE, UPGRADE_DELAY));
        string memory execute = _writeBundle("ethereum-upgrade-execute", AAC4, _executeTx(UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_ETH_UPGRADE));

        console.log("=== Schedule, warp 2d, execute ===");
        executeGnosisTransactionBundle(schedule);
        vm.warp(block.timestamp + UPGRADE_DELAY + 1);
        executeGnosisTransactionBundle(execute);
        require(_implOf(across) == acrossImpl, "Across impl mismatch");
        require(_implOf(enso) == ensoImpl, "Enso impl mismatch");
        require(address(AcrossSwapModule(across).etherFiDataProvider()) == dataProvider, "Across data provider binding mismatch");
        require(address(EnsoSwapModule(enso).etherFiDataProvider()) == dataProvider, "Enso data provider binding mismatch");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(across) && EtherFiDataProvider(dataProvider).isDefaultModule(enso), "swap modules not default");
        console.log("Simulation OK: Ethereum Across and Enso upgraded");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────

    function _checkTimelock(address timelock, uint256 delay) internal view {
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");
        require(EtherFiTimelock(payable(timelock)).getMinDelay() == delay, "timelock minDelay mismatch");
    }

    function _scheduleTx(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt, uint256 delay) internal pure returns (string memory) {
        bytes memory data = abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt, delay);
        return _getGnosisTransaction(addressToHex(timelock), iToHex(data), "0", true);
    }

    function _executeTx(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt) internal pure returns (string memory) {
        bytes memory data = abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt);
        return _getGnosisTransaction(addressToHex(timelock), iToHex(data), "0", true);
    }

    function _writeBundle(string memory name, address safe, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/TradeWithdrawPath3CP-", name, ".json");
        vm.writeFile(path, string.concat(_getGnosisHeader(vm.toString(block.chainid), addressToHex(safe)), txs));
        console.log("Wrote", path);
    }

    function _isOperation(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt) internal view returns (bool) {
        bytes32 id = EtherFiTimelock(payable(timelock)).hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt);
        return EtherFiTimelock(payable(timelock)).isOperation(id);
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _contains(address[] memory values, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == needle) return true;
        }
        return false;
    }
}
