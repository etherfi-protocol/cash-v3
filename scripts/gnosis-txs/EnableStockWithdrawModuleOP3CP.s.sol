// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { StockWithdrawConfig } from "../stock-withdraw/StockWithdrawConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title EnableStockWithdrawModuleOP3CP
 * @author ether.fi
 * @notice 3CP-646 — the OP leg of the stock-withdraw launch: turns the deployed
 *         StockWithdrawModule on with a SINGLE 3CP bundle, then simulates it on the current
 *         fork and asserts the end state.
 *
 *         Both calls here are ROLE-gated and the Safe holds both roles directly, so this
 *         bundle needs NO timelock:
 *
 *           EtherFiDataProvider.configureDefaultModules([module], [true])   DATA_PROVIDER_ADMIN_ROLE
 *           CashModule.configureModulesCanRequestWithdraw([module], [true]) CASH_MODULE_CONTROLLER_ROLE
 *
 *         `configureDefaultModules(true)` adds to the whitelist AND the default set in one
 *         call, so every existing EtherFiSafe picks the module up without a per-safe tx.
 *
 * @dev This is one of three independent 3CPs, deliberately not batched:
 *        - 3CP-646 (this one, OP)  — enable the module. No timelock.
 *        - 3CP-647 (Ethereum)      — the whole Ethereum leg in one bundle: STOCK_UNWRAPPER_ADMIN_ROLE
 *                                    to the Safe, plus the raw-stock top-up token configs. No
 *                                    timelock: the Safe owns the Ethereum RoleRegistry directly,
 *                                    so both calls are plain Safe transactions.
 *        - 3CP-648 (OP)            — grant STOCK_WITHDRAW_MODULE_ADMIN_ROLE to the Safe. Two
 *                                    bundles 8h apart, because `grantRole` on OP is owner-gated
 *                                    and the owner is the EtherFiTimelock.
 *
 *      Going live before 3CP-648 completes is deliberate and safe:
 *        - the module's launch config is complete at `initialize` (all three supported iTOKENs,
 *          the Ethereum unwrapper route, measured LZ gas limits, providerFeeBps = 0), all
 *          re-asserted below;
 *        - `pause()` is PAUSER-role gated (NOT the admin role, NOT ownership) and the Safe holds
 *          PAUSER/UNPAUSER, so emergency stop is available immediately.
 *      What waits for 3CP-648 is only later ADJUSTMENT: `setLzGasLimits`, `configureTokens`,
 *      `configureUnwrappers`, `setProviderFee`. Until the grant lands, nobody can bump the LZ
 *      gas limits — the failure mode that previously stranded a live withdrawal — so treat
 *      3CP-648 as launch-critical follow-through, not optional cleanup.
 *
 * Prerequisite: the prod module is deployed and recorded at `.addresses.StockWithdrawModule`
 * in deployments/mainnet/10/deployments.json (DeployStockWithdrawModule.s.sol, ENV=mainnet).
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/EnableStockWithdrawModuleOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract EnableStockWithdrawModuleOP3CP is StockWithdrawConfig, GnosisHelpers {
    using stdJson for string;

    EtherFiDataProvider internal dataProvider;
    RoleRegistry internal roleRegistry;
    ICashModule internal cashModule;
    StockWithdrawModule internal module;
    address internal lendGateway;

    function run() public {
        require(block.chainid == 10, "EnableStockWithdraw: Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _checkPreconditions();

        string memory path = _writeBundle();
        _simulateAndVerify(path);
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _loadAddresses() internal {
        string memory deployments = readDeploymentFile();

        require(
            vm.keyExistsJson(deployments, ".addresses.StockWithdrawModule"),
            "StockWithdrawModule missing from deployments.json - deploy it first (DeployStockWithdrawModule.s.sol, ENV=mainnet)"
        );

        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        cashModule = ICashModule(deployments.readAddress(".addresses.CashModule"));
        module = StockWithdrawModule(payable(deployments.readAddress(".addresses.StockWithdrawModule")));
        lendGateway = deployments.readAddress(".addresses.LendGateway");
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    /// @dev The module must be the PROD one. deployments.json is hand-maintained and dev OP is
    ///      also chain 10, so a dev-salt module address landing in the prod file is a real
    ///      failure mode — the CREATE3 salt check is what rules it out.
    function _checkPreconditions() internal view {
        _assertProdAddresses();
        require(address(module).code.length > 0, "StockWithdrawModule has no code at the recorded address");
        require(address(module) == _predictAddress(_moduleProxySalt()), "recorded module != Prod.StockWithdraw.StockWithdrawModuleProxy.V2 CREATE3 address");
        require(address(module.etherFiDataProvider()) == address(dataProvider), "module is bound to a different EtherFiDataProvider");

        // The rails the module is about to be allowed to send over must still be correctly
        // peered at SIGNING time, not merely at deploy time.
        _assertAssetRails(true);

        // Enabling a module whose own config is empty would ship a dead feature — and with the
        // admin role not yet granted (3CP-648), nothing here can be fixed after the fact. Driven
        // off StockWithdrawConfig._iTokens() so adding an asset there cannot silently ship a
        // module that does not actually support it.
        (address[] memory iTokens,) = _iTokens();
        for (uint256 i = 0; i < iTokens.length; i++) {
            require(module.isTokenSupported(iTokens[i]), "module does not support a configured iToken");
        }
        require(module.getSupportedTokens().length == iTokens.length, "module supports a different NUMBER of tokens than configured");
        require(module.getStockUnwrapper(ETHEREUM_EID) == _predictAddress(_unwrapperProxySalt()), "module's Ethereum route is not the prod StockUnwrapper");
        (uint128 lzReceiveGas, uint128 composeGas) = module.getLzGasLimits();
        require(lzReceiveGas >= LZ_RECEIVE_GAS_LIMIT, "module lzReceive gas limit below the measured floor");
        require(composeGas >= COMPOSE_GAS_LIMIT, "module compose gas limit below the measured floor");

        // Emergency stop must be available from the moment the module goes live, since the
        // admin setters are not reachable until phase 2.
        require(roleRegistry.hasRole(roleRegistry.PAUSER(), SAFE), "Safe lacks PAUSER - do not enable without an emergency stop");
        require(roleRegistry.hasRole(roleRegistry.UNPAUSER(), SAFE), "Safe lacks UNPAUSER");

        // Idempotence: refuse to build a bundle that is already applied.
        require(!dataProvider.isWhitelistedModule(address(module)), "module already whitelisted - enable already done?");
        require(!dataProvider.isDefaultModule(address(module)), "module already a default module - enable already done?");

        // The Safe signs both calls directly; without these roles its own txs revert.
        require(roleRegistry.hasRole(dataProvider.ADMIN_TIMELOCK_ROLE(), SAFE), "Safe lacks DATA_PROVIDER_ADMIN_ROLE");
        require(roleRegistry.hasRole(cashModule.ADMIN_TIMELOCK_ROLE(), SAFE), "Safe lacks CASH_MODULE_CONTROLLER_ROLE");
    }

    // ── Bundle construction ───────────────────────────────────────────────────────

    function _writeBundle() internal returns (string memory path) {
        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory enable = new bool[](1);
        enable[0] = true;

        bytes memory defaultModulesData = abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, enable);
        bytes memory canRequestWithdrawData = abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, modules, enable);

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(dataProvider)), iToHex(defaultModulesData), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(cashModule)), iToHex(canRequestWithdrawData), "0", true));

        vm.createDir("./output", true);
        path = string.concat("./output/3CP-646-EnableStockWithdrawModule-op-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory path) internal {
        console.log("");
        console.log("=== Simulating the enable bundle ===");

        address ownerBefore = roleRegistry.owner();
        executeGnosisTransactionBundle(path);

        require(dataProvider.isWhitelistedModule(address(module)), "SIM FAILED: module not whitelisted");
        require(dataProvider.isDefaultModule(address(module)), "SIM FAILED: module not a default module");
        require(_canRequestWithdraw(address(module)), "SIM FAILED: module cannot request withdrawals");

        // The emergency stop must actually work on the now-live module, not merely be role-held.
        vm.prank(SAFE);
        module.pause();
        require(module.paused(), "SIM FAILED: pause did not take effect");
        vm.prank(SAFE);
        module.unpause();
        require(!module.paused(), "SIM FAILED: unpause did not take effect");

        // Collateral damage: this bundle must not touch governance or the existing module set.
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        if (lendGateway != address(0)) require(dataProvider.isDefaultModule(lendGateway), "SIM FAILED: LendGateway lost default status");

        console.log("");
        console.log("  [OK] StockWithdrawModule enabled:", address(module));
        console.log("       whitelisted + default on EtherFiDataProvider");
        console.log("       can request withdrawals on CashModule");
        console.log("  [OK] pause/unpause verified against the live module");
        console.log("");
        console.log("3CP-646 simulation passed.");
        console.log("NEXT: 3CP-648 - GrantStockWithdrawAdminRoleOP3CP.s.sol grants the module admin role");
        console.log("      via the 8h timelock. Until it lands the module config is FROZEN (no");
        console.log("      setLzGasLimits, no configureTokens).");
    }

    function _canRequestWithdraw(address target) internal view returns (bool) {
        address[] memory allowed = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == target) return true;
        }
        return false;
    }
}
