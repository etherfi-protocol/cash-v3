// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { VerifyRoleGatingBatch3 } from "../../scripts/role-gating-batch3/VerifyRoleGatingBatch3.s.sol";

/// @dev Shared plumbing: fork, a verifier instance, and the "is this contract live yet" probes.
///      Every check reverts on mismatch (ContractCodeChecker.requireCodeMatchAllowingAddressEmbeds),
///      unlike the log-only verifyContractByteCodeMatch.
///
///      Each test SKIPS until its contract is on the re-gated code, detected independently of the
///      deployment record: the old code still answers its per-contract role getter
///      (e.g. DATA_PROVIDER_ADMIN_ROLE()), the re-gated code does not. So the suite is green before
///      the rollout and starts enforcing on its own once the upgrade executes. Module checks skip
///      until deployments/mainnet/10/role-gating-batch3.json exists.
abstract contract RoleGatingBatch3BytecodeBase is Test {
    VerifyRoleGatingBatch3 verifier;
    string cash;
    string trading;

    function _setUp(string memory rpcEnv, string memory fallbackRpc) internal {
        // envOr alone is not enough: CI sets unset secrets to "", which must also fall back
        string memory rpc = vm.envOr(rpcEnv, string(""));
        vm.createSelectFork(bytes(rpc).length > 0 ? rpc : fallbackRpc);
        // The verifier embeds the creation code of every contract it rebuilds (~313 KB), far past the
        // EIP-170 / EIP-3860 limits that forge >= 1.8 enforces on `new` inside tests. Etch its runtime
        // code instead. That skips its constructor, which only initialises forge-std / Utils state
        // (IS_SCRIPT, chain-id strings) the checkBytecode* path never reads. Each contract it rebuilds
        // is still deployed normally, and is itself under the limit.
        verifier = VerifyRoleGatingBatch3(makeAddr("VerifyRoleGatingBatch3"));
        vm.etch(address(verifier), vm.getDeployedCode("VerifyRoleGatingBatch3.s.sol:VerifyRoleGatingBatch3"));
        // `new` grants cheatcode access automatically; etched code needs it explicitly (vm.readFile / vm.load)
        vm.allowCheatcodes(address(verifier));
        string memory dir = string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid));
        cash = vm.readFile(string.concat(dir, "/deployments.json"));
        trading = vm.readFile(string.concat(dir, "/trading-account.json"));
    }

    function _cash(string memory key) internal view returns (address) {
        return stdJson.readAddress(cash, string.concat(".addresses.", key));
    }

    function _trading(string memory key) internal view returns (address) {
        return stdJson.readAddress(trading, string.concat(".", key));
    }

    /// @dev Skip while `target` still exposes the pre-PR role getter `sig`
    function _skipWhileOld(address target, string memory sig) internal {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        vm.skip(ok && ret.length == 32);
    }

    /// @dev Skip while `registry` lacks the re-gated ADMIN_ROLE() getter
    function _skipUntilRegated(address registry) internal {
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeWithSignature("ADMIN_ROLE()"));
        vm.skip(!(ok && ret.length == 32));
    }
}

