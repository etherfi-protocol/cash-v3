// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { OneInchSwapModule } from "../../src/modules/oneinch-swap/OneInchSwapModule.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title 1inch — Deploy implementations
 * @notice Deploys every new impl the 1inch integration needs on prod:
 *           1. OneInchSwapModule implementation (UUPS) + ERC1967 proxy
 *           2. EtherFiSafe implementation (for the tightened ERC-1271 binding)
 *           3. EtherFiDataProvider implementation (adds get/setOneInchSwapModule)
 *           4. DebtManagerCore implementation
 *
 *         These are the four contracts the `feat/fusion-swap-module` branch changes relative to
 *         `dev`. Hook / CashModuleSetters / CashModuleCore are intentionally NOT redeployed — the
 *         branch leaves them byte-identical to the live impls (the audit reverted the 1inch
 *         special-cases in Hook + Setters).
 *
 *         This script only DEPLOYS impls from a plain EOA. The privileged proxy upgrades + wiring
 *         are executed by the operating safe (RoleRegistry owner / beacon owner / DataProvider
 *         admin) via the Gnosis bundle — see `scripts/1inch/BuildSafeCalldata.s.sol`.
 *
 *         Usage:
 *           ENV=mainnet PRIVATE_KEY=0x... \
 *             forge script scripts/1inch/Deploy.s.sol --rpc-url <optimism_rpc> --broadcast
 */
contract DeployOneInch is Utils {
    /// 1inch v6 Aggregation Router — canonical address on all EVM chains
    address constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    /// 1inch Fusion SimpleSettlement on Optimism (chainId 10)
    address constant SIMPLE_SETTLEMENT_OP = 0x2Ad5004c60e16E54d5007C80CE329Adde5B51Ef5;
    /// Cash operating safe — destination for `rescueFunds`
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        vm.startBroadcast(deployerPrivateKey);

        OneInchSwapModule moduleImpl = new OneInchSwapModule(AGGREGATION_ROUTER, SIMPLE_SETTLEMENT_OP, dataProvider, OPERATING_SAFE);
        ERC1967Proxy moduleProxy = new ERC1967Proxy(address(moduleImpl), abi.encodeCall(OneInchSwapModule.initialize, (roleRegistry)));

        EtherFiSafe safeImpl = new EtherFiSafe(dataProvider);
        EtherFiDataProvider dataProviderImpl = new EtherFiDataProvider();
        DebtManagerCore debtManagerImpl = new DebtManagerCore(dataProvider);

        vm.stopBroadcast();

        console.log("OneInchSwapModule impl  :", address(moduleImpl));
        console.log("OneInchSwapModule proxy :", address(moduleProxy));
        console.log("New EtherFiSafe impl    :", address(safeImpl));
        console.log("New DataProvider impl   :", address(dataProviderImpl));
        console.log("New DebtManagerCore impl:", address(debtManagerImpl));
        console.log("");
        console.log("Next step: set the following env vars and run BuildSafeCalldata.s.sol");
        console.log("  ONE_INCH_MODULE_PROXY=%s",   address(moduleProxy));
        console.log("  NEW_SAFE_IMPL=%s",           address(safeImpl));
        console.log("  NEW_DATA_PROVIDER_IMPL=%s",  address(dataProviderImpl));
        console.log("  NEW_DEBT_MANAGER_IMPL=%s",   address(debtManagerImpl));
    }
}
