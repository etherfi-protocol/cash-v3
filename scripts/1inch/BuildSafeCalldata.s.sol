// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title 1inch — Build Gnosis Safe tx bundle
 * @notice Emits the on-chain bundle for the 1inch integration, executed by the operating safe
 *         (RoleRegistry owner / beacon owner / DataProvider admin). Run AFTER `Deploy.s.sol`.
 *
 *         The bundle contains, in order:
 *           1. EtherFiDataProvider(proxy).upgradeToAndCall(newDataProviderImpl, "")
 *              — adds get/setOneInchSwapModule. MUST precede tx 7 (setOneInchSwapModule selector
 *                does not exist on the live impl until this lands).
 *           2. DebtManager(proxy).upgradeToAndCall(newDebtManagerImpl, "")
 *           3. EtherFiSafeFactory.upgradeBeaconImplementation(newSafeImpl)
 *              — points all EtherFiSafes at the new implementation with the tightened ERC-1271
 *           4. EtherFiDataProvider.configureModules([oneInchModule], [true])
 *              — whitelists the module so Safes can install it
 *           5. EtherFiDataProvider.configureDefaultModules([oneInchModule], [true])
 *              — installs it as a default module on every Safe (mirrors the dev rollout). DROP
 *                this tx if 1inch should be opt-in per Safe rather than installed on all.
 *           6. CashModule.configureModulesCanRequestWithdraw([oneInchModule], [true])
 *              — authorises the module to call `requestWithdrawalByModule`
 *           7. EtherFiDataProvider.setOneInchSwapModule(oneInchModule)
 *              — binds the module into EtherFiSafe.isValidSignature (CRITICAL: until this lands,
 *                fills will fail at ERC-1271)
 *           8. RoleRegistry.grantRole(ONEINCH_SWAP_REQUEST_ROLE, BE_KEEPER)
 *              — authorises the BE keeper EOA to call `requestSwap(...)`. Mandatory: every
 *                `requestSwap` call gates on this role.
 *           9. RoleRegistry.grantRole(ONEINCH_SWAP_CANCEL_ROLE, BE_KEEPER)
 *              — authorises the same EOA to call `cancelSwap(safe, [], [])` without an
 *                owner-quorum sig.
 *
 *         ⚠ `BE_KEEPER` is a PLACEHOLDER (0xCA9CE100…). REPLACE with the real BE EOA before
 *         signing — without the request-role grant, `requestSwap` is bricked on the live module.
 *
 *         Usage:
 *           ENV=mainnet ONE_INCH_MODULE_PROXY=0x... NEW_SAFE_IMPL=0x... \
 *             NEW_DATA_PROVIDER_IMPL=0x... NEW_DEBT_MANAGER_IMPL=0x... \
 *             forge script scripts/1inch/BuildSafeCalldata.s.sol --rpc-url <optimism_rpc>
 *
 *         Output: ./output/BuildSafeCalldata1inch.json (Safe tx builder format)
 */
contract BuildSafeCalldata1inch is GnosisHelpers, Utils {
    /// Cash operating safe (DATA_PROVIDER_ADMIN_ROLE holder, RoleRegistry owner)
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// ⚠ PLACEHOLDER — replace with the real BE keeper EOA before signing this bundle.
    /// Holds both `ONEINCH_SWAP_REQUEST_ROLE` and `ONEINCH_SWAP_CANCEL_ROLE`. Use separate
    /// constants if you want different EOAs per role.
    address constant BE_KEEPER = 0xCA9cE100Ca9Ce100Ca9ce100cA9CE100ca9Ce100;

    struct Addrs {
        address oneInchModule;
        address newSafeImpl;
        address newDataProviderImpl;
        address newDebtManagerImpl;
        address dataProvider;
        address safeFactory;
        address cashModule;
        address debtManager;
        address roleRegistry;
    }

    function _readAddrs() internal view returns (Addrs memory a) {
        string memory d = readDeploymentFile();
        a.oneInchModule      = vm.envAddress("ONE_INCH_MODULE_PROXY");
        a.newSafeImpl        = vm.envAddress("NEW_SAFE_IMPL");
        a.newDataProviderImpl= vm.envAddress("NEW_DATA_PROVIDER_IMPL");
        a.newDebtManagerImpl = vm.envAddress("NEW_DEBT_MANAGER_IMPL");
        a.dataProvider       = stdJson.readAddress(d, ".addresses.EtherFiDataProvider");
        a.safeFactory        = stdJson.readAddress(d, ".addresses.EtherFiSafeFactory");
        a.cashModule         = stdJson.readAddress(d, ".addresses.CashModule");
        a.debtManager        = stdJson.readAddress(d, ".addresses.DebtManager");
        a.roleRegistry       = stdJson.readAddress(d, ".addresses.RoleRegistry");
    }

    function _buildBundle(Addrs memory a, string memory chainId) internal pure returns (string memory) {
        address[] memory modules = new address[](1);
        modules[0] = a.oneInchModule;
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        // keccak256("ONEINCH_SWAP_REQUEST_ROLE") — mirrors OneInchSwapModule.ONEINCH_SWAP_REQUEST_ROLE
        bytes32 requestRole = 0x601574078c2fa21841ec131b800e87c9cafa29f936d1aeb40ca456efa550d668;
        // keccak256("ONEINCH_SWAP_CANCEL_ROLE")  — mirrors OneInchSwapModule.ONEINCH_SWAP_CANCEL_ROLE
        bytes32 cancelRole  = 0xa9ce2bf1c42d4065626ccf229669805407f00ce0f190f535062f67a4e110894c;

        string memory txs = _getGnosisHeader(chainId, addressToHex(OPERATING_SAFE));
        // --- privileged proxy upgrades (RoleRegistry owner) ---
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.dataProvider), iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, a.newDataProviderImpl, "")),                "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.debtManager),  iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, a.newDebtManagerImpl, "")),                 "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.safeFactory),  iToHex(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, a.newSafeImpl)),                   "0", false)));
        // --- module wiring (DataProvider admin / CashModule admin) ---
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.dataProvider), iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, modules, yes)),                         "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.dataProvider), iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, yes)),                  "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.cashModule),   iToHex(abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, modules, yes)),              "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.dataProvider), iToHex(abi.encodeWithSelector(EtherFiDataProvider.setOneInchSwapModule.selector, a.oneInchModule)),                  "0", false)));
        // --- role grants (RoleRegistry owner) ---
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.roleRegistry), iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, requestRole, BE_KEEPER)),                            "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(a.roleRegistry), iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, cancelRole,  BE_KEEPER)),                            "0", true)));
        return txs;
    }

    function run() public {
        Addrs memory a = _readAddrs();
        string memory txs = _buildBundle(a, vm.toString(block.chainid));

        vm.createDir("./output", true);
        string memory path = "./output/BuildSafeCalldata1inch.json";
        vm.writeFile(path, txs);

        console.log("Gnosis tx bundle written to:", path);
        console.log("Operating safe     :", OPERATING_SAFE);
        console.log("EtherFiSafeFactory :", a.safeFactory);
        console.log("EtherFiDataProvider:", a.dataProvider);
        console.log("DebtManager        :", a.debtManager);
        console.log("CashModule         :", a.cashModule);
        console.log("1inch module       :", a.oneInchModule);
        console.log("New Safe impl      :", a.newSafeImpl);
        console.log("New DataProvider   :", a.newDataProviderImpl);
        console.log("New DebtManager    :", a.newDebtManagerImpl);

        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }
}
