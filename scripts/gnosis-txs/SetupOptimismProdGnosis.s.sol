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
import { ICashModule, BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { ICashbackDispatcher } from "../../src/interfaces/ICashbackDispatcher.sol";
import { IPriceProvider } from "../../src/interfaces/IPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
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

    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant wbtc = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    address constant usdt = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant weth = 0x4200000000000000000000000000000000000006;
    address constant weeth = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant op = 0x4200000000000000000000000000000000000042;

    address constant weEthEthOracle = 0xb4479d436DDa5c1A79bD88D282725615202406E3;

    address constant settlementBridger = 0x23ddE38BA34e378D28c667bC26b44310c7CA0997;
    address constant topUpDepositor = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    address constant topupRole1 = 0xf96f8E03615f7b71e0401238D28bb08CceECBae7;
    address constant topupRole2 = 0xB82C61E4A4b4E5524376BC54013a154b2e55C5c8;
    address constant topupRole3 = 0xC73019F991dCBCc899d6B76000FdcCc99a208235;
    address constant topupRole4 = 0x93D540Dd6893bF9eA8ECD57fce32cB49b2D1B510;
    address constant topupRole5 = 0x29ebBC872CE1AF08508A65053b725Beadba43C48;
    address constant topupRole6 = 0x957a670ecE294dDf71c6A9C030432Db013082fd1;
    address constant topupRole7 = 0xFb5e703DAe21C594246f0311AE0361D1dFe250b1;
    address constant topupRole8 = 0xab00819212917dA43A81b696877Cc0BcA798b613;
    address constant topupRole9 = 0x5609BB231ec547C727D65eb6811CCd0C731339De;
    address constant topupRole10 = 0xcf1369d6CdD148AF5Af04F4002dee9A00c7F8Ae9;

    // USDC
    uint80 constant ltv_usdc = 90e18;
    uint80 constant liquidationThreshold_usdc = 95e18;
    uint96 constant liquidationBonus_usdc = 1e18;
    uint64 constant borrowApyPerSecond_usdc = 126839167935;
    
    // WETH
    uint80 constant ltv_weth = 55e18;
    uint80 constant liquidationThreshold_weth = 75e18;
    uint96 constant liquidationBonus_weth = 3.5e18;
    
    // WEETH
    uint80 constant ltv_weeth = 55e18;
    uint80 constant liquidationThreshold_weeth = 75e18;
    uint96 constant liquidationBonus_weeth = 3.5e18;

    // USDT
    uint80 constant ltv_usdt = 90e18;
    uint80 constant liquidationThreshold_usdt = 95e18;
    uint96 constant liquidationBonus_usdt = 1e18;

    bytes32 constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");
    bytes32 constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");
    bytes32 constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 constant ETHERFI_SAFE_FACTORY_ADMIN_ROLE = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");
    bytes32 constant SETTLEMENT_DISPATCHER_BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");
    bytes32 constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    // ── Impl salts (same as SetupOptimismProd) ──
    bytes32 constant SALT_SAFE_FACTORY_IMPL       = 0x89a0cb186faf1ec3240a4a2bdefe0124bd4fac7547ef1d07ad0d1f1a9f30cafe;
    bytes32 constant SALT_SAFE_IMPL               = 0xff29656f33cc018695c4dadfbd883155f1ef30d667ca50827a9b9c56a50fe803;
    bytes32 constant SALT_DEBT_MANAGER_CORE_IMPL  = 0xd7d8accf3671d756a509daca0abd0356c4079376519f8b6e1796646b98b5f9bc;
    bytes32 constant SALT_DEBT_MANAGER_ADMIN_IMPL = 0xc3a0307fe194705a7248e1e199e6a1d405af038d07b82c61a736ad23635bfc9b;
    bytes32 constant SALT_ROLE_REGISTRY_IMPL      = 0x1206639152b566c622b4f941f56c06cf7ccb447bc9326c21c2b41c8d27b8ac74;

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
    address settlementDispatcherPix;
    address settlementDispatcherCardOrder;
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
        settlementDispatcherPix = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix");
        settlementDispatcherCardOrder = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder");
        topUpDest = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        hook = stdJson.readAddress(deployments, ".addresses.EtherFiHook");

        // Compute deterministic impl addresses (deployed by SetupOptimismProd via CREATE3)
        address safeFactoryImpl = CREATE3.predictDeterministicAddress(SALT_SAFE_FACTORY_IMPL, NICKS_FACTORY);
        address safeImpl = CREATE3.predictDeterministicAddress(SALT_SAFE_IMPL, NICKS_FACTORY);
        address debtManagerCoreImpl = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_CORE_IMPL, NICKS_FACTORY);
        address debtManagerAdminImpl = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_ADMIN_IMPL, NICKS_FACTORY);
        address roleRegistryImpl = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_IMPL, NICKS_FACTORY);

        require(safeFactoryImpl.code.length > 0, "SafeFactory impl not deployed - run SetupOptimismProd first");
        require(safeImpl.code.length > 0, "EtherFiSafe impl not deployed - run SetupOptimismProd first");
        require(roleRegistryImpl.code.length > 0, "RoleRegistry impl not deployed - run SetupOptimismProd first");
        require(debtManagerCoreImpl.code.length > 0, "DebtManagerCore impl not deployed - run SetupOptimismProd first");
        require(debtManagerAdminImpl.code.length > 0, "DebtManagerAdmin impl not deployed - run SetupOptimismProd first");

        require(safeFactoryImpl == 0xAE143062e65EDBEBfc4EdED8a31092e3FdB496B8, "SafeFactory impl address mismatch");
        require(safeImpl == 0xb8436D6fbF080f3c79cF0aB89b5745de4ab3376a, "EtherFiSafe impl address mismatch");
        require(roleRegistryImpl == 0xBbdfD3a5f661698f44276c8Af600B76AE9A506dC, "RoleRegistry impl address mismatch");
        require(debtManagerCoreImpl == 0x0392347936B84Fd2d9De67F178f1D8e0bFc14a19, "DebtManagerCore impl address mismatch");
        require(debtManagerAdminImpl == 0x8E87938C7FdF1d4728D87639e15E425A98a2d94F, "DebtManagerAdmin impl address mismatch");

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

        // ── 7. Set PriceProvider config for corrected weETH address ──
        txs = _configurePriceProviderWeETH(txs);

        // ── 8. Configure DebtManager (collateral + borrow tokens) ──
        txs = _configureDebtManager(txs);

        // ── 9. Set PIX and CardOrder settlement dispatchers on CashModule ──
        txs = _addTx(txs, cashModule, abi.encodeCall(CashModuleSetters.setSettlementDispatcher, (BinSponsor.PIX, settlementDispatcherPix)), false);
        txs = _addTx(txs, cashModule, abi.encodeCall(CashModuleSetters.setSettlementDispatcher, (BinSponsor.CardOrder, settlementDispatcherCardOrder)), false);

        // ── 10. Pause DebtManager ──
        txs = _addTx(txs, debtManager, abi.encodeCall(UpgradeableProxy.pause, ()), true);

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
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TopUpDest(topUpDest).TOP_UP_DEPOSITOR_ROLE(), cashControllerSafe)), false);

        // EtherFi wallet roles
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHER_FI_WALLET_ROLE, etherFiWallet1)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherFiWallet1)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHER_FI_WALLET_ROLE, etherFiWallet2)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherFiWallet2)), false);
        
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (SETTLEMENT_DISPATCHER_BRIDGER_ROLE, settlementBridger)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (SETTLEMENT_DISPATCHER_BRIDGER_ROLE, cashControllerSafe)), false);

        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_DEPOSITOR_ROLE, topUpDepositor)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_DEPOSITOR_ROLE, cashControllerSafe)), false);

        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole1)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole2)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole3)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole4)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole5)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole6)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole7)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole8)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole9)), false);
        txs = _addTx(txs, roleRegistry, abi.encodeCall(IRoleRegistry.grantRole, (TOP_UP_ROLE, topupRole10)), false);

        return txs;
    }

    function _configureWithdrawTokens(string memory txs) internal view returns (string memory) {
        address[] memory tokens = new address[](4);
        tokens[0] = usdc;
        tokens[1] = weth;
        tokens[2] = weeth;
        tokens[3] = usdt;
        bool[] memory shouldWhitelist = new bool[](4);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;
        shouldWhitelist[2] = true;
        shouldWhitelist[3] = true;

        txs = _addTx(txs, cashModule, abi.encodeCall(ICashModule.configureWithdrawAssets, (tokens, shouldWhitelist)), false);

        return txs;
    }

    function _configureDebtManager(string memory txs) internal view returns (string memory) {
        IDebtManager.CollateralTokenConfig memory usdcAndUsdtCollateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: ltv_usdc,
            liquidationThreshold: liquidationThreshold_usdc,
            liquidationBonus: liquidationBonus_usdc
        });
        IDebtManager.CollateralTokenConfig memory weETHAndWethCollateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: ltv_weeth,
            liquidationThreshold: liquidationThreshold_weeth,
            liquidationBonus: liquidationBonus_weeth
        });

        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportCollateralToken, (usdc, usdcAndUsdtCollateralConfig)), false);
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportCollateralToken, (usdt, usdcAndUsdtCollateralConfig)), false);
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportCollateralToken, (weeth, weETHAndWethCollateralConfig)), false);
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportCollateralToken, (weth, weETHAndWethCollateralConfig)), false);

        uint128 minShares = uint128(10 * 10 ** IERC20Metadata(usdc).decimals());
        txs = _addTx(txs, debtManager, abi.encodeCall(IDebtManager.supportBorrowToken, (usdc, borrowApyPerSecond_usdc, minShares)), false);

        return txs;
    }

    function _configurePriceProviderWeETH(string memory txs) internal view returns (string memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = weeth;

        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: weEthEthOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(weEthEthOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: true,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        txs = _addTx(txs, priceProvider, abi.encodeCall(PriceProvider.setTokenConfig, (tokens, configs)), false);
        return txs;
    }

    function _addTx(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast)));
    }
}
