// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { AaveV4Lens } from "../../src/lens/AaveV4Lens.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendProdConfig } from "./CashLendProdConfig.sol";

/**
 * @title VerifyCashLendProdBytecode
 * @notice Bytecode verification for every contract DeployCashLendProd broadcast. VerifyCashLendProd
 *         proves each address is the CREATE3-predicted one — i.e. WHO deployed it (only a registered
 *         EtherFiDeployer account could). CREATE3 addresses do not commit to initcode, so it cannot
 *         prove WHAT was deployed: a broadcast from a stale branch or submodule would pass every
 *         address check. This script closes that gap the same way the module bytecode tests do
 *         (test/safe/modules/frax/FraxVerifyBytecode.t.sol and friends): redeploy each contract
 *         locally from CURRENT source with the SAME chain-mirrored constructor args the deploy
 *         script used, and compare runtime bytecode against the on-chain deployment.
 *
 * @dev Two deviations from the plain ContractCodeChecker pattern, both because the plain form
 *      cannot gate this deployment:
 *
 *      1. Every comparison is followed by a require. verifyContractByteCodeMatch only console.logs
 *         Success/Fail (it reverts on nothing but empty code and post-trim length mismatch), and a
 *         verification script must revert on failure so the exit code can be trusted.
 *
 *      2. The 13 UUPS implementations cannot pass a plain byte compare AT ALL: each embeds its own
 *         deploy address (OZ UUPSUpgradeable's `__self` immutable), and CashModuleCore /
 *         CashModuleSetters / CashLens / LendGateway additionally embed linked library addresses
 *         (CashLendLib, LendSourcingLib, CashLensLegacyLib, LendCapacityLib) that differ between
 *         the broadcast and the local simulation — so a CORRECT deployment logs "Fail". For these,
 *         _requireCodeMatch demands byte-equality (metadata included) except in 20-byte windows
 *         forming a consistent local→on-chain address binding where the local address holds code
 *         (which pins window alignment). Non-self bindings are the linked libraries, and each one's
 *         bytecode is verified recursively under the same rules.
 *
 *      The 7 replacement modules, the EtherFiSafe beacon impl and the two UUPSProxies have no
 *      self-embeds and no libraries — their immutables bake to the constructor args — so they go
 *      through the standard verifyContractByteCodeMatch path (plus the require gate).
 *
 * Usage (read-only, any time after the EOA broadcast; does not need the Safe bundle executed):
 *   source .env && ENV=mainnet forge script scripts/lend/VerifyCashLendProdBytecode.s.sol:VerifyCashLendProdBytecode \
 *     --rpc-url $OPTIMISM_RPC -vv
 */
