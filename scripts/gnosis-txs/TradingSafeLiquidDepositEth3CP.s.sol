// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountGnosisHelpers } from "./TradingAccountGnosisHelpers.sol";

/**
 * @notice Generates the Ethereum 3CP JSON that turns on the `TradingSafeLiquidDepositModule`.
 *         Two txs from the OperatingSafe, which owns the RoleRegistry and holds
 *         DATA_PROVIDER_ADMIN_ROLE:
 *
 *           1. RoleRegistry.grantRole(TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN, OperatingSafe)
 *           2. EtherFiDataProvider.configureDefaultModules([TradingSafeLiquidDepositModule], [true])
 *
 *         `configureDefaultModules` whitelists AND marks the module default in one call, so it is
 *         enabled on every mainnet TradingSafe — existing safes included, since `isModuleEnabled`
 *         short-circuits on the data provider's default set rather than per-safe storage. That
 *         matches how the withdraw module, Enso, and Across are registered on this deployment.
 *
 *         The WBTC → Liquid BTC teller is set in the constructor, so this bundle does not call
 *         `addLiquidAssets`. The admin grant is what lets a later Safe tx add or remove routes.
 *         PAUSER and UNPAUSER are not granted here: the withdraw 3CP already put them on this
 *         registry (HyperNative and the Safe can pause; only the Safe can unpause). This script
 *         requires those holders and exercises the switch on the new module.
 *
 *         Ethereum only. Deposited Liquid BTC is forwarded to the factory-bound TopUp; the existing
 *         permissionless sweep bridges it to Optimism.
 *
 * @dev The module address is the CREATE3 prediction, so this bundle can be produced and reviewed
 *      before `DeployTradingSafeLiquidDepositModuleProd` broadcasts. Where the module is not on
 *      chain yet the fork simulation deploys it locally at that same deterministic address first,
 *      so the simulated end state is the one the real bundle produces.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/TradingSafeLiquidDepositEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract TradingSafeLiquidDepositEth3CP is TradingAccountGnosisHelpers, Utils, TradingAccountCreate3 {
    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        address module = _predict(C.SALT_TRADING_SAFE_LIQUID_DEPOSIT_MODULE);
        require(dataProvider.code.length > 0, "EtherFiDataProvider not deployed");
        require(!EtherFiDataProvider(dataProvider).isDefaultModule(module), "module already default");
        _requireTellerReady();

        // Read the registry off the data provider rather than trusting the salt: it is the one the
        // module resolves at runtime, and grants to any other registry would be inert.
        RoleRegistry registry = RoleRegistry(address(EtherFiDataProvider(dataProvider).roleRegistry()));
        require(address(registry) == _predict(C.SALT_ROLE_REGISTRY_PROXY), "registry is not the prod CREATE3 registry");
        require(registry.owner() == C.OPERATING_SAFE, "OperatingSafe does not own the RoleRegistry");
        require(registry.hasRole(EtherFiDataProvider(dataProvider).DATA_PROVIDER_ADMIN_ROLE(), C.OPERATING_SAFE), "OperatingSafe is not DATA_PROVIDER_ADMIN");

        bytes32 admin = keccak256("TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN");
        bytes32 pauser = registry.PAUSER();
        bytes32 unpauser = registry.UNPAUSER();
        require(pauser == keccak256("PAUSER") && unpauser == keccak256("UNPAUSER"), "unexpected role hashes");
        require(!registry.hasRole(admin, C.OPERATING_SAFE), "admin role already granted");
        require(registry.hasRole(pauser, C.HYPERNATIVE_EXECUTOR), "HyperNative is not PAUSER");
        require(registry.hasRole(pauser, C.OPERATING_SAFE), "OperatingSafe is not PAUSER");
        require(registry.hasRole(unpauser, C.OPERATING_SAFE), "OperatingSafe is not UNPAUSER");

        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _appendRole(txs, address(registry), admin, C.OPERATING_SAFE);
        bytes memory data = abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, flags);
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(dataProvider), iToHex(data), "0", true));

        vm.createDir("./output", true);
        string memory path = "./output/TradingSafeLiquidDeposit3CP-eth-1.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        _requireModuleDeployed(module, dataProvider);
        executeGnosisTransactionBundle(path);

        TradingSafeLiquidDepositModule deployed = TradingSafeLiquidDepositModule(module);
        require(deployed.TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN() == admin, "unexpected admin role hash");
        require(EtherFiDataProvider(dataProvider).isWhitelistedModule(module), "module not whitelisted");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(module), "module not default");
        require(registry.hasRole(admin, C.OPERATING_SAFE), "OperatingSafe missing liquid deposit admin");
        require(address(deployed.liquidAssetToTeller(C.LIQUID_BTC)) == C.LIQUID_BTC_TELLER, "Liquid BTC route mismatch");
        _requirePauseSwitchLive(module);

        console.log("Simulation passed. TradingSafeLiquidDepositModule: %s", module);
    }

    /// @dev The constructor only checks `teller.vault() == liquidAsset`. Refuse to enable the module
    ///      if the live teller would reject a WBTC deposit or lock the minted shares.
    function _requireTellerReady() private view {
        ILayerZeroTeller teller = ILayerZeroTeller(C.LIQUID_BTC_TELLER);
        require(address(teller.vault()) == C.LIQUID_BTC, "teller vault is not Liquid BTC");
        require(teller.assetData(ERC20(C.WBTC)).allowDeposits, "teller does not accept WBTC");
        require(teller.shareLockPeriod() == 0, "teller share lock would trap the forward");
    }

    /// @dev The roles are the means, a working kill switch is the end — so exercise it rather than
    ///      just reading `hasRole`. Both pausers must be able to stop deposits, only the Safe may
    ///      restart them, and the module must be left unpaused.
    function _requirePauseSwitchLive(address module) private {
        TradingSafeLiquidDepositModule m = TradingSafeLiquidDepositModule(module);

        vm.prank(C.HYPERNATIVE_EXECUTOR);
        m.pause();
        require(m.paused(), "HyperNative pause did not take effect");

        vm.prank(C.HYPERNATIVE_EXECUTOR);
        vm.expectRevert(); // UNPAUSER is Safe-only: a fast pauser must not be able to undo it.
        m.unpause();

        vm.prank(C.OPERATING_SAFE);
        m.unpause();
        require(!m.paused(), "OperatingSafe unpause did not take effect");

        vm.prank(C.OPERATING_SAFE);
        m.pause();
        require(m.paused(), "OperatingSafe pause did not take effect");

        vm.prank(C.OPERATING_SAFE);
        m.unpause();
        require(!m.paused(), "module must be left unpaused");
    }

    /// @dev CREATE3 is permissionless and address-deterministic, so deploying the module inside the
    ///      fork reproduces exactly what the broadcast deploy will put at `module`.
    function _requireModuleDeployed(address module, address dataProvider) private {
        if (module.code.length == 0) {
            console.log("Module not deployed on chain; deploying in fork at the predicted address");
            _deployCreate3(_creationCode(dataProvider), C.SALT_TRADING_SAFE_LIQUID_DEPOSIT_MODULE);
        }
        TradingSafeLiquidDepositModule deployed = TradingSafeLiquidDepositModule(module);
        require(address(deployed.etherFiDataProvider()) == dataProvider, "module bound to wrong data provider");
        require(address(deployed.liquidAssetToTeller(C.LIQUID_BTC)) == C.LIQUID_BTC_TELLER, "Liquid BTC route mismatch");
    }

    function _creationCode(address dataProvider) private pure returns (bytes memory) {
        address[] memory liquidAssets = new address[](1);
        liquidAssets[0] = C.LIQUID_BTC;
        address[] memory tellers = new address[](1);
        tellers[0] = C.LIQUID_BTC_TELLER;
        return abi.encodePacked(type(TradingSafeLiquidDepositModule).creationCode, abi.encode(liquidAssets, tellers, dataProvider));
    }
}
