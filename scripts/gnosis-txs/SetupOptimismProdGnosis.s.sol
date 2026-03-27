// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { ICashbackDispatcher } from "../../src/interfaces/ICashbackDispatcher.sol";
import { IPriceProvider } from "../../src/interfaces/IPriceProvider.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title SetupOptimismProdGnosis
/// @notice Generates a Gnosis Safe batch transaction for OP Mainnet prod setup.
///         Handles upgrading placeholders (RoleRegistry, SafeFactory) to real impls
///         and all owner-gated configuration (roles, withdraw tokens, debt manager).
///
/// Prerequisites: Run SetupOptimismProd.s.sol first to deploy all implementations + new proxies.
///
/// Usage:
///   forge script scripts/gnosis-txs/SetupOptimismProdGnosis.s.sol --rpc-url <OP_RPC> --broadcast
///   Then import output/SetupOptimismProdGnosis.json into the Gnosis Safe Transaction Builder.
contract SetupOptimismProdGnosis is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ── OP Mainnet addresses ──
    address constant etherFiWallet1 = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;
    address constant etherFiWallet2 = 0xB42833d6edd1241474D33ea99906fD4CBE893730;
    address constant etherFiWallet3 = 0x8D5AAc5d3d5cda4c404fA7ee31B0822B648Bb150;

    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant weETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;

    uint80 constant ltv = 50e18;
    uint80 constant liquidationThreshold = 80e18;
    uint96 constant liquidationBonus = 1e18;
    uint64 constant borrowApyPerSecond = 1;

    bytes32 constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");
    bytes32 constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");
    bytes32 constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 constant ETHERFI_SAFE_FACTORY_ADMIN_ROLE = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");

    // ── Impl salts (same as SetupOptimismProd) ──
    bytes32 constant SALT_ROLE_REGISTRY_IMPL  = 0x32e997ba554122714b8ab01335f36a045850032102a6a6946442eaecac753c3a;
    bytes32 constant SALT_SAFE_FACTORY_IMPL   = 0x89a0cb186faf1ec3240a4a2bdefe0124bd4fac7547ef1d07ad0d1f1a9f30cafe;
    bytes32 constant SALT_SAFE_IMPL           = 0xff29656f33cc018695c4dadfbd883155f1ef30d667ca50827a9b9c56a50fe803;
    bytes32 constant SALT_DEBT_MANAGER_CORE_IMPL = 0xd7d8accf3671d756a509daca0abd0356c4079376519f8b6e1796646b98b5f9bc;
    bytes32 constant SALT_DEBT_MANAGER_ADMIN_IMPL = 0xc3a0307fe194705a7248e1e199e6a1d405af038d07b82c61a736ad23635bfc9b;

    // Addresses read from deployment file
    address roleRegistry;
    address dataProvider;
    address safeFactory;
    address cashModule;
    address debtManager;
    address priceProvider;
    address cashbackDispatcher;
    address cashEventEmitter;
    address settlementDispatcherReap;
    address settlementDispatcherRain;
    address topUpDest;
    address hook;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        safeFactory = stdJson.readAddress(deployments, ".addresses.EtherFiSafeFactory");
        cashModule = stdJson.readAddress(deployments, ".addresses.CashModule");
        debtManager = stdJson.readAddress(deployments, ".addresses.DebtManager");
        priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        cashbackDispatcher = stdJson.readAddress(deployments, ".addresses.CashbackDispatcher");
        cashEventEmitter = stdJson.readAddress(deployments, ".addresses.CashEventEmitter");
        settlementDispatcherReap = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap");
        settlementDispatcherRain = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain");
        topUpDest = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        hook = stdJson.readAddress(deployments, ".addresses.EtherFiHook");

        // Compute deterministic impl addresses (deployed by SetupOptimismProd via CREATE3)
        address roleRegistryImpl = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_IMPL, NICKS_FACTORY);
        address safeFactoryImpl = CREATE3.predictDeterministicAddress(SALT_SAFE_FACTORY_IMPL, NICKS_FACTORY);
        address safeImpl = CREATE3.predictDeterministicAddress(SALT_SAFE_IMPL, NICKS_FACTORY);
        address debtManagerCoreImpl = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_CORE_IMPL, NICKS_FACTORY);
        address debtManagerAdminImpl = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_ADMIN_IMPL, NICKS_FACTORY);

        require(roleRegistryImpl.code.length > 0, "RoleRegistry impl not deployed — run SetupOptimismProd first");
        require(safeFactoryImpl.code.length > 0, "SafeFactory impl not deployed — run SetupOptimismProd first");
        require(safeImpl.code.length > 0, "EtherFiSafe impl not deployed — run SetupOptimismProd first");

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // ── 1. Upgrade RoleRegistry placeholder to real impl ──
        txs = _addTx(txs, roleRegistry, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (roleRegistryImpl, "")), false);

        // ── 2. Upgrade SafeFactory from EtherFiPlaceholder to real impl + reinitialize (creates beacon) ──
        txs = _addTx(txs, safeFactory, abi.encodeCall(
            UUPSUpgradeable.upgradeToAndCall,
            (safeFactoryImpl, abi.encodeCall(EtherFiSafeFactory.reinitialize, (safeImpl)))
        ), false);

        // ── 3. Upgrade DebtManager from initializer impl to core impl ──
        txs = _addTx(txs, debtManager, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (debtManagerCoreImpl, "")), false);

        // ── 4. Set DebtManager admin impl ──
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.setAdminImpl, (debtManagerAdminImpl)), false);

        // ── 5. Grant roles ──
        txs = _grantRoles(txs);

        // ── 6. Configure withdraw tokens ──
        txs = _configureWithdrawTokens(txs);

        // ── 7. Configure DebtManager (collateral + borrow tokens) ──
        txs = _configureDebtManager(txs);

        // ── 8. Revoke deployer-only roles (last tx) ──
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.revokeRole, (DEBT_MANAGER_ADMIN_ROLE, cashControllerSafe)), true);

        vm.createDir("./output", true);
        string memory path = "./output/SetupOptimismProdGnosis.json";
        vm.writeFile(path, txs);

        // Simulate execution on fork
        executeGnosisTransactionBundle(path);
    }

    function _grantRoles(string memory txs) internal view returns (string memory) {
        // Admin roles for the Safe itself
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (keccak256("PAUSER"), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (keccak256("UNPAUSER"), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (EtherFiDataProvider(dataProvider).DATA_PROVIDER_ADMIN_ROLE(), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (CASH_MODULE_CONTROLLER_ROLE, cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (IPriceProvider(priceProvider).PRICE_PROVIDER_ADMIN_ROLE(), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ICashbackDispatcher(cashbackDispatcher).CASHBACK_DISPATCHER_ADMIN_ROLE(), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (DEBT_MANAGER_ADMIN_ROLE, cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (SettlementDispatcher(payable(settlementDispatcherReap)).SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (SettlementDispatcher(payable(settlementDispatcherRain)).SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), cashControllerSafe)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TopUpDest(topUpDest).TOP_UP_DEPOSITOR_ROLE(), cashControllerSafe)), false);

        // EtherFi wallet roles
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHER_FI_WALLET_ROLE, etherFiWallet1)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherFiWallet1)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHER_FI_WALLET_ROLE, etherFiWallet2)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherFiWallet2)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHER_FI_WALLET_ROLE, etherFiWallet3)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherFiWallet3)), false);

        return txs;
    }

    function _configureWithdrawTokens(string memory txs) internal view returns (string memory) {
        // Grant controller role to Safe temporarily
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (CASH_MODULE_CONTROLLER_ROLE, cashControllerSafe)), false);

        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = weETH;
        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        txs = _addTx(txs, cashModule, abi.encodeCall(ICashModule.configureWithdrawAssets, (tokens, shouldWhitelist)), false);

        return txs;
    }

    function _configureDebtManager(string memory txs) internal view returns (string memory) {
        IDebtManager.CollateralTokenConfig memory usdcCollateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        });
        IDebtManager.CollateralTokenConfig memory nonStableCollateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus
        });

        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportCollateralToken, (usdc, usdcCollateralConfig)), false);
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportCollateralToken, (weETH, nonStableCollateralConfig)), false);

        uint128 minShares = uint128(10 * 10 ** IERC20Metadata(usdc).decimals());
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportBorrowToken, (usdc, borrowApyPerSecond, minShares)), false);

        return txs;
    }

    function _addTx(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast)));
    }
}
