// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";

/// @title LiquidUSDLiquifierOPModule Bytecode Verification
/// @notice Deploys LiquidUSDLiquifierOPModule locally with the same constructor args used on OP
///         and compares bytecode against the on-chain CREATE3 implementation.
///
/// Usage:
///   forge test --match-contract LiquidUSDLiquifierOPVerifyBytecode --rpc-url optimism -vv
contract LiquidUSDLiquifierOPVerifyBytecode is ContractCodeChecker, Test {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Must match salt in UpgradeLiquidUSDLiquifierOP.s.sol
    bytes32 constant SALT_IMPL = keccak256("UpgradeLiquidUSDLiquifierOP.Impl");

    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant DEBT_MANAGER  = 0x0078C5a459132e279056B2371fE8A8eC973A9553;

    function setUp() public {
        string memory opRpc = vm.envString("OPTIMISM_RPC");
        if (bytes(opRpc).length == 0) opRpc = "https://mainnet.optimism.io";
        vm.createSelectFork(opRpc);
    }

    function test_liquidUSDLiquifierOPModule_verifyBytecode() public {
        address deployed = CREATE3.predictDeterministicAddress(SALT_IMPL, NICKS_FACTORY);
        LiquidUSDLiquifierOPModule localImpl = new LiquidUSDLiquifierOPModule(DEBT_MANAGER, DATA_PROVIDER);

        console.log("-------------- LiquidUSDLiquifierOPModule ----------------");
        emit log_named_address("New deploy", address(localImpl));
        emit log_named_address("Verifying contract", deployed);
        verifyContractByteCodeMatch(deployed, address(localImpl));
    }
}
