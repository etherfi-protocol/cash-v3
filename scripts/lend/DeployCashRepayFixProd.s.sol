// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendProdConfig } from "./CashLendProdConfig.sol";

/**
 * @title DeployCashRepayFixProd
 * @notice Ships the full-repay rounding fix (PR #261) to Optimism prod. CashLendLib changed, and it
 *         is a linked library, so CashModuleCore and CashModuleSetters get fresh implementations
 *         relinked against the fixed library (forge deploys and links the libraries automatically
 *         during the broadcast). Same two-actor flow as DeployCashLendProd:
 *
 *         1. The deployer EOA broadcasts the two unprivileged CREATE3 implementation deployments
 *            through EtherFiDeployer (salts `CashLendProd.CashModuleCoreImplV2` /
 *            `CashLendProd.CashModuleSettersImplV2`; the launch salts are occupied).
 *         2. The two privileged calls (proxy upgrade + setters pointer) are written to
 *            output/CashRepayFixProd-10.json for the OperatingSafe. The script simulates the
 *            bundle on the fork and asserts the end state before finishing.
 *
 * Usage (drop --broadcast to simulate; sender comes from CLI wallet flags):
 *   source .env && ENV=mainnet forge script scripts/lend/DeployCashRepayFixProd.s.sol:DeployCashRepayFixProd \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 *
 * Before signing the Safe bundle (and again after execution):
 *   source .env && ENV=mainnet forge script scripts/lend/VerifyCashRepayFixProdBytecode.s.sol:VerifyCashRepayFixProdBytecode \
 *     --rpc-url $OPTIMISM_RPC -vv
 */
contract DeployCashRepayFixProd is Utils, GnosisHelpers, CashLendProdConfig {
    string internal constant CORE_NAME = "CashModuleCoreImplV2";
    string internal constant SETTERS_NAME = "CashModuleSettersImplV2";

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        string memory json = readDeploymentFile();
        address cashModule = stdJson.readAddress(json, ".addresses.CashModule");
        address dataProvider = stdJson.readAddress(json, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(json, ".addresses.RoleRegistry");
        require(RoleRegistry(roleRegistry).owner() == SAFE, "RoleRegistry owner is not the prod Safe");
        _requireDeployer(msg.sender);

        // ── 1. Deployer EOA: unprivileged CREATE3 deployments only ──
        vm.startBroadcast();
        address core = _create3(CORE_NAME, abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(dataProvider)));
        address setters = _create3(SETTERS_NAME, abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(dataProvider)));
        vm.stopBroadcast();

        // ── 2. Build the Gnosis bundle ──
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(cashModule), iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, core, "")), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(cashModule), iToHex(abi.encodeWithSelector(ICashModule.setCashModuleSettersAddress.selector, setters)), "0", true));
        string memory path = string.concat("./output/CashRepayFixProd-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);

        if (_implementationOf(cashModule) == core) {
            console.log("Bundle already executed on-chain; nothing left to simulate.");
            return;
        }

        // ── 3. Simulate the bundle as the Safe and assert the end state ──
        address gatewayBefore = address(ICashModule(cashModule).getLendGateway());
        executeGnosisTransactionBundle(path);
        require(_implementationOf(cashModule) == core, "CashModule impl mismatch");
        require(CashModuleCore(cashModule).getCashModuleSetters() == setters, "CashModule setters mismatch");
        // Upgrade must swap code only: spot-check that storage reads the same through the new impl.
        require(address(ICashModule(cashModule).getLendGateway()) == gatewayBefore, "lend gateway drifted across the upgrade");
        // A tx injected into the bundle could hand over governance; this must be the last check.
        require(RoleRegistry(roleRegistry).owner() == SAFE, "CRITICAL: RoleRegistry owner changed");

        _writeDeploymentRecord(core, setters);

        console.log("");
        console.log("=== Deployed (EOA, CREATE3) ===");
        console.log("CashModuleCore impl (V2):    ", core);
        console.log("CashModuleSetters impl (V2): ", setters);
        console.log("");
        console.log("Gnosis bundle (2 txs):", path);
    }

    /// @dev Fails before any broadcast if the deployer isn't the recorded one, isn't live on this
    ///      chain, or hasn't authorised the broadcaster (same guarantee as DeployCashLendProd).
    function _requireDeployer(address broadcaster) internal view {
        address recorded = stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer");
        require(recorded == ETHERFI_DEPLOYER, "ETHERFI_DEPLOYER does not match deployments/deployer/etherfi-deployer.json");
        require(ETHERFI_DEPLOYER.code.length != 0, "EtherFiDeployer not deployed on this chain");
        require(EtherFiDeployer(ETHERFI_DEPLOYER).isDeployer(broadcaster), "broadcaster is not a registered EtherFiDeployer deployer; owner must call configureDeployers first");
    }

    /// @dev Idempotent CREATE3 through the protocol's permissioned deployer; see DeployCashLendProd._create3
    ///      for why a public factory is not an option. The skip branch is safe because only registered
    ///      deployers can ever place code at these addresses.
    function _create3(string memory name, bytes memory creationCode) internal returns (address deployed) {
        deployed = _predicted(name);

        if (deployed.code.length > 0) {
            console.log("  [SKIP]", name, "already deployed at", deployed);
            return deployed;
        }

        address actual = EtherFiDeployer(ETHERFI_DEPLOYER).deploy(_salt(name), creationCode);
        require(actual == deployed, string.concat("CREATE3 address mismatch: ", name));
        require(deployed.code.length > 0, string.concat("CREATE3 verification failed: ", name));
        console.log(string.concat("  ", name, ":"), deployed);
    }

    /// @dev Keeps deployments/mainnet/10/cash-lend.json pointing at the implementations that are
    ///      live once the Safe executes the bundle.
    function _writeDeploymentRecord(address core, address setters) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            console.log("Dry run, not writing deployment record");
            return;
        }
        string memory path = string.concat(vm.projectRoot(), "/deployments/mainnet/10/cash-lend.json");
        vm.writeJson(string.concat("\"", vm.toString(core), "\""), path, ".cashModuleCoreImpl");
        vm.writeJson(string.concat("\"", vm.toString(setters), "\""), path, ".cashModuleSettersImpl");
        console.log("Deployment record updated:", path);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }
}
