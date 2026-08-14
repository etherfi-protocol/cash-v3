// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";

/**
 * @title VerifyStockWithdrawBytecode
 * @author ether.fi
 * @notice Proves the code actually running at the stock-withdraw addresses is the code in THIS
 *         repo at THIS commit — independently of any block explorer. Reverts on mismatch, so it
 *         can gate a rollout. The topup direction's adapter has its own script,
 *         scripts/stock-topup/VerifyStockTopupBytecode.s.sol.
 *
 *         CREATE3 addresses prove WHO deployed (only a registered EtherFiDeployer account could)
 *         but not WHAT: they do not commit to initcode, so a broadcast from a stale branch passes
 *         every address check. This closes that gap the repo-standard way — redeploy each
 *         contract locally from current source with the same constructor args and compare runtime
 *         bytecode through `ContractCodeChecker`.
 *
 *         Chain-switched, because the halves live on different chains. Run it on both:
 *           forge script scripts/stock-withdraw/VerifyStockWithdrawBytecode.s.sol --rpc-url $OPTIMISM_RPC -vv
 *           forge script scripts/stock-withdraw/VerifyStockWithdrawBytecode.s.sol --rpc-url $MAINNET_RPC -vv
 *
 *         Env: ENV (dev|mainnet) — selects the salts and the deployments file, so the same script
 *         verifies either environment.
 *
 * @dev THE IMPLEMENTATIONS CANNOT PASS A PLAIN BYTE COMPARE. `StockWithdrawModule` and
 *      `StockUnwrapper` are OZ `UUPSUpgradeable`, which embeds the implementation's own deploy
 *      address (`__self`) in runtime code, so a CORRECT deployment differs from a local redeploy
 *      in that one 20-byte window. They therefore go through
 *      `requireCodeMatchAllowingAddressEmbeds`, which demands byte equality everywhere except
 *      consistent address bindings. The proxies and the stateless bridge adapter embed nothing
 *      and use `requireExactCodeMatch`.
 *
 * @dev `type(C).runtimeCode` is deliberately not used anywhere here: Solidity refuses it for any
 *      contract with immutables, and `StockWithdrawModule` has two (`etherFiDataProvider`, plus
 *      `cashModule` derived from it in the constructor). Redeploying locally is also the stronger
 *      check, because immutables bake INTO runtime code — it proves the live impl was constructed
 *      with OUR DataProvider, not merely that it shares source with ours.
 *
 * @dev What this does NOT cover: proxy state. Bytecode equality on an ERC-1967 proxy says nothing
 *      about which implementation its slot points at, so the impl slot is re-read and cross-checked
 *      against the impl verified here. Full config verification (routes, token set, gas limits,
 *      wiring) stays in VerifyStockWithdrawModule / VerifyStockUnwrapper / VerifyStockTopup.
 */
contract VerifyStockWithdrawBytecode is StockWithdrawConfig, ContractCodeChecker {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() public {
        if (block.chainid == 10) _verifyOptimism();
        else if (block.chainid == 1) _verifyEthereum();
        else revert("VerifyStockWithdrawBytecode: run on Optimism (10) or Ethereum (1)");

        console.log("");
        console.log("VerifyStockWithdrawBytecode: all bytecode checks passed");
    }

    // ── Optimism: StockWithdrawModule impl + proxy ────────────────────────────────

    function _verifyOptimism() internal {
        string memory deployments = readDeploymentFile();
        EtherFiDataProvider dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));

        address impl = _predictAddress(_moduleImplSalt());
        address proxy = _predictAddress(_moduleProxySalt());

        console.log("Chain: Optimism   ENV:", getEnv());
        console.log("  StockWithdrawModule impl: ", impl);
        console.log("  StockWithdrawModule proxy:", proxy);
        console.log("  constructor arg (DataProvider):", address(dataProvider));

        // Same constructor argument the deploy script uses: if the live impl was built against a
        // different DataProvider its baked-in immutables differ and the compare fails.
        address localImpl = address(new StockWithdrawModule(address(dataProvider)));
        requireCodeMatchAllowingAddressEmbeds("StockWithdrawModuleImpl", impl, localImpl);

        // The proxy's runtime code is argument-independent (the implementation lives in storage,
        // not in code), so an empty-init local copy is the right reference and runs no
        // initializer of its own.
        requireExactCodeMatch("StockWithdrawModuleProxy", proxy, address(new UUPSProxy(localImpl, "")));

        _assertImplSlot("StockWithdrawModule", proxy, impl);

        // The immutables are why the impl comparison is meaningful — read them back through the
        // proxy so the log records what was actually verified.
        StockWithdrawModule module = StockWithdrawModule(payable(proxy));
        require(address(module.etherFiDataProvider()) == address(dataProvider), "module etherFiDataProvider != deployments DataProvider");
        require(address(module.cashModule()) == dataProvider.getCashModule(), "module cashModule != DataProvider.getCashModule()");
        console.log("  [OK] immutables verified: etherFiDataProvider + cashModule");
    }

    // ── Ethereum: StockUnwrapper impl + proxy, and the topup bridge adapter ───────

    function _verifyEthereum() internal {
        address impl = _predictAddress(_unwrapperImplSalt());
        address proxy = _predictAddress(_unwrapperProxySalt());

        console.log("Chain: Ethereum   ENV:", getEnv());
        console.log("  StockUnwrapper impl: ", impl);
        console.log("  StockUnwrapper proxy:", proxy);

        address localImpl = address(new StockUnwrapper());
        requireCodeMatchAllowingAddressEmbeds("StockUnwrapperImpl", impl, localImpl);
        requireExactCodeMatch("StockUnwrapperProxy", proxy, address(new UUPSProxy(localImpl, "")));
        _assertImplSlot("StockUnwrapper", proxy, impl);

        console.log("");
        console.log("  The topup direction's StockOFTBridgeAdapter lives on this chain too, but its");
        console.log("  bytecode check is scripts/stock-topup/VerifyStockTopupBytecode.s.sol (that");
        console.log("  script inherits StockTopupConfig, which cannot be combined with this one).");
    }

    /// @dev An ERC-1967 proxy with correct bytecode can still delegate anywhere; pin the slot.
    function _assertImplSlot(string memory name, address proxy, address expectedImpl) internal view {
        address actual = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actual == expectedImpl, string.concat(name, ": proxy impl slot does not point at the verified impl - possible hijack"));
        console.log(string.concat("  [OK] ", name, " proxy impl slot -> verified impl"));
    }
}
