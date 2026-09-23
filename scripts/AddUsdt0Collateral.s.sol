// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { IRoleRegistry } from "../src/interfaces/IRoleRegistry.sol";
import { PriceProviderV2 } from "../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

/// @dev Minimal accessor for the `roleRegistry()` getter that every UpgradeableProxy-derived
///      contract exposes. IDebtManager / ICashModule don't declare it, so this reads it off the
///      raw proxy address without needing their concrete implementation types.
interface IProxyRoleRegistry {
    function roleRegistry() external view returns (address);
}

/// @title AddUsdt0Collateral
/// @notice COR-1753: registers USD₮0 (0x01bFF41798a0BcF287b996046Ca68b395DbC1071, Optimism) with
///         *exactly* USDT's live configuration -- same PriceProviderV2 oracle config, same
///         DebtManager collateral config (LTV / liquidation threshold / liquidation bonus) --
///         and whitelists it as a withdrawable Cash asset, the same three steps
///         AddOpCollateral(Dev) used to onboard OP as collateral.
///
///         USDT0 is collateral only for this ticket: supportBorrowToken is never called, even
///         though USDT itself is also a borrow token today. Direct "Debit" swipes and legacy
///         "Credit" borrows both require `debtManager.isBorrowToken(token)` on the *spent*
///         token (CashLendLib.sol:662,942) -- so USDT0 itself is not directly swipeable. What
///         collateral registration buys is Credit-mode spend: `spendCredit` borrows an
///         *already-supported* borrow token (e.g. USDC/USDT) sized against the safe's total
///         collateral value, and `DebtManager.borrow()` (called from
///         `CashLendLib._spendLegacyCredit`) checks that borrow's health across every supported
///         collateral token -- which will include USDT0 once this script runs. That borrow-path
///         health check is what "spendable" cashes out to for a collateral-only token; it needs
///         nothing from CashModule/EtherFiDataProvider beyond the withdraw whitelist.
///
///         The deployed PriceProvider proxy runs the V2 implementation (generic `baseAsset`
///         field rather than V1's isBaseTokenEth/isBaseTokenBtc bools) -- confirmed by
///         disassembling the live implementation bytecode (see PR/task notes); importing the V1
///         `PriceProvider.sol` type here would silently mis-encode the call. USDT/USD is
///         USD-denominated, so baseAsset = address(0), and USDT0 mirrors that.
///
///         Dev: direct EOA broadcast (PRIVATE_KEY). Mainnet: emits a Gnosis bundle for the Cash
///         controller Safe into output/, simulates it on a fork via GnosisHelpers, then reads
///         back on-chain state to confirm it matches USDT's.
///
///         Idempotent: each of the 3 steps is independently skipped once its target state is
///         already reached (comparing full struct equality, not just "is it set"), so a partial
///         run can be re-run safely. If a step's state exists but does NOT match USDT's, the
///         script reverts rather than silently overwriting or ignoring the mismatch.
///
/// Usage:
///   source .env && ENV=dev forge script scripts/AddUsdt0Collateral.s.sol:AddUsdt0Collateral --rpc-url $OPTIMISM_RPC --broadcast -vvvv
///   source .env && ENV=mainnet forge script scripts/AddUsdt0Collateral.s.sol:AddUsdt0Collateral --rpc-url optimism -vvv
contract AddUsdt0Collateral is Utils, GnosisHelpers, Test {
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // USDT (the template) and USD₮0 (the new token) on Optimism. Both 6 decimals.
    address constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;

    // The Chainlink USDT/USD feed USDT0 reuses -- documented and signed off in COR-1753.
    // Asserted against USDT's live oracle below rather than trusted blindly: a typo'd oracle is
    // the main risk in this ticket.
    address constant USDT_USD_CHAINLINK_FEED = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;

    bytes32 constant PRICE_PROVIDER_ADMIN_ROLE = keccak256("PRICE_PROVIDER_ADMIN_ROLE");
    bytes32 constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");
    bytes32 constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");

    PriceProviderV2 priceProvider;
    IDebtManager debtManager;
    ICashModule cashModule;

    function run() public {
        require(block.chainid == 10, "AddUsdt0Collateral: Optimism only");

        string memory deployments = readDeploymentFile();
        priceProvider = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));

        console.log("Env:          ", getEnv());
        console.log("PriceProvider:", address(priceProvider));
        console.log("DebtManager:  ", address(debtManager));
        console.log("CashModule:   ", address(cashModule));

        // All three proxies must share one RoleRegistry -- if they ever diverge, the role checks
        // below would be checking the wrong registry.
        address roleRegistryAddr = address(priceProvider.roleRegistry());
        require(IProxyRoleRegistry(address(debtManager)).roleRegistry() == roleRegistryAddr, "DebtManager roleRegistry != PriceProvider's");
        require(IProxyRoleRegistry(address(cashModule)).roleRegistry() == roleRegistryAddr, "CashModule roleRegistry != PriceProvider's");
        IRoleRegistry roleRegistry = IRoleRegistry(roleRegistryAddr);

        // ---- Step 1: read USDT's live config -- this IS the spec USDT0 mirrors ----
        PriceProviderV2.Config memory usdtOracleConfig = priceProvider.tokenConfig(USDT);
        require(usdtOracleConfig.oracle != address(0), "USDT has no PriceProvider config on this deployment");
        require(usdtOracleConfig.oracle == USDT_USD_CHAINLINK_FEED, "USDT's live oracle != the documented USDT/USD Chainlink feed");
        require(usdtOracleConfig.baseAsset == address(0), "USDT unexpectedly has a non-USD base asset");

        require(debtManager.isCollateralToken(USDT), "USDT is not a DebtManager collateral token on this deployment");
        IDebtManager.CollateralTokenConfig memory usdtCollateralConfig = debtManager.collateralTokenConfig(USDT);

        console.log("--- USDT live PriceProviderV2.Config ---");
        console.log("  oracle:              ", usdtOracleConfig.oracle);
        console.log("  isChainlinkType:     ", usdtOracleConfig.isChainlinkType);
        console.log("  oraclePriceDecimals: ", usdtOracleConfig.oraclePriceDecimals);
        console.log("  maxStaleness:        ", usdtOracleConfig.maxStaleness);
        console.log("  dataType (0=Int256): ", uint8(usdtOracleConfig.dataType));
        console.log("  isStableToken:       ", usdtOracleConfig.isStableToken);
        console.log("  baseAsset:           ", usdtOracleConfig.baseAsset);
        console.log("--- USDT live DebtManager.CollateralTokenConfig ---");
        console.log("  ltv:                 ", usdtCollateralConfig.ltv);
        console.log("  liquidationThreshold:", usdtCollateralConfig.liquidationThreshold);
        console.log("  liquidationBonus:    ", usdtCollateralConfig.liquidationBonus);

        // USDT0's target config is an exact struct copy of USDT's -- copying rather than
        // re-typing the fields removes any chance of a transcription typo.
        PriceProviderV2.Config memory usdt0OracleConfig = usdtOracleConfig;
        IDebtManager.CollateralTokenConfig memory usdt0CollateralConfig = usdtCollateralConfig;

        if (isEqualString(getEnv(), "dev")) {
            _runDev(roleRegistry, usdt0OracleConfig, usdt0CollateralConfig);
        } else {
            _runMainnet(roleRegistry, usdt0OracleConfig, usdt0CollateralConfig);
        }

        _verify(usdt0OracleConfig, usdt0CollateralConfig);
    }

    // ---------------------------------------------------------------------------------------
    // Dev: direct EOA broadcast
    // ---------------------------------------------------------------------------------------

    function _runDev(IRoleRegistry roleRegistry, PriceProviderV2.Config memory oracleConfig, IDebtManager.CollateralTokenConfig memory collateralConfig) internal {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerPrivateKey);

        require(roleRegistry.hasRole(PRICE_PROVIDER_ADMIN_ROLE, broadcaster), "broadcaster lacks PRICE_PROVIDER_ADMIN_ROLE");
        require(roleRegistry.hasRole(DEBT_MANAGER_ADMIN_ROLE, broadcaster), "broadcaster lacks DEBT_MANAGER_ADMIN_ROLE");
        require(roleRegistry.hasRole(CASH_MODULE_CONTROLLER_ROLE, broadcaster), "broadcaster lacks CASH_MODULE_CONTROLLER_ROLE");

        vm.startBroadcast(deployerPrivateKey);

        if (_oracleNeedsUpdate(oracleConfig)) {
            address[] memory tokens = new address[](1);
            tokens[0] = USDT0;
            PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
            configs[0] = oracleConfig;
            priceProvider.setTokenConfig(tokens, configs);
            console.log("  [SET] PriceProviderV2 config for USDT0");
        } else {
            console.log("  [SKIP] PriceProviderV2 config for USDT0 already matches USDT's");
        }

        if (debtManager.isCollateralToken(USDT0)) {
            require(_collateralConfigMatches(debtManager.collateralTokenConfig(USDT0), collateralConfig), "USDT0 already a collateral token but with a DIFFERENT config than USDT's");
            console.log("  [SKIP] USDT0 already a DebtManager collateral token with matching config");
        } else {
            debtManager.supportCollateralToken(USDT0, collateralConfig);
            console.log("  [SET] USDT0 supported as DebtManager collateral");
        }

        if (_isWithdrawWhitelisted(USDT0)) {
            console.log("  [SKIP] USDT0 already whitelisted as a Cash withdraw asset");
        } else {
            address[] memory assets = new address[](1);
            assets[0] = USDT0;
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;
            cashModule.configureWithdrawAssets(assets, shouldWhitelist);
            console.log("  [SET] USDT0 whitelisted as a Cash withdraw asset");
        }

        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------------------------
    // Mainnet: Gnosis bundle for the Cash controller Safe
    // ---------------------------------------------------------------------------------------

    function _runMainnet(IRoleRegistry roleRegistry, PriceProviderV2.Config memory oracleConfig, IDebtManager.CollateralTokenConfig memory collateralConfig) internal {
        require(roleRegistry.hasRole(PRICE_PROVIDER_ADMIN_ROLE, cashControllerSafe), "cashControllerSafe lacks PRICE_PROVIDER_ADMIN_ROLE");
        require(roleRegistry.hasRole(DEBT_MANAGER_ADMIN_ROLE, cashControllerSafe), "cashControllerSafe lacks DEBT_MANAGER_ADMIN_ROLE");
        require(roleRegistry.hasRole(CASH_MODULE_CONTROLLER_ROLE, cashControllerSafe), "cashControllerSafe lacks CASH_MODULE_CONTROLLER_ROLE");

        bool needOracle = _oracleNeedsUpdate(oracleConfig);

        bool alreadyCollateral = debtManager.isCollateralToken(USDT0);
        if (alreadyCollateral) {
            require(_collateralConfigMatches(debtManager.collateralTokenConfig(USDT0), collateralConfig), "USDT0 already a collateral token but with a DIFFERENT config than USDT's");
        }
        bool needCollateral = !alreadyCollateral;

        bool needWithdraw = !_isWithdrawWhitelisted(USDT0);

        uint256 stepsNeeded = (needOracle ? 1 : 0) + (needCollateral ? 1 : 0) + (needWithdraw ? 1 : 0);
        if (stepsNeeded == 0) {
            console.log("Already fully configured on-chain; nothing to bundle.");
            return;
        }

        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        uint256 stepIndex = 0;

        if (needOracle) {
            address[] memory tokens = new address[](1);
            tokens[0] = USDT0;
            PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
            configs[0] = oracleConfig;

            string memory data = iToHex(abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(priceProvider)), data, "0", ++stepIndex == stepsNeeded)));
        }

        if (needCollateral) {
            string memory data = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, USDT0, collateralConfig));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), data, "0", ++stepIndex == stepsNeeded)));
        }

        if (needWithdraw) {
            address[] memory assets = new address[](1);
            assets[0] = USDT0;
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;

            string memory data = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, assets, shouldWhitelist));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(cashModule)), data, "0", ++stepIndex == stepsNeeded)));
        }

        vm.createDir("./output", true);
        string memory path = "./output/AddUsdt0Collateral.json";
        vm.writeFile(path, txs);
        console.log("Bundle written to:", path);

        // Simulate the bundle against a fork before trusting it.
        executeGnosisTransactionBundle(path);
        console.log("Simulation OK");
    }

    // ---------------------------------------------------------------------------------------
    // Idempotency / equality helpers
    // ---------------------------------------------------------------------------------------

    function _oracleNeedsUpdate(PriceProviderV2.Config memory target) internal view returns (bool) {
        return !_oracleConfigMatches(priceProvider.tokenConfig(USDT0), target);
    }

    function _oracleConfigMatches(PriceProviderV2.Config memory a, PriceProviderV2.Config memory b) internal pure returns (bool) {
        return a.oracle == b.oracle
            && keccak256(a.priceFunctionCalldata) == keccak256(b.priceFunctionCalldata)
            && a.isChainlinkType == b.isChainlinkType
            && a.oraclePriceDecimals == b.oraclePriceDecimals
            && a.maxStaleness == b.maxStaleness
            && a.dataType == b.dataType
            && a.isStableToken == b.isStableToken
            && a.baseAsset == b.baseAsset;
    }

    function _collateralConfigMatches(IDebtManager.CollateralTokenConfig memory a, IDebtManager.CollateralTokenConfig memory b) internal pure returns (bool) {
        return a.ltv == b.ltv && a.liquidationThreshold == b.liquidationThreshold && a.liquidationBonus == b.liquidationBonus;
    }

    function _isWithdrawWhitelisted(address token) internal view returns (bool) {
        address[] memory assets = cashModule.getWhitelistedWithdrawAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == token) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------
    // Post-condition verification -- read back on-chain state and assert it matches USDT's
    // ---------------------------------------------------------------------------------------

    function _verify(PriceProviderV2.Config memory expectedOracleConfig, IDebtManager.CollateralTokenConfig memory expectedCollateralConfig) internal view {
        require(_oracleConfigMatches(priceProvider.tokenConfig(USDT0), expectedOracleConfig), "USDT0 PriceProviderV2 config != USDT's after run");
        console.log("  [OK] USDT0 PriceProviderV2 config matches USDT's");

        uint256 p = priceProvider.price(USDT0);
        require(p > 0, "USDT0 price resolves to zero");
        require(p > 0.99e6 && p < 1.01e6, "USDT0 price is not close to $1");
        console.log("  [OK] USDT0 price resolves to", p, "(6 decimals)");

        require(debtManager.isCollateralToken(USDT0), "USDT0 is not a DebtManager collateral token after run");
        require(_collateralConfigMatches(debtManager.collateralTokenConfig(USDT0), expectedCollateralConfig), "USDT0 DebtManager collateral config != USDT's after run");
        console.log("  [OK] USDT0 DebtManager collateral config matches USDT's");

        require(!debtManager.isBorrowToken(USDT0), "USDT0 unexpectedly registered as a borrow token -- out of scope for this ticket");
        console.log("  [OK] USDT0 is NOT a borrow token (collateral-only, as scoped)");

        require(_isWithdrawWhitelisted(USDT0), "USDT0 is not whitelisted as a Cash withdraw asset after run");
        console.log("  [OK] USDT0 whitelisted as a Cash withdraw asset");
    }
}