contract VerifyCashLendProdBytecode is Utils, ContractCodeChecker, CashLendProdConfig {
    /// @dev local address => on-chain address bindings discovered for the contract being compared.
    address[] private bindingLocal;
    address[] private bindingOnchain;

    function run() public virtual {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        string memory json = readDeploymentFile();
        address cashModule = _addr(json, "CashModule");
        address dataProvider = _addr(json, "EtherFiDataProvider");
        address debtManager = _addr(json, "DebtManager");
        address spoke = stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/summer-lend.json")), ".spoke");
        address weth = _fixtureAsset("weth");

        // ── UUPS implementations: self-address (and library) bindings, see @dev ──
        _checkWithBindings("CashModuleCoreImpl", address(new CashModuleCore(dataProvider)));
        _checkWithBindings("CashModuleSettersImpl", address(new CashModuleSetters(dataProvider)));
        _checkWithBindings("CashLensImpl", address(new CashLens(cashModule, dataProvider)));
        _checkWithBindings("CashEventEmitterImpl", address(new CashEventEmitter(cashModule)));
        _checkWithBindings("DebtManagerCoreImpl", address(new DebtManagerCore(dataProvider)));
        _checkWithBindings("DebtManagerAdminImpl", address(new DebtManagerAdmin(dataProvider)));
        _checkWithBindings("EtherFiHookImpl", address(new EtherFiHook(dataProvider)));
        _checkWithBindings("TopUpDestImpl", address(new TopUpDest(dataProvider, weth)));
        _checkWithBindings("LiquifierImpl", address(new LiquidUSDLiquifierOPModule(debtManager, dataProvider)));
        _checkWithBindings("EnsoImpl", address(new EnsoSwapModule(dataProvider)));
        _checkWithBindings("AcrossImpl", address(new AcrossSwapModule(dataProvider)));
        _checkWithBindings("LendGatewayImpl", address(new LendGateway(dataProvider, spoke)));
        _checkWithBindings("AaveV4LensImpl", address(new AaveV4Lens()));

        // ── Beacon impl and proxies: no self-embeds, standard pattern applies ──
        _checkStandard("EtherFiSafeImpl", address(new EtherFiSafe(dataProvider)));
        _checkStandard("LendGatewayProxy", address(new UUPSProxy(_predicted("LendGatewayImpl"), "")));
        _checkStandard("AaveV4LensProxy", address(new UUPSProxy(_predicted("AaveV4LensImpl"), "")));

        // ── Replacement modules (constructor args mirrored from the live old modules, exactly
        //    as the deploy script built them): standard pattern ──
        _checkModules(json, dataProvider);

        console.log("All bytecode checks passed");
    }

    function _checkModules(string memory json, address dataProvider) internal {
        string[7] memory oldKeys = _oldModuleKeys();
        address[7] memory old;
        for (uint256 i = 0; i < 7; ++i) {
            old[i] = _addr(json, oldKeys[i]);
        }

        _checkStandard("OpenOceanModule", address(new OpenOceanSwapModule(OpenOceanSwapModule(old[0]).swapRouter(), dataProvider)));
        _checkStandard("LiquidModule", _localLiquid(old[1], dataProvider, false));
        _checkStandard("LiquidReferrerModule", _localLiquid(old[2], dataProvider, true));
        _checkStandard("FraxModule", address(new FraxModule(dataProvider, FraxModule(old[3]).fraxusd(), FraxModule(old[3]).custodian(), FraxModule(old[3]).remoteHop())));
        _checkStandard("StakeModule", address(new EtherFiStakeModule(dataProvider, address(EtherFiStakeModule(old[4]).syncPool()), EtherFiStakeModule(old[4]).weth(), EtherFiStakeModule(old[4]).weETH())));
        _checkStandard("MidasModule", _localMidas(old[5], dataProvider));
        _checkStandard("BeHYPEModule", address(new BeHYPEStakeModule(dataProvider, address(BeHYPEStakeModule(old[6]).staker()), BeHYPEStakeModule(old[6]).whype(), BeHYPEStakeModule(old[6]).beHYPE(), BeHYPEStakeModule(old[6]).getRefundGasLimit())));
    }

    function _localLiquid(address old, address dataProvider, bool referrer) internal returns (address) {
        (address[] memory assets, address[] memory tellers) = _liquidConfig(EtherFiLiquidModule(old));
        address wethAddr = EtherFiLiquidModule(old).weth();
        if (referrer) return address(new EtherFiLiquidModuleWithReferrer(assets, tellers, dataProvider, wethAddr));
        return address(new EtherFiLiquidModule(assets, tellers, dataProvider, wethAddr));
    }

    function _localMidas(address old, address dataProvider) internal returns (address) {
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasConfig(MidasModule(old));
        return address(new MidasModule(dataProvider, tokens, deposits, redemptions));
    }

    // ─────────────────────────────── comparisons ───────────────────────────────

    /// @dev The repo-standard ContractCodeChecker comparison (same as the module bytecode tests),
    ///      followed by the require gate a verification script needs.
    function _checkStandard(string memory saltName, address local) internal {
        address onchain = _predicted(saltName);
        require(onchain.code.length != 0, string.concat(saltName, " not deployed on-chain"));
        console.log(string.concat("-------------- ", saltName, " ----------------"));
        verifyContractByteCodeMatch(onchain, local);
        require(keccak256(onchain.code) == keccak256(local.code), string.concat(saltName, ": bytecode mismatch - source drift since broadcast"));
        console.log(string.concat("  [OK] ", saltName), onchain);
    }

    function _checkWithBindings(string memory saltName, address local) internal {
        address onchain = _predicted(saltName);
        require(onchain.code.length != 0, string.concat(saltName, " not deployed on-chain"));
        _requireCodeMatch(saltName, onchain, local);
        console.log(string.concat("  [OK] ", saltName), onchain);
    }

    /**
     * @dev Requires local.code == onchain.code byte-for-byte, except 20-byte windows forming a
     *      consistent (localAddr => onchainAddr) binding where localAddr holds code in the
     *      simulation. The code-bearing requirement pins the window alignment: sliding the window
     *      off a real PUSH20 operand yields a garbage address with no code. Discovered non-self
     *      bindings are linked libraries and are verified recursively (a library embeds its own
     *      deploy address for the DELEGATECALL guard, which resolves to its self-binding here).
     */
    function _requireCodeMatch(string memory label, address onchain, address local) internal {
        bytes memory oc = onchain.code;
        bytes memory lc = local.code;
        require(oc.length != 0 && lc.length != 0, string.concat(label, ": empty bytecode"));
        require(oc.length == lc.length, string.concat(label, ": bytecode length mismatch - source drift since broadcast"));

        delete bindingLocal;
        delete bindingOnchain;

        uint256 i;
        while (i < lc.length) {
            if (lc[i] == oc[i]) {
                ++i;
                continue;
            }
            i = _consumeBindingWindow(label, lc, oc, i);
        }

        // Snapshot before recursion — the recursive call reuses the shared binding arrays.
        address[] memory locals = bindingLocal;
        address[] memory onchains = bindingOnchain;
        for (uint256 j = 0; j < locals.length; ++j) {
            if (locals[j] == local) {
                require(onchains[j] == onchain, string.concat(label, ": self-address binding mismatch"));
            } else {
                _requireCodeMatch(string.concat(label, ".lib(", vm.toString(locals[j]), ")"), onchains[j], locals[j]);
            }
        }
    }

    /// @dev Interprets the mismatch at index `i` as part of a 20-byte embedded address. Scans the
    ///      candidate window starts (the address must begin at or up to 19 bytes before `i`, since
    ///      every byte before `i` matched) and accepts the first alignment whose local 20 bytes are
    ///      a code-bearing address with a consistent binding. Returns the index after the window.
    function _consumeBindingWindow(string memory label, bytes memory lc, bytes memory oc, uint256 i) private returns (uint256) {
        uint256 sMin = i >= 19 ? i - 19 : 0;
        for (uint256 s = i + 1; s > sMin;) {
            --s;
            if (s + 20 > lc.length) continue;
            address la = _addrAt(lc, s);
            if (la == address(0) || la.code.length == 0) continue;
            address oa = _addrAt(oc, s);
            (bool known, address expected) = _binding(la);
            if (known && expected != oa) continue;
            if (!known) {
                bindingLocal.push(la);
                bindingOnchain.push(oa);
            }
            return s + 20;
        }
        revert(string.concat(label, ": unexplained bytecode mismatch at byte ", vm.toString(i), " - source drift since broadcast"));
    }

    function _binding(address localAddr) private view returns (bool, address) {
        for (uint256 j = 0; j < bindingLocal.length; ++j) {
            if (bindingLocal[j] == localAddr) return (true, bindingOnchain[j]);
        }
        return (false, address(0));
    }

    function _addrAt(bytes memory code, uint256 offset) private pure returns (address) {
        uint256 value;
        for (uint256 k = 0; k < 20; ++k) {
            value = (value << 8) | uint8(code[offset + k]);
        }
        return address(uint160(value));
    }

    function _addr(string memory json, string memory name) internal pure returns (address) {
        return stdJson.readAddress(json, string.concat(".addresses.", name));
    }

    /// @dev Utils.getChainConfig parses fixture keys chain 10 doesn't have, so read directly.
    function _fixtureAsset(string memory key) internal view returns (address) {
        string memory fixtures = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/fixtures/fixtures.json"));
        return stdJson.readAddress(fixtures, string.concat(".", vm.toString(block.chainid), ".", key));
    }
}
