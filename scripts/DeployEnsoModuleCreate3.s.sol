// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "./utils/Utils.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";
import { EnsoSwapModule } from "../src/enso/EnsoSwapModule.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../src/utils/EtherFiDeployer.sol";

/**
 * @title DeployEnsoModuleCreate3
 * @notice Standalone CREATE3 (re)deploy of the EnsoSwapModule so its proxy lands at the SAME
 *         address on OP and mainnet — the invariant the BE relies on (a single
 *         `ensoSwapModule` field resolved on mainnet.id, exactly like AcrossSwapModule). The
 *         earlier `DeployEnsoModule.s.sol` used plain `new UUPSProxy(...)` (nonce-based CREATE),
 *         so its two proxies diverged (OP 0x9EF2…, mainnet 0xeaBf…) and could never be wired
 *         into that single field. This script fixes that.
 *
 *         Everything runs in ONE broadcast (the dev key holds the data-provider / cash-module /
 *         role-registry admin rights):
 *           1. CREATE3-deploy the impl + proxy (proxy initialised atomically in its deploy tx).
 *           2. Whitelist it as a DEFAULT module (installed on every safe) and, where a CashModule
 *              exists (OP), register it so it can place withdrawal holds.
 *           3. Grant the deployer ENSO_SWAP_MODULE_ADMIN_ROLE (so the router can be repointed).
 *           4. Retire the stale non-CREATE3 module if it's still whitelisted — one Enso remains.
 *
 *         The OP cash stack is read from `deployments.json`; the mainnet TradingSafe stack from
 *         `trading-account.json` (pass TRADING_ACCOUNT=true). On the mainnet TradingSafe
 *         `getCashModule() == 0`, so the hold registration is skipped and swaps execute
 *         immediately — matching the existing trading-account deploy.
 *
 * Run:
 *   source .env && ENV=dev forge script scripts/DeployEnsoModuleCreate3.s.sol --rpc-url optimism --broadcast -vvv --verify
 *   source .env && ENV=dev TRADING_ACCOUNT=true forge script scripts/DeployEnsoModuleCreate3.s.sol --rpc-url mainnet --broadcast -vvv --verify
 */
contract DeployEnsoModuleCreate3 is Utils {
    // Cross-chain CREATE3 deployer — same address on every chain, so a shared salt ⇒ shared address.
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    // Enso Router V2 (same address on Ethereum and Optimism). Pinned target for the module's
    // forward-calldata swaps; repointable later via setEnsoRouter (admin role granted below).
    address constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;

    // Stale plain-CREATE proxies from the earlier (non-CREATE3) DeployEnsoModule run. Chain-specific
    // because plain CREATE diverged; retired below so only the CREATE3 module stays whitelisted.
    address constant STALE_ENSO_OP = 0x9EF2C6a01EbD49EfAdA26B5a0a19f5C4FB7FC8A1;
    address constant STALE_ENSO_MAINNET = 0xeaBf20f60594bCE8edde7bBc767528B2ef30DEc6;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(DEPLOYER.isDeployer(deployer), "broadcaster not registered on EtherFiDeployer");

        (EtherFiDataProvider dataProvider, RoleRegistry roleRegistry) = _readStack();

        address predicted = DEPLOYER.getDeterministicAddress(getSalt("EnsoSwapModuleDev"));
        require(predicted.code.length == 0, "CREATE3 proxy address already occupied");

        vm.startBroadcast(pk);

        // 1. Impl + proxy, both via CREATE3. The impl constructor reads getCashModule() off the data
        //    provider, so the resulting immutable decides whether the hold path is active on this chain.
        //    The proxy initialises atomically in its deploy tx (deploy-then-init is front-runnable).
        address impl = _deploy(
            "EnsoSwapModuleImplDev", type(EnsoSwapModule).creationCode, abi.encode(address(dataProvider))
        );
        EnsoSwapModule enso = EnsoSwapModule(_deploy(
            "EnsoSwapModuleDev",
            type(UUPSProxy).creationCode,
            abi.encode(impl, abi.encodeWithSelector(EnsoSwapModule.initialize.selector, address(roleRegistry), ENSO_ROUTER))
        ));
        require(address(enso) == predicted, "enso landed off-prediction");

        // 2. Whitelist as a default module + (where present) allow it to place withdrawal holds.
        address[] memory mods = new address[](1);
        bool[] memory on = new bool[](1);
        mods[0] = address(enso);
        on[0] = true;
        dataProvider.configureDefaultModules(mods, on);

        address cashModule = dataProvider.getCashModule();
        if (cashModule != address(0)) ICashModule(cashModule).configureModulesCanRequestWithdraw(mods, on);

        // 3. Admin role so the pinned Enso router can be repointed later.
        roleRegistry.grantRole(enso.ENSO_SWAP_MODULE_ADMIN_ROLE(), deployer);

        // 4. Retire the stale non-CREATE3 module (idempotent — only acts if still whitelisted).
        address stale = block.chainid == 1 ? STALE_ENSO_MAINNET : STALE_ENSO_OP;
        if (stale != address(0) && dataProvider.isDefaultModule(stale)) {
            mods[0] = stale;
            on[0] = false;
            dataProvider.configureDefaultModules(mods, on);
            if (cashModule != address(0)) ICashModule(cashModule).configureModulesCanRequestWithdraw(mods, on);
        }

        vm.stopBroadcast();

        // Post-conditions: new module live + whitelisted, stale retired, router pinned.
        require(dataProvider.isDefaultModule(address(enso)), "enso not whitelisted");
        require(stale == address(0) || !dataProvider.isDefaultModule(stale), "stale module still whitelisted");
        require(enso.getEnsoRouter() == ENSO_ROUTER, "enso router mismatch");

        _persist(address(enso), impl);

        console.log("EnsoSwapModule (CREATE3):", address(enso));
        console.log("EnsoSwapModule impl:     ", impl);
        console.log("CashModule (hold path):  ", cashModule);
        console.log("Retired stale module:    ", stale);
    }

    /// @dev OP reads the live cash stack from deployments.json; the mainnet TradingSafe stack records
    ///      its addresses in a flat trading-account.json (TRADING_ACCOUNT=true).
    function _readStack() internal view returns (EtherFiDataProvider dataProvider, RoleRegistry roleRegistry) {
        if (_isTradingAccount()) {
            string memory tradingFile = string.concat(
                vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/trading-account.json"
            );
            string memory trading = vm.readFile(tradingFile);
            dataProvider = EtherFiDataProvider(stdJson.readAddress(trading, ".EtherFiDataProvider"));
            roleRegistry = RoleRegistry(stdJson.readAddress(trading, ".RoleRegistry"));
        } else {
            string memory deployments = readDeploymentFile();
            dataProvider = EtherFiDataProvider(stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider"));
            roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));
        }
    }

    /// @dev Record the deployed address for BE/FE integration. Written to a dedicated file so it
    ///      works on OP too (which has no trading-account.json).
    function _persist(address enso, address impl) internal {
        string memory out = "enso-module";
        vm.serializeAddress(out, "EnsoSwapModule", enso);
        vm.serializeAddress(out, "EnsoSwapModuleImpl", impl);
        vm.serializeAddress(out, "EnsoRouter", ENSO_ROUTER);
        string memory json = vm.serializeUint(out, "chainId", block.chainid);
        vm.writeJson(json, string.concat(
            vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/enso-module.json"
        ));
    }

    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs)
        internal
        returns (address)
    {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }

    function _isTradingAccount() internal view returns (bool) {
        try vm.envBool("TRADING_ACCOUNT") returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }
}
