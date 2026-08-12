// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { VerifyCashLendProdBytecode } from "./VerifyCashLendProdBytecode.s.sol";

/**
 * @title VerifyCashRepayFixProdBytecode
 * @notice Bytecode verification for the two implementations DeployCashRepayFixProd broadcast.
 *         Same guarantee split as the launch verifier it inherits: the CREATE3 address proves WHO
 *         deployed (only a registered EtherFiDeployer account), this proves WHAT was deployed —
 *         each on-chain implementation byte-matches current source, and the linked libraries
 *         (CashLendLib with the repay fix, LendSourcingLib) are verified recursively through the
 *         inherited address-binding comparison.
 *
 * Usage (read-only; run before signing the Safe bundle and again after execution):
 *   source .env && ENV=mainnet forge script scripts/lend/VerifyCashRepayFixProdBytecode.s.sol:VerifyCashRepayFixProdBytecode \
 *     --rpc-url $OPTIMISM_RPC -vv
 */
contract VerifyCashRepayFixProdBytecode is VerifyCashLendProdBytecode {
    function run() public override {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        string memory json = readDeploymentFile();
        address cashModule = _addr(json, "CashModule");
        address dataProvider = _addr(json, "EtherFiDataProvider");

        _checkWithBindings("CashModuleCoreImplV2", address(new CashModuleCore(dataProvider)));
        _checkWithBindings("CashModuleSettersImplV2", address(new CashModuleSetters(dataProvider)));

        address core = _predicted("CashModuleCoreImplV2");
        address setters = _predicted("CashModuleSettersImplV2");
        if (address(uint160(uint256(vm.load(cashModule, EIP1967_IMPLEMENTATION_SLOT)))) == core) {
            require(CashModuleCore(cashModule).getCashModuleSetters() == setters, "setters pointer mismatch");
            console.log("Bundle executed: CashModule runs the repay-fix implementations");
        } else {
            console.log("Bundle NOT yet executed: CashModule still on the previous implementation");
        }
        console.log("All bytecode checks passed");
    }
}