/// @title Role re-gated bytecode verification — Optimism
/// Usage: forge test --match-contract VerifyRoleGatingBatch3OPBytecode -vv
contract VerifyRoleGatingBatch3OPBytecode is RoleGatingBatch3BytecodeBase {
    function setUp() public {
        _setUp("OPTIMISM_RPC", "https://mainnet.optimism.io");
    }

    function test_verifyBytecode_CashModuleCoreAndSetters() public {
        _skipWhileOld(_cash("CashModule"), "CASH_MODULE_CONTROLLER_ROLE()");
        verifier.checkBytecodeCashModule();
    }

    function test_verifyBytecode_DebtManagerCoreAndAdmin() public {
        _skipWhileOld(_cash("DebtManager"), "DEBT_MANAGER_ADMIN_ROLE()");
        verifier.checkBytecodeDebtManager();
    }

    function test_verifyBytecode_EtherFiDataProvider() public {
        _skipWhileOld(_cash("EtherFiDataProvider"), "DATA_PROVIDER_ADMIN_ROLE()");
        verifier.checkBytecodeDataProvider();
    }

    function test_verifyBytecode_PriceProvider() public {
        _skipWhileOld(_cash("PriceProvider"), "PRICE_PROVIDER_ADMIN_ROLE()");
        verifier.checkBytecodePriceProvider();
    }

    function test_verifyBytecode_AcrossSwapModule() public {
        _skipWhileOld(_cash("AcrossSwapModule"), "ACROSS_SWAP_MODULE_ADMIN_ROLE()");
        verifier.checkBytecodeAcross();
    }

    function test_verifyBytecode_EnsoSwapModule() public {
        _skipWhileOld(_cash("EnsoSwapModule"), "ENSO_SWAP_MODULE_ADMIN_ROLE()");
        verifier.checkBytecodeEnso();
    }

    function test_verifyBytecode_LendGateway() public {
        _skipWhileOld(_cash("LendGateway"), "LEND_GATEWAY_ADMIN_ROLE()");
        verifier.checkBytecodeLendGateway();
    }

    function test_verifyBytecode_StockWithdrawModule() public {
        _skipWhileOld(_cash("StockWithdrawModule"), "STOCK_WITHDRAW_MODULE_ADMIN_ROLE()");
        verifier.checkBytecodeStockWithdrawModule();
    }

    /// @dev The replacement modules are verifiable as soon as they are deployed (before the swap)
    function test_verifyBytecode_ReplacementModules() public {
        vm.skip(!vm.exists(string.concat(vm.projectRoot(), "/deployments/mainnet/10/role-gating-batch3.json")));
        verifier.checkBytecodeModules();
    }

    function test_verifyBytecode_TradingRoleRegistry() public {
        _skipUntilRegated(_trading("RoleRegistry"));
        verifier.checkBytecodeTradingRoleRegistry();
    }

    function test_verifyBytecode_TradingDataProvider() public {
        _skipWhileOld(_trading("EtherFiDataProvider"), "DATA_PROVIDER_ADMIN_ROLE()");
        verifier.checkBytecodeTradingDataProvider();
    }
}

/// @title Role re-gated bytecode verification — Ethereum
/// Usage: forge test --match-contract VerifyRoleGatingBatch3ETHBytecode -vv
contract VerifyRoleGatingBatch3ETHBytecode is RoleGatingBatch3BytecodeBase {
    function setUp() public {
        _setUp("MAINNET_RPC", "https://ethereum-rpc.publicnode.com");
    }

    function test_verifyBytecode_StockUnwrapper() public {
        _skipWhileOld(_cash("StockUnwrapper"), "STOCK_UNWRAPPER_ADMIN_ROLE()");
        verifier.checkBytecodeStockUnwrapper();
    }

    function test_verifyBytecode_TradingRoleRegistry() public {
        _skipUntilRegated(_trading("RoleRegistry"));
        verifier.checkBytecodeTradingRoleRegistry();
    }

    function test_verifyBytecode_TradingDataProvider() public {
        _skipWhileOld(_trading("EtherFiDataProvider"), "DATA_PROVIDER_ADMIN_ROLE()");
        verifier.checkBytecodeTradingDataProvider();
    }

    function test_verifyBytecode_TradingPriceProvider() public {
        _skipWhileOld(_trading("PriceProvider"), "PRICE_PROVIDER_ADMIN_ROLE()");
        verifier.checkBytecodePriceProvider();
    }

    function test_verifyBytecode_AcrossSwapModule() public {
        _skipWhileOld(_trading("AcrossSwapModule"), "ACROSS_SWAP_MODULE_ADMIN_ROLE()");
        verifier.checkBytecodeAcross();
    }

    function test_verifyBytecode_EnsoSwapModule() public {
        _skipWhileOld(_trading("EnsoSwapModule"), "ENSO_SWAP_MODULE_ADMIN_ROLE()");
        verifier.checkBytecodeEnso();
    }

    function test_verifyBytecode_TradingLens() public {
        _skipWhileOld(_trading("TradingLens"), "TRADING_LENS_ADMIN_ROLE()");
        verifier.checkBytecodeTradingLens();
    }
}
