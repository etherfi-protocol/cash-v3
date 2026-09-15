// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Deploys and configures `TradingSafeLiquidDepositModule` on the Ethereum dev trading stack.
 * @dev Deploys the module through the dev EtherFiDeployer with only the Liquid BTC teller route,
 *      grants DEV_ADMIN route-admin and pause roles, and registers the module as a default module
 *      so it is enabled on existing and future dev TradingSafes.
 *
 *      The configured teller currently accepts WBTC and has no share lock. Input-token support
 *      remains teller-controlled, while future Liquid vault routes can be added through the module's
 *      governance-gated `addLiquidAssets`.
 *
 *      Idempotent: an existing deterministic deployment is reused; role grants, route configuration,
 *      and default-module registration are skipped when already correct. With PRIVATE_KEY unset the
 *      script impersonates DEV_ADMIN for fork simulation. A real broadcast must provide its key.
 *
 * Usage (fork simulation):
 *   source .env && forge script \
 *     scripts/trading-account/DeployTradingSafeLiquidDepositModuleDev.s.sol \
 *     --rpc-url $MAINNET_RPC
 *
 * Usage (broadcast later):
 *   source .env && forge script \
 *     scripts/trading-account/DeployTradingSafeLiquidDepositModuleDev.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployTradingSafeLiquidDepositModuleDev is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    /// @dev Guard against accidentally configuring the production trading stack.
    address private constant PROD_DATA_PROVIDER = 0xcaC7ec798A9561B00Ff2F3C7505a0C2c1B543d0C;

    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address private constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;

    bytes32 private constant MODULE_ADMIN_ROLE = keccak256("TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN");
    string private constant SALT_NAME = "TradingAccount.Dev.v1.TradingSafeLiquidDepositModule";
    string private constant MANIFEST_PATH = "/deployments/dev/1/trading-account.json";
    string private constant MANIFEST_KEY = "TradingSafeLiquidDepositModule";

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");
        require(WBTC.code.length > 0, "WBTC not deployed");
        require(LIQUID_BTC.code.length > 0, "Liquid BTC not deployed");
        require(LIQUID_BTC_TELLER.code.length > 0, "Liquid BTC teller not deployed");
        require(address(ILayerZeroTeller(LIQUID_BTC_TELLER).vault()) == LIQUID_BTC, "Liquid BTC teller vault mismatch");
        require(ILayerZeroTeller(LIQUID_BTC_TELLER).assetData(ERC20(WBTC)).allowDeposits, "Liquid BTC teller does not accept WBTC");
        require(ILayerZeroTeller(LIQUID_BTC_TELLER).shareLockPeriod() == 0, "Liquid BTC shares are locked");

        string memory manifest = _readManifest();
        address dataProvider = manifest.readAddress(".EtherFiDataProvider");
        require(dataProvider.code.length > 0, "dev EtherFiDataProvider not deployed");
        require(dataProvider != PROD_DATA_PROVIDER, "manifest points at prod data provider");

        EtherFiDataProvider provider = EtherFiDataProvider(dataProvider);
        require(provider.getCashModule() == address(0), "unexpected cash module on trading stack");

        RoleRegistry registry = RoleRegistry(address(provider.roleRegistry()));
        require(address(registry) == manifest.readAddress(".RoleRegistry"), "registry is not dev manifest registry");
        require(registry.owner() == DEV_ADMIN, "dev admin does not own dev RoleRegistry");

        bytes32 pauser = registry.PAUSER();
        bytes32 unpauser = registry.UNPAUSER();
        bytes32 dataProviderAdmin = provider.DATA_PROVIDER_ADMIN_ROLE();

        address moduleAddress = DEPLOYER.getDeterministicAddress(getSalt(SALT_NAME));
        bool wasDeployed = moduleAddress.code.length > 0;
        bool wasDefault = provider.isDefaultModule(moduleAddress);
        bool routeConfigured = wasDeployed && address(TradingSafeLiquidDepositModule(moduleAddress).liquidAssetToTeller(LIQUID_BTC)) == LIQUID_BTC_TELLER;

        console2.log("predicted module    ", moduleAddress);
        console2.log("already deployed    ", wasDeployed);
        console2.log("route configured    ", routeConfigured);
        console2.log("already default     ", wasDefault);

        address[] memory liquidAssets = _single(LIQUID_BTC);
        address[] memory tellers = _single(LIQUID_BTC_TELLER);

        _startBroadcast();
        if (!wasDeployed) {
            bytes memory creationCode = abi.encodePacked(type(TradingSafeLiquidDepositModule).creationCode, abi.encode(liquidAssets, tellers, dataProvider));
            require(DEPLOYER.deploy(getSalt(SALT_NAME), creationCode) == moduleAddress, "deployed off predicted address");
        }

        if (!registry.hasRole(pauser, DEV_ADMIN)) registry.grantRole(pauser, DEV_ADMIN);
        if (!registry.hasRole(unpauser, DEV_ADMIN)) registry.grantRole(unpauser, DEV_ADMIN);
        if (!registry.hasRole(dataProviderAdmin, DEV_ADMIN)) {
            registry.grantRole(dataProviderAdmin, DEV_ADMIN);
        }
        if (!registry.hasRole(MODULE_ADMIN_ROLE, DEV_ADMIN)) {
            registry.grantRole(MODULE_ADMIN_ROLE, DEV_ADMIN);
        }

        if (!routeConfigured) {
            TradingSafeLiquidDepositModule(moduleAddress).addLiquidAssets(liquidAssets, tellers);
        }
        if (!wasDefault) {
            address[] memory modules = _single(moduleAddress);
            bool[] memory flags = new bool[](1);
            flags[0] = true;
            provider.configureDefaultModules(modules, flags);
        }
        vm.stopBroadcast();

        TradingSafeLiquidDepositModule module = TradingSafeLiquidDepositModule(moduleAddress);
        require(moduleAddress.code.length > 0, "module not deployed");
        require(address(module.etherFiDataProvider()) == dataProvider, "module bound to wrong data provider");
        require(address(module.liquidAssetToTeller(LIQUID_BTC)) == LIQUID_BTC_TELLER, "Liquid BTC route not configured");
        require(!module.paused(), "module must be left unpaused");
        require(provider.isWhitelistedModule(moduleAddress), "module not whitelisted");
        require(provider.isDefaultModule(moduleAddress), "module not default");
        require(registry.hasRole(pauser, DEV_ADMIN), "dev admin not PAUSER");
        require(registry.hasRole(unpauser, DEV_ADMIN), "dev admin not UNPAUSER");
        require(registry.hasRole(dataProviderAdmin, DEV_ADMIN), "dev admin not data provider admin");
        require(registry.hasRole(MODULE_ADMIN_ROLE, DEV_ADMIN), "dev admin not module admin");
        require(registry.owner() == DEV_ADMIN, "CRITICAL: RoleRegistry owner changed");

        _writeManifest(manifest, moduleAddress);

        console2.log("TradingSafeLiquidDepositModule", moduleAddress);
        console2.log("EtherFiDataProvider", dataProvider);
        console2.log("RoleRegistry", address(registry));
    }

    function _writeManifest(string memory manifest, address module) private {
        string[] memory keys = vm.parseJsonKeys(manifest, "$");
        string memory obj = "trading-account-dev-liquid-deposit";
        string memory json;
        for (uint256 i = 0; i < keys.length; ++i) {
            if (isEqualString(keys[i], MANIFEST_KEY)) continue;
            json = vm.serializeAddress(obj, keys[i], manifest.readAddress(string.concat(".", keys[i])));
        }
        json = vm.serializeAddress(obj, MANIFEST_KEY, module);

        string memory path = string.concat(".", MANIFEST_PATH);
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }

    function _readManifest() private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), MANIFEST_PATH));
    }

    function _startBroadcast() private {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) {
            vm.startBroadcast(DEV_ADMIN);
        } else {
            require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not dev admin");
            vm.startBroadcast(privateKey);
        }
    }

    function _single(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
