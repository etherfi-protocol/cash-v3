// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { BinSponsor, ICashModule } from "../../src/interfaces/ICashModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title DeployStargateTaxiOptimism
 * @notice Deploys the Optimism taxi module and dispatcher implementations.
 *         It writes one immediate module-switch bundle and two timelock upgrade bundles.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/stargate-taxi/DeployOptimism.s.sol \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify
 */
contract DeployStargateTaxiOptimism is EtherFiDeployerHelper, GnosisHelpers, ContractCodeChecker {
    using stdJson for string;

    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant ETHERFI_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant TIMELOCK_DELAY = 8 hours;
    bytes32 internal constant PREDECESSOR = bytes32(0);
    bytes32 internal constant TIMELOCK_SALT = keccak256("StargateTaxi.Optimism.DispatcherUpgrades");

    address internal constant OLD_STARGATE_MODULE = 0xee77DEB6991f5d5CcAE5a327debA32d292E85c1c;
    address internal constant REAP_PROXY = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address internal constant RAIN_PROXY = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address internal constant PIX_PROXY = 0x95aaddD43b6edF838ec486E9f9814787212Bf42D;
    address internal constant CARD_ORDER_PROXY = 0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a;

    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant WEETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address internal constant ETHFI = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address internal constant WHYPE = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address internal constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address internal constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address internal constant USDC_STARGATE_POOL = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    string internal constant MODULE_SALT = "Prod.StargateTaxi.Optimism.StargateModule";
    string internal constant REAP_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherReapImpl";
    string internal constant RAIN_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherRainImpl";
    string internal constant PIX_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherPixImpl";
    string internal constant CARD_ORDER_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherCardOrderImpl";

    address internal constant EXPECTED_MODULE = 0x865a756d15e40D1D38595a39F29867518594182E;
    address internal constant EXPECTED_REAP_IMPL = 0x34ACb3f6D3F1B6651Ef8De20aC4d47A6eF435c7b;
    address internal constant EXPECTED_RAIN_IMPL = 0x54a1f126A105FA6ee28128c55E38aDBa7FD242DA;
    address internal constant EXPECTED_PIX_IMPL = 0xA369a66D8dC96f54B973B7FDD382F2BDfF811f21;
    address internal constant EXPECTED_CARD_ORDER_IMPL = 0x05c364474Ccf03AF0316321D8fb04225828c4A1C;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    EtherFiDataProvider internal dataProvider;
    ICashModule internal cashModule;
    RoleRegistry internal roleRegistry;
    EtherFiTimelock internal timelockController;

    address internal module;
    address internal reapImpl;
    address internal rainImpl;
    address internal pixImpl;
    address internal cardOrderImpl;

    /// @notice Deploys the contracts, writes the Safe bundles, and simulates the complete rollout.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        _loadAndCheckExistingDeployment();
        _deploy();
        _checkDeployments();

        string memory moduleBundle = _writeModuleSwitchBundle();
        (string memory scheduleBundle, string memory executeBundle) = _writeDispatcherUpgradeBundles();
        _simulate(moduleBundle, scheduleBundle, executeBundle);

        console.log("Record StargateModule in deployments/mainnet/10/deployments.json:", module);
    }

    /// @dev Loads the live registry and rejects a deployment against unexpected proxy addresses.
    function _loadAndCheckExistingDeployment() internal {
        string memory deployments = readDeploymentFile();
        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        cashModule = ICashModule(deployments.readAddress(".addresses.CashModule"));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        timelockController = EtherFiTimelock(payable(ETHERFI_TIMELOCK));

        require(deployments.readAddress(".addresses.StargateModule") == OLD_STARGATE_MODULE, "unexpected old StargateModule");
        require(deployments.readAddress(".addresses.SettlementDispatcherReap") == REAP_PROXY, "unexpected Reap proxy");
        require(deployments.readAddress(".addresses.SettlementDispatcherRain") == RAIN_PROXY, "unexpected Rain proxy");
        require(deployments.readAddress(".addresses.SettlementDispatcherPix") == PIX_PROXY, "unexpected PIX proxy");
        require(deployments.readAddress(".addresses.SettlementDispatcherCardOrder") == CARD_ORDER_PROXY, "unexpected CardOrder proxy");

        require(roleRegistry.hasRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), SAFE), "Safe lacks DATA_PROVIDER_ADMIN_ROLE");
        require(roleRegistry.hasRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), SAFE), "Safe lacks CASH_MODULE_CONTROLLER_ROLE");
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "RoleRegistry owner is not the timelock");
        require(timelockController.getMinDelay() == TIMELOCK_DELAY, "unexpected timelock delay");
        require(timelockController.hasRole(timelockController.PROPOSER_ROLE(), SAFE), "Safe is not a proposer");
        require(timelockController.hasRole(timelockController.EXECUTOR_ROLE(), SAFE) || timelockController.hasRole(timelockController.EXECUTOR_ROLE(), address(0)), "Safe is not an executor");
        _checkModuleConfig(OLD_STARGATE_MODULE);
        require(_canRequestWithdraw(OLD_STARGATE_MODULE), "old module is not an active withdrawal requester");
    }

    /// @dev Deploys all five contracts through the permissioned EtherFi CREATE3 deployer.
    function _deploy() internal {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        require(address(DEPLOYER).code.length > 0, "EtherFiDeployer is not deployed");
        require(DEPLOYER.isDeployer(broadcaster), "broadcaster is not an approved deployer");

        (address[] memory assets, StargateModule.AssetConfig[] memory configs) = _moduleConfig();
        vm.startBroadcast(privateKey);
        module = _create3(MODULE_SALT, type(StargateModule).creationCode, abi.encode(assets, configs, address(dataProvider)));
        reapImpl = _create3(REAP_IMPL_SALT, type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Reap, address(dataProvider)));
        rainImpl = _create3(RAIN_IMPL_SALT, type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Rain, address(dataProvider)));
        pixImpl = _create3(PIX_IMPL_SALT, type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, address(dataProvider)));
        cardOrderImpl = _create3(CARD_ORDER_IMPL_SALT, type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, address(dataProvider)));
        vm.stopBroadcast();
    }

    /// @dev Confirms the deterministic addresses and constructor configuration before bundle creation.
    function _checkDeployments() internal {
        require(_predictAddress(MODULE_SALT) == EXPECTED_MODULE && module == EXPECTED_MODULE, "module address mismatch");
        require(_predictAddress(REAP_IMPL_SALT) == EXPECTED_REAP_IMPL && reapImpl == EXPECTED_REAP_IMPL, "Reap impl mismatch");
        require(_predictAddress(RAIN_IMPL_SALT) == EXPECTED_RAIN_IMPL && rainImpl == EXPECTED_RAIN_IMPL, "Rain impl mismatch");
        require(_predictAddress(PIX_IMPL_SALT) == EXPECTED_PIX_IMPL && pixImpl == EXPECTED_PIX_IMPL, "PIX impl mismatch");
        require(_predictAddress(CARD_ORDER_IMPL_SALT) == EXPECTED_CARD_ORDER_IMPL && cardOrderImpl == EXPECTED_CARD_ORDER_IMPL, "CardOrder impl mismatch");

        require(address(StargateModule(payable(module)).etherFiDataProvider()) == address(dataProvider), "module data provider mismatch");
        _checkModuleConfig(module);
        (address[] memory assets, StargateModule.AssetConfig[] memory configs) = _moduleConfig();
        requireExactCodeMatch("StargateModule", module, address(new StargateModule(assets, configs, address(dataProvider))));
        _checkDispatcherImpl(reapImpl, BinSponsor.Reap);
        _checkDispatcherImpl(rainImpl, BinSponsor.Rain);
        _checkDispatcherImpl(pixImpl, BinSponsor.PIX);
        _checkDispatcherImpl(cardOrderImpl, BinSponsor.CardOrder);
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherReapImpl", reapImpl, address(new SettlementDispatcherV2(BinSponsor.Reap, address(dataProvider))));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherRainImpl", rainImpl, address(new SettlementDispatcherV2(BinSponsor.Rain, address(dataProvider))));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherPixImpl", pixImpl, address(new SettlementDispatcherV2(BinSponsor.PIX, address(dataProvider))));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherCardOrderImpl", cardOrderImpl, address(new SettlementDispatcherV2(BinSponsor.CardOrder, address(dataProvider))));
    }

    /// @dev Replaces the default module while preserving the old module's exclusive right to drain its queued withdrawals.
    function _writeModuleSwitchBundle() internal returns (string memory path) {
        address[] memory defaultModules = new address[](2);
        defaultModules[0] = module;
        defaultModules[1] = OLD_STARGATE_MODULE;
        bool[] memory defaultEnabled = new bool[](2);
        defaultEnabled[0] = true;
        defaultEnabled[1] = false;

        address[] memory requestModules = new address[](1);
        requestModules[0] = module;
        bool[] memory requestEnabled = new bool[](1);
        requestEnabled[0] = true;

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(dataProvider)), iToHex(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (defaultModules, defaultEnabled))), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(cashModule)), iToHex(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (requestModules, requestEnabled))), "0", true));

        path = "./output/StargateTaxi-Optimism-module-switch.json";
        vm.createDir("./output", true);
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    /// @dev Writes the schedule and execute bundles for the four owner-gated UUPS upgrades.
    function _writeDispatcherUpgradeBundles() internal returns (string memory schedulePath, string memory executePath) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _dispatcherUpgradeCalls();
        bytes memory scheduleData = abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, PREDECESSOR, TIMELOCK_SALT, TIMELOCK_DELAY));
        bytes memory executeData = abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, PREDECESSOR, TIMELOCK_SALT));

        string memory scheduleTxs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        scheduleTxs = string.concat(scheduleTxs, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), iToHex(scheduleData), "0", true));
        string memory executeTxs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        executeTxs = string.concat(executeTxs, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), iToHex(executeData), "0", true));

        vm.createDir("./output", true);
        schedulePath = "./output/StargateTaxi-Optimism-dispatchers-step1-schedule.json";
        executePath = "./output/StargateTaxi-Optimism-dispatchers-step2-execute.json";
        vm.writeFile(schedulePath, scheduleTxs);
        vm.writeFile(executePath, executeTxs);
        console.log("Wrote", schedulePath);
        console.log("Wrote", executePath);
    }

    /// @dev Simulates all bundles and checks the module switch and proxy implementation slots.
    function _simulate(string memory moduleBundle, string memory scheduleBundle, string memory executeBundle) internal {
        executeGnosisTransactionBundle(moduleBundle);
        require(dataProvider.isDefaultModule(module), "new module is not default");
        require(!dataProvider.isDefaultModule(OLD_STARGATE_MODULE), "old module is still default");
        require(dataProvider.isWhitelistedModule(OLD_STARGATE_MODULE), "old module must remain whitelisted until drain");
        require(_canRequestWithdraw(module), "new module cannot request withdrawals");
        require(_canRequestWithdraw(OLD_STARGATE_MODULE), "old module cannot drain queued withdrawals");

        executeGnosisTransactionBundle(scheduleBundle);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        executeGnosisTransactionBundle(executeBundle);
        require(_implementation(REAP_PROXY) == reapImpl, "Reap upgrade failed");
        require(_implementation(RAIN_PROXY) == rainImpl, "Rain upgrade failed");
        require(_implementation(PIX_PROXY) == pixImpl, "PIX upgrade failed");
        require(_implementation(CARD_ORDER_PROXY) == cardOrderImpl, "CardOrder upgrade failed");
        console.log("Stargate taxi Optimism bundle simulation passed");
    }

    /// @dev Returns every asset configuration present on the live Optimism module.
    function _moduleConfig() internal pure returns (address[] memory assets, StargateModule.AssetConfig[] memory configs) {
        assets = new address[](6);
        assets[0] = USDC;
        assets[1] = WEETH;
        assets[2] = ETHFI;
        assets[3] = WHYPE;
        assets[4] = BEHYPE;
        assets[5] = EURC;

        configs = new StargateModule.AssetConfig[](6);
        configs[0] = StargateModule.AssetConfig({ isOFT: false, pool: USDC_STARGATE_POOL });
        for (uint256 i = 1; i < assets.length; i++) {
            configs[i] = StargateModule.AssetConfig({ isOFT: true, pool: assets[i] });
        }
    }

    /// @dev Checks every audited asset against the intended live configuration.
    function _checkModuleConfig(address target) internal view {
        (address[] memory assets, StargateModule.AssetConfig[] memory expected) = _moduleConfig();
        StargateModule deployed = StargateModule(payable(target));
        for (uint256 i = 0; i < assets.length; i++) {
            StargateModule.AssetConfig memory actual = deployed.getAssetConfig(assets[i]);
            require(actual.isOFT == expected[i].isOFT && actual.pool == expected[i].pool, "module asset config mismatch");
        }
    }

    /// @dev Checks one dispatcher implementation's immutable sponsor and data provider.
    function _checkDispatcherImpl(address implementation, BinSponsor sponsor) internal view {
        SettlementDispatcherV2 dispatcher = SettlementDispatcherV2(payable(implementation));
        require(dispatcher.binSponsor() == sponsor, "dispatcher sponsor mismatch");
        require(address(dispatcher.dataProvider()) == address(dataProvider), "dispatcher data provider mismatch");
    }

    /// @dev Builds the four proxy upgrade calls used by both timelock bundles.
    function _dispatcherUpgradeCalls() internal view returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        targets = new address[](4);
        targets[0] = REAP_PROXY;
        targets[1] = RAIN_PROXY;
        targets[2] = PIX_PROXY;
        targets[3] = CARD_ORDER_PROXY;
        values = new uint256[](4);
        payloads = new bytes[](4);
        payloads[0] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (reapImpl, bytes("")));
        payloads[1] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (rainImpl, bytes("")));
        payloads[2] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (pixImpl, bytes("")));
        payloads[3] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (cardOrderImpl, bytes("")));
    }

    /// @dev Returns whether the CashModule currently accepts withdrawal requests from a module.
    function _canRequestWithdraw(address target) internal view returns (bool) {
        address[] memory allowed = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == target) return true;
        }
        return false;
    }

    /// @dev Reads a UUPS proxy's current EIP-1967 implementation address.
    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
