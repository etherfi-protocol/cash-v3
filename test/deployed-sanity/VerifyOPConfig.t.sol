// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils, ChainConfig } from "../utils/Utils.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";

/// @title OP Mainnet Config Verification
/// @notice Reads expected config from config.json, resolves token names via fixtures.json
///         and contract names via deployments.json, then verifies against live on-chain state.
///
/// Usage:
///   TEST_CHAIN=10 forge test --match-contract VerifyOPConfig -vv
contract VerifyOPConfig is Utils {

    RoleRegistry roleRegistry;
    EtherFiDataProvider dataProvider;
    IDebtManager debtManager;
    ICashModule cashModule;
    CashbackDispatcher cashbackDispatcher;
    PriceProvider priceProvider;
    TopUpDest topUpDest;

    string config;
    string deployments;
    string fixtures;
    ChainConfig cc;

    function setUp() public {
        string memory rpc = _tryEnv("OPTIMISM_RPC", "https://mainnet.optimism.io");
        vm.createSelectFork(rpc);

        cc = getChainConfig(vm.toString(block.chainid));

        deployments = readDeploymentFile();
        string memory configFile = string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid), "/config.json");
        config = vm.readFile(configFile);
        string memory fixturesFile = string.concat(vm.projectRoot(), "/deployments/mainnet/fixtures/fixtures.json");
        fixtures = vm.readFile(fixturesFile);

        roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));
        dataProvider = EtherFiDataProvider(stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider"));
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        cashbackDispatcher = CashbackDispatcher(stdJson.readAddress(deployments, ".addresses.CashbackDispatcher"));
        priceProvider = PriceProvider(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        topUpDest = TopUpDest(payable(stdJson.readAddress(deployments, ".addresses.TopUpDest")));
    }

    // ---- Role Registry Owner ----

    function test_config_roleRegistryOwner() public view {
        address expected = stdJson.readAddress(config, ".roleRegistry.owner");
        assertEq(roleRegistry.owner(), expected, "RoleRegistry owner mismatch");
    }

    // ---- Roles ----

    function test_config_roles_pauser() public view { _verifyRole("PAUSER"); }
    function test_config_roles_unpauser() public view { _verifyRole("UNPAUSER"); }
    function test_config_roles_dataProviderAdmin() public view { _verifyRole("DATA_PROVIDER_ADMIN_ROLE"); }
    function test_config_roles_cashModuleController() public view { _verifyRole("CASH_MODULE_CONTROLLER_ROLE"); }
    function test_config_roles_priceProviderAdmin() public view { _verifyRole("PRICE_PROVIDER_ADMIN_ROLE"); }
    function test_config_roles_cashbackDispatcherAdmin() public view { _verifyRole("CASHBACK_DISPATCHER_ADMIN_ROLE"); }
    function test_config_roles_debtManagerAdmin() public view { _verifyRole("DEBT_MANAGER_ADMIN_ROLE"); }
    function test_config_roles_liquidModuleAdmin() public view { _verifyRole("ETHERFI_LIQUID_MODULE_ADMIN"); }
    function test_config_roles_stargateModuleAdmin() public view { _verifyRole("STARGATE_MODULE_ADMIN_ROLE"); }
    function test_config_roles_etherFiWallet() public view { _verifyRole("ETHER_FI_WALLET_ROLE"); }
    function test_config_roles_safeFactoryAdmin() public view { _verifyRole("ETHERFI_SAFE_FACTORY_ADMIN_ROLE"); }
    function test_config_roles_settlementBridger() public view { _verifyRole("SETTLEMENT_DISPATCHER_BRIDGER_ROLE"); }
    function test_config_roles_topUpDepositor() public view { _verifyRole("DEPOSITOR_ROLE"); }
    function test_config_roles_topUpRole() public view { _verifyRole("TOP_UP_ROLE"); }

    // ---- Data Provider ----

    function test_config_dataProvider_defaultModules() public view {
        string[] memory moduleNames = stdJson.readStringArray(config, ".dataProvider.defaultModules");
        for (uint256 i = 0; i < moduleNames.length; i++) {
            address moduleAddr = stdJson.readAddress(deployments, string.concat(".addresses.", moduleNames[i]));
            assertTrue(dataProvider.isDefaultModule(moduleAddr), string.concat("Not default module: ", moduleNames[i]));
        }
    }

    function test_config_dataProvider_signers() public view {
        assertEq(dataProvider.getEtherFiRecoverySigner(), stdJson.readAddress(config, ".dataProvider.etherFiRecoverySigner"), "etherFiRecoverySigner mismatch");
        assertEq(dataProvider.getThirdPartyRecoverySigner(), stdJson.readAddress(config, ".dataProvider.thirdPartyRecoverySigner"), "thirdPartyRecoverySigner mismatch");
    }

    function test_config_dataProvider_refundWallet() public view {
        assertEq(dataProvider.getRefundWallet(), stdJson.readAddress(config, ".dataProvider.refundWallet"), "refundWallet mismatch");
    }

    // ---- Debt Manager: Collateral Tokens ----

    function test_config_debtManager_collateral_usdc() public view { _verifyCollateral("usdc"); }
    function test_config_debtManager_collateral_usdt() public view { _verifyCollateral("usdt"); }
    function test_config_debtManager_collateral_weETH() public view { _verifyCollateral("weETH"); }
    function test_config_debtManager_collateral_weth() public view { _verifyCollateral("weth"); }
    function test_config_debtManager_collateral_fraxusd() public view { _verifyCollateral("fraxusd"); }
    function test_config_debtManager_collateral_liquidEth() public view { _verifyCollateral("liquidEth"); }
    function test_config_debtManager_collateral_liquidBtc() public view { _verifyCollateral("liquidBtc"); }
    function test_config_debtManager_collateral_liquidUsd() public view { _verifyCollateral("liquidUsd"); }
    function test_config_debtManager_collateral_ebtc() public view { _verifyCollateral("ebtc"); }
    function test_config_debtManager_collateral_eUSD() public view { _verifyCollateral("eUSD"); }
    function test_config_debtManager_collateral_eurc() public view { _verifyCollateral("eurc"); }
    function test_config_debtManager_collateral_ethfi() public view { _verifyCollateral("ethfi"); }
    function test_config_debtManager_collateral_sethfi() public view { _verifyCollateral("sethfi"); }
    function test_config_debtManager_collateral_wHYPE() public view { _verifyCollateral("wHYPE"); }
    function test_config_debtManager_collateral_beHYPE() public view { _verifyCollateral("beHYPE"); }
    function test_config_debtManager_collateral_liquidReserve() public view { _verifyCollateral("liquidReserve"); }

    // ---- Debt Manager: Borrow Tokens ----

    function test_config_debtManager_borrowTokens() public view {
        string[] memory names = stdJson.readStringArray(config, ".debtManager.borrowTokens");
        for (uint256 i = 0; i < names.length; i++) {
            address token = _resolveToken(names[i]);
            assertTrue(debtManager.isBorrowToken(token), string.concat("Not borrow token: ", names[i]));
        }
    }

    // ---- Cash Module ----

    function test_config_cashModule_withdrawAssets() public view {
        string[] memory names = stdJson.readStringArray(config, ".cashModule.withdrawAssets");
        address[] memory actual = cashModule.getWhitelistedWithdrawAssets();

        for (uint256 i = 0; i < names.length; i++) {
            address token = _resolveToken(names[i]);
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (actual[j] == token) { found = true; break; }
            }
            assertTrue(found, string.concat("Withdraw asset missing: ", names[i]));
        }
    }

    function test_config_cashModule_modulesCanRequestWithdraw() public view {
        string[] memory names = stdJson.readStringArray(config, ".cashModule.modulesCanRequestWithdraw");
        address[] memory actual = cashModule.getWhitelistedModulesCanRequestWithdraw();

        for (uint256 i = 0; i < names.length; i++) {
            address moduleAddr = stdJson.readAddress(deployments, string.concat(".addresses.", names[i]));
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (actual[j] == moduleAddr) { found = true; break; }
            }
            assertTrue(found, string.concat("Module cannot request withdraw: ", names[i]));
        }
    }

    // ---- Cashback Dispatcher ----

    function test_config_cashbackDispatcher_tokens() public view {
        string[] memory names = stdJson.readStringArray(config, ".cashbackDispatcher.cashbackTokens");
        for (uint256 i = 0; i < names.length; i++) {
            address token = _resolveToken(names[i]);
            assertTrue(cashbackDispatcher.isCashbackToken(token), string.concat("Not cashback token: ", names[i]));
        }
    }

    // ---- Price Provider ----

    function test_config_priceProvider_allTokensHavePrice() public view {
        string[] memory names = stdJson.readStringArray(config, ".priceProvider.tokensWithPrice");
        for (uint256 i = 0; i < names.length; i++) {
            address token = _resolveToken(names[i]);
            uint256 p = priceProvider.price(token);
            assertTrue(p > 0, string.concat("Zero price for: ", names[i]));
        }
    }

    function test_config_priceProvider_oracleAddresses() public view {
        string[] memory names = stdJson.readStringArray(config, ".priceProvider.tokensWithPrice");
        for (uint256 i = 0; i < names.length; i++) {
            string memory oracleKey = string.concat(".priceProvider.oracles.", names[i], ".oracle");
            if (!vm.keyExistsJson(config, oracleKey)) continue;

            address expectedOracle = stdJson.readAddress(config, oracleKey);
            address token = _resolveToken(names[i]);
            PriceProvider.Config memory cfg = priceProvider.tokenConfig(token);
            assertEq(cfg.oracle, expectedOracle, string.concat("Oracle mismatch for: ", names[i]));
        }
    }

    // ---- Stargate Module ----

    function test_config_stargateModule_usdcPool() public view {
        StargateModule sm = StargateModule(payable(stdJson.readAddress(deployments, ".addresses.StargateModule")));
        address expectedPool = stdJson.readAddress(config, ".stargateModule.stargatePool.usdc");
        StargateModule.AssetConfig memory cfg = sm.getAssetConfig(_resolveToken("usdc"));
        assertFalse(cfg.isOFT, "USDC should not be OFT");
        assertEq(cfg.pool, expectedPool, "USDC stargate pool mismatch");
    }

    function test_config_stargateModule_oftAssets() public view {
        StargateModule sm = StargateModule(payable(stdJson.readAddress(deployments, ".addresses.StargateModule")));
        string[] memory names = stdJson.readStringArray(config, ".stargateModule.oft");
        for (uint256 i = 0; i < names.length; i++) {
            address token = _resolveToken(names[i]);
            StargateModule.AssetConfig memory cfg = sm.getAssetConfig(token);
            assertTrue(cfg.isOFT, string.concat("Not OFT: ", names[i]));
            assertEq(cfg.pool, token, string.concat("OFT pool mismatch: ", names[i]));
        }
    }

    // ---- Settlement Dispatchers ----

    function test_config_settlementDispatchers_exist() public view {
        assertTrue(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap").code.length > 0, "Reap has no code");
        assertTrue(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain").code.length > 0, "Rain has no code");
        assertTrue(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix").code.length > 0, "Pix has no code");
        assertTrue(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder").code.length > 0, "CardOrder has no code");
    }

    function test_config_settlementDispatchers_fraxConfig() public view {
        address expectedFraxUsd = stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.fraxUsd");
        address expectedCustodian = stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.custodian");
        address expectedRemoteHop = stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.remoteHop");

        _verifyFraxConfig("Reap", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap"),
            expectedFraxUsd, expectedCustodian, expectedRemoteHop,
            stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.deposits.Reap"));

        _verifyFraxConfig("Rain", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain"),
            expectedFraxUsd, expectedCustodian, expectedRemoteHop,
            stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.deposits.Rain"));

        _verifyFraxConfig("Pix", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix"),
            expectedFraxUsd, expectedCustodian, expectedRemoteHop,
            stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.deposits.Pix"));

        _verifyFraxConfig("CardOrder", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder"),
            expectedFraxUsd, expectedCustodian, expectedRemoteHop,
            stdJson.readAddress(config, ".settlementDispatchers.fraxConfig.deposits.CardOrder"));
    }

    function test_config_settlementDispatchers_liquidUsdBoringQueue() public view {
        address expectedQueue = stdJson.readAddress(config, ".settlementDispatchers.liquidUsdBoringQueue");
        address liquidUsdAddr = _resolveToken("liquidUsd");

        _verifyLiquidQueue("Reap", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap"), liquidUsdAddr, expectedQueue);
        _verifyLiquidQueue("Rain", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain"), liquidUsdAddr, expectedQueue);
        _verifyLiquidQueue("Pix", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix"), liquidUsdAddr, expectedQueue);
        _verifyLiquidQueue("CardOrder", stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder"), liquidUsdAddr, expectedQueue);
    }

    function test_config_settlementDispatchers_settlementRecipients() public view {
        address expectedRecipient = stdJson.readAddress(config, ".settlementDispatchers.settlementRecipient");
        address usdcAddr = _resolveToken("usdc");
        address usdtAddr = _resolveToken("usdt");

        SettlementDispatcherV2 reap = SettlementDispatcherV2(payable(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap")));
        SettlementDispatcherV2 rain = SettlementDispatcherV2(payable(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain")));

        assertEq(reap.getSettlementRecipient(usdcAddr), expectedRecipient, "Reap USDC recipient mismatch");
        assertEq(reap.getSettlementRecipient(usdtAddr), expectedRecipient, "Reap USDT recipient mismatch");
        assertEq(rain.getSettlementRecipient(usdcAddr), expectedRecipient, "Rain USDC recipient mismatch");
        assertEq(rain.getSettlementRecipient(usdtAddr), expectedRecipient, "Rain USDT recipient mismatch");
    }

    function test_config_settlementDispatchers_cardOrderRefundWallet() public view {
        address expected = stdJson.readAddress(config, ".settlementDispatchers.cardOrderRefundWallet");
        SettlementDispatcherV2 cardOrder = SettlementDispatcherV2(payable(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder")));
        assertEq(cardOrder.getRefundWallet(), expected, "CardOrder refund wallet mismatch");
    }

    function test_config_settlementDispatchers_pixUsdtRecipient() public view {
        address expected = stdJson.readAddress(config, ".settlementDispatchers.pixUsdtRecipient");
        address usdtAddr = _resolveToken("usdt");
        SettlementDispatcherV2 pix = SettlementDispatcherV2(payable(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix")));
        assertEq(pix.getSettlementRecipient(usdtAddr), expected, "Pix USDT recipient mismatch");
    }

    function test_config_settlementDispatchers_pixCCTP() public view {
        SettlementDispatcherV2 pix = SettlementDispatcherV2(payable(stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix")));

        address expectedMessenger = stdJson.readAddress(config, ".settlementDispatchers.pixCCTP.tokenMessenger");
        uint32 expectedDomain = uint32(stdJson.readUint(config, ".settlementDispatchers.pixCCTP.destDomainBase"));
        uint256 expectedMaxFee = stdJson.readUint(config, ".settlementDispatchers.pixCCTP.maxFee");
        uint32 expectedMinFinality = uint32(stdJson.readUint(config, ".settlementDispatchers.pixCCTP.minFinality"));
        address expectedRecipient = stdJson.readAddress(config, ".settlementDispatchers.pixCCTP.recipientBase");

        (address messenger_, uint32 domain_, uint256 maxFee_, uint32 minFinality_) = pix.getCCTPConfig();
        assertEq(messenger_, expectedMessenger, "PIX CCTP messenger mismatch");
        assertEq(domain_, expectedDomain, "PIX CCTP domain mismatch");
        assertEq(maxFee_, expectedMaxFee, "PIX CCTP maxFee mismatch");
        assertEq(minFinality_, expectedMinFinality, "PIX CCTP minFinality mismatch");

        address usdcAddr = _resolveToken("usdc");
        SettlementDispatcherV2.DestinationData memory dest = pix.destinationData(usdcAddr);
        assertTrue(dest.useCCTP, "PIX USDC not set to CCTP");
        assertEq(dest.destRecipient, expectedRecipient, "PIX USDC CCTP recipient mismatch");
    }

    // ---- Liquid Module Boring Queues ----

    function test_config_liquidModule_boringQueues() public view {
        EtherFiLiquidModule lm = EtherFiLiquidModule(stdJson.readAddress(deployments, ".addresses.EtherFiLiquidModule"));
        assertNotEq(lm.liquidWithdrawQueue(cc.liquidEth), address(0), "liquidEth boring queue not set");
        assertNotEq(lm.liquidWithdrawQueue(cc.liquidBtc), address(0), "liquidBtc boring queue not set");
        assertNotEq(lm.liquidWithdrawQueue(cc.liquidUsd), address(0), "liquidUsd boring queue not set");
        assertNotEq(lm.liquidWithdrawQueue(cc.ebtc), address(0), "ebtc boring queue not set");
    }

    function test_config_liquidModuleWithReferrer_boringQueue() public view {
        EtherFiLiquidModuleWithReferrer lmr = EtherFiLiquidModuleWithReferrer(stdJson.readAddress(deployments, ".addresses.EtherFiLiquidModuleWithReferrer"));
        assertNotEq(lmr.liquidWithdrawQueue(cc.sethfi), address(0), "sETHFI boring queue not set");
    }

    // ---- Helpers ----

    function _verifyRole(string memory roleName) internal view {
        bytes32 role = keccak256(abi.encodePacked(roleName));
        address[] memory expected = stdJson.readAddressArray(config, string.concat(".roles.", roleName));
        for (uint256 i = 0; i < expected.length; i++) {
            assertTrue(roleRegistry.hasRole(role, expected[i]), string.concat(roleName, " missing for: ", vm.toString(expected[i])));
        }
    }

    function _verifyFraxConfig(string memory name, address proxy, address expectedFraxUsd, address expectedCustodian, address expectedRemoteHop, address expectedDeposit) internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        (address fraxUsd_, address custodian_, address remoteHop_, address deposit_) = sd.getFraxConfig();
        assertEq(fraxUsd_, expectedFraxUsd, string.concat(name, " fraxUsd mismatch"));
        assertEq(custodian_, expectedCustodian, string.concat(name, " custodian mismatch"));
        assertEq(remoteHop_, expectedRemoteHop, string.concat(name, " remoteHop mismatch"));
        assertEq(deposit_, expectedDeposit, string.concat(name, " frax deposit mismatch"));
    }

    function _verifyLiquidQueue(string memory name, address proxy, address liquidUsdAddr, address expectedQueue) internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        assertEq(sd.getLiquidAssetWithdrawQueue(liquidUsdAddr), expectedQueue, string.concat(name, " liquid queue mismatch"));
    }

    function _verifyCollateral(string memory tokenName) internal view {
        address token = _resolveToken(tokenName);
        string memory base = string.concat(".debtManager.collateralTokens.", tokenName);

        assertTrue(debtManager.isCollateralToken(token), string.concat("Not collateral: ", tokenName));

        IDebtManager.CollateralTokenConfig memory actual = debtManager.collateralTokenConfig(token);

        // bps * 1e16 = on-chain e18 value (e.g. 9000 bps * 1e16 = 90e18)
        uint256 expectedLtv = stdJson.readUint(config, string.concat(base, ".ltvBps")) * 1e16;
        uint256 expectedLiqThreshold = stdJson.readUint(config, string.concat(base, ".liqThresholdBps")) * 1e16;
        uint256 expectedLiqBonus = stdJson.readUint(config, string.concat(base, ".liqBonusBps")) * 1e16;

        assertEq(uint256(actual.ltv), expectedLtv, string.concat("LTV mismatch for ", tokenName));
        assertEq(uint256(actual.liquidationThreshold), expectedLiqThreshold, string.concat("LiqThreshold mismatch for ", tokenName));
        assertEq(uint256(actual.liquidationBonus), expectedLiqBonus, string.concat("LiqBonus mismatch for ", tokenName));
    }

    /// @dev Resolves a token name to its address. Checks fixtures first (for chain-specific tokens),
    ///      then falls back to well-known addresses.
    function _resolveToken(string memory name) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory key = string.concat(".", chainId, ".", name);

        if (vm.keyExistsJson(fixtures, key)) {
            return stdJson.readAddress(fixtures, key);
        }

        // ETH sentinel
        if (keccak256(bytes(name)) == keccak256(bytes("ETH"))) {
            return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        }

        revert(string.concat("Cannot resolve token: ", name));
    }

    function _tryEnv(string memory key, string memory fallback_) internal view returns (string memory) {
        try vm.envString(key) returns (string memory val) {
            return bytes(val).length > 0 ? val : fallback_;
        } catch {
            return fallback_;
        }
    }
}
