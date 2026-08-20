// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafeWithdrawModule } from "../../src/trading-safe/TradingSafeWithdrawModule.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Deploys and enables the `TradingSafeWithdrawModule` on the Ethereum **dev** trading stack.
 * @dev The dev counterpart of `DeployTradingSafeWithdrawModuleProd` + `gnosis-txs/TradingSafeWithdrawEth3CP`,
 *      which are split in two because prod's registry admin is a multisig. On dev both the RoleRegistry
 *      owner and `DATA_PROVIDER_ADMIN_ROLE` sit on `DEV_ADMIN`, so deploy and configuration are one
 *      broadcast, mirroring `AddTradingTokensEthereumDev`.
 *
 *      Configuration is exactly what prod's bundle does, minus HyperNative (dev has no automated
 *      responder): grant PAUSER/UNPAUSER to `DEV_ADMIN` so the kill switch is live *before* the module
 *      is, then `configureDefaultModules([module], [true])` — which whitelists AND marks it default in
 *      one call, so it is enabled on every existing dev TradingSafe without a per-safe setup tx.
 *
 *      Ethereum only: OP TradingSafes carry a CashModule and exit through its delayed withdrawal.
 *
 *      Idempotent — a module already at the deterministic address is reused, and every role /
 *      whitelist step is skipped when already in place, so a partially failed run is safe to re-run.
 *      With PRIVATE_KEY unset the run impersonates DEV_ADMIN (fork simulation); a real broadcast must
 *      supply the dev admin key.
 *
 * Usage (simulate, doubles as the "is it already deployed?" check):
 *   source .env && forge script scripts/trading-account/DeployTradingSafeWithdrawModuleDev.s.sol \
 *     --rpc-url $MAINNET_RPC
 *
 * Usage (broadcast):
 *   source .env && forge script scripts/trading-account/DeployTradingSafeWithdrawModuleDev.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployTradingSafeWithdrawModuleDev is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    /// @dev Prod's data provider, listed only so a mis-edited manifest can't point this dev-admin
    ///      broadcast at the production stack (whose registry DEV_ADMIN does not own anyway).
    address private constant PROD_DATA_PROVIDER = 0xcaC7ec798A9561B00Ff2F3C7505a0C2c1B543d0C;

    string private constant SALT_NAME = "TradingAccount.Dev.v1.TradingSafeWithdrawModule";
    string private constant MANIFEST_PATH = "/deployments/dev/1/trading-account.json";
    string private constant MANIFEST_KEY = "TradingSafeWithdrawModule";

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        string memory manifest = _readManifest();
        address dataProvider = manifest.readAddress(".EtherFiDataProvider");
        require(dataProvider.code.length > 0, "dev EtherFiDataProvider not deployed");
        require(dataProvider != PROD_DATA_PROVIDER, "manifest points at the prod data provider");

        EtherFiDataProvider provider = EtherFiDataProvider(dataProvider);
        require(provider.getCashModule() == address(0), "unexpected cash module on trading stack");

        // Read the registry off the data provider rather than trusting the manifest: it is the one the
        // module resolves at runtime, so grants to any other registry would be inert. The manifest
        // entry is then only cross-checked, not relied on.
        RoleRegistry registry = RoleRegistry(address(provider.roleRegistry()));
        require(address(registry) == manifest.readAddress(".RoleRegistry"), "registry is not the dev manifest registry");
        require(registry.owner() == DEV_ADMIN, "dev admin does not own the dev RoleRegistry");

        bytes32 pauser = registry.PAUSER();
        bytes32 unpauser = registry.UNPAUSER();
        bytes32 dataProviderAdmin = keccak256("ADMIN_TIMELOCK_ROLE");
        require(pauser == keccak256("PAUSER") && unpauser == keccak256("UNPAUSER"), "unexpected role hashes");

        address module = DEPLOYER.getDeterministicAddress(getSalt(SALT_NAME));
        bool wasDeployed = module.code.length > 0;
        bool wasDefault = provider.isDefaultModule(module);
        console2.log("predicted module    ", module);
        console2.log("already deployed    ", wasDeployed);
        console2.log("already default     ", wasDefault);

        _startBroadcast();
        if (!wasDeployed) require(DEPLOYER.deploy(getSalt(SALT_NAME), abi.encodePacked(type(TradingSafeWithdrawModule).creationCode, abi.encode(dataProvider))) == module, "deployed off the predicted address");
        // The pause switch goes live before the module does, matching the prod bundle's ordering.
        if (!registry.hasRole(pauser, DEV_ADMIN)) registry.grantRole(pauser, DEV_ADMIN);
        if (!registry.hasRole(unpauser, DEV_ADMIN)) registry.grantRole(unpauser, DEV_ADMIN);
        if (!registry.hasRole(dataProviderAdmin, DEV_ADMIN)) registry.grantRole(dataProviderAdmin, DEV_ADMIN);
        if (!wasDefault) {
            address[] memory modules = new address[](1);
            modules[0] = module;
            bool[] memory flags = new bool[](1);
            flags[0] = true;
            provider.configureDefaultModules(modules, flags);
        }
        vm.stopBroadcast();

        // The data provider is an immutable in the module's code, and a module bound to the wrong one
        // would pass every registration check and then fail on the first withdrawal.
        require(module.code.length > 0, "module not deployed");
        require(address(TradingSafeWithdrawModule(module).etherFiDataProvider()) == dataProvider, "module bound to wrong data provider");
        require(!TradingSafeWithdrawModule(module).paused(), "module must be left unpaused");

        require(provider.isWhitelistedModule(module), "module not whitelisted");
        require(provider.isDefaultModule(module), "module not default");
        require(registry.hasRole(pauser, DEV_ADMIN), "dev admin not PAUSER");
        require(registry.hasRole(unpauser, DEV_ADMIN), "dev admin not UNPAUSER");
        require(registry.hasRole(dataProviderAdmin, DEV_ADMIN), "dev admin not data provider admin");

        // Last check: nothing in the batch may have moved the registry out of DEV_ADMIN's control.
        require(registry.owner() == DEV_ADMIN, "CRITICAL: RoleRegistry owner changed!");

        _writeManifest(manifest, module);

        console2.log("TradingSafeWithdrawModule", module);
        console2.log("EtherFiDataProvider", dataProvider);
        console2.log("RoleRegistry", address(registry));
    }

    /// @dev Rewrites the manifest key-for-key so the new entry is added without dropping anything —
    ///      `vm.writeJson` into a single key can only replace one that already exists.
    function _writeManifest(string memory manifest, address module) private {
        string[] memory keys = vm.parseJsonKeys(manifest, "$");
        string memory obj = "trading-account-dev-withdraw";
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
            require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not the dev admin");
            vm.startBroadcast(privateKey);
        }
    }
}
