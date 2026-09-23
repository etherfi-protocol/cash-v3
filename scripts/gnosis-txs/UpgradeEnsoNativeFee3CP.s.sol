// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { console } from "forge-std/console.sol";

import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountGnosisHelpers } from "./TradingAccountGnosisHelpers.sol";

/**
 * @notice Generates the 3CP JSON that upgrades the live `EnsoSwapModule` proxy to the
 *         implementation supporting signed, keeper-funded native fees. One tx from the
 *         OperatingSafe (owner of the chain's RoleRegistry, which is what `onlyUpgrader` checks):
 *
 *           EnsoSwapModule.upgradeToAndCall(newImplementation, "")
 *
 *         Run once per chain — Ethereum and Optimism share the proxy address but not the
 *         deployment behind it: on Ethereum the proxy belongs to the trading stack and executes
 *         immediately (no CashModule), on Optimism it sits on the cash deployment and the keeper
 *         funds the fee when the withdrawal hold matures. Both need the new implementation.
 *
 *         Upgrade only. The change adds `requestSwapWithNativeFee` and appends `nativeFee` to the
 *         stored swap; it introduces no new roles, no config, and no initializer, and the existing
 *         zero-fee `requestSwap` digest is unchanged, so in-flight swaps stay executable across the
 *         upgrade. Hence the empty call data rather than a `reinitialize`.
 *
 * @dev The implementation address is the CREATE3 prediction, so this bundle can be produced and
 *      reviewed before `DeployEnsoNativeFeeImplProd` broadcasts. Where it is not on chain yet the
 *      fork simulation deploys it locally at that same deterministic address first, so the
 *      simulated end state is the one the real bundle produces.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/UpgradeEnsoNativeFee3CP.s.sol --rpc-url $MAINNET_RPC
 *   source .env && forge script scripts/gnosis-txs/UpgradeEnsoNativeFee3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract UpgradeEnsoNativeFee3CP is TradingAccountGnosisHelpers, Utils, TradingAccountCreate3 {
    function run() external {
        require(block.chainid == 1 || block.chainid == 10, "unsupported chain");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address proxy = _predict(C.SALT_ENSO_PROXY);
        address newImpl = _predict(C.SALT_ENSO_IMPL_NATIVE_FEE);
        require(proxy.code.length > 0, "EnsoSwapModule proxy not deployed");

        EnsoSwapModule module = EnsoSwapModule(proxy);
        address dataProvider = address(module.etherFiDataProvider());
        address cashModule = address(module.cashModule());
        address ensoRouter = module.getEnsoRouter();
        address roleRegistry = address(module.roleRegistry());
        address oldImpl = _implementationOf(proxy);
        require(oldImpl != newImpl, "already upgraded");
        require(RoleRegistry(roleRegistry).owner() == C.OPERATING_SAFE, "OperatingSafe is not the upgrader");

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newImpl, "");
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(proxy), iToHex(data), "0", true));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/EnsoNativeFeeUpgrade3CP-", block.chainid == 1 ? "eth-1" : "op-10", ".json");
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        _requireImplDeployed(newImpl, dataProvider);
        executeGnosisTransactionBundle(path);

        require(_implementationOf(proxy) == newImpl, "implementation mismatch");
        // The upgrade must not disturb anything the module resolves per chain: the data provider and
        // cash module are implementation immutables, the router and role registry are proxy storage.
        require(address(module.etherFiDataProvider()) == dataProvider, "data provider changed");
        require(address(module.cashModule()) == cashModule, "cash module changed");
        require(module.getEnsoRouter() == ensoRouter, "Enso router changed");
        require(address(module.roleRegistry()) == roleRegistry, "RoleRegistry changed");

        console.log("Simulation passed. chainId: %s", block.chainid);
        console.log("old implementation: %s", oldImpl);
        console.log("new implementation: %s", newImpl);
    }

    /// @dev CREATE3 is permissionless and address-deterministic, so deploying the implementation
    ///      inside the fork reproduces exactly what the broadcast deploy will put at `newImpl`.
    function _requireImplDeployed(address newImpl, address dataProvider) private {
        if (newImpl.code.length == 0) {
            console.log("Implementation not deployed on chain; deploying in fork at the predicted address");
            _deployCreate3(abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(dataProvider)), C.SALT_ENSO_IMPL_NATIVE_FEE);
        }
        require(address(EnsoSwapModule(newImpl).etherFiDataProvider()) == dataProvider, "implementation bound to wrong data provider");
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, C.EIP1967_IMPL_SLOT))));
    }
}
