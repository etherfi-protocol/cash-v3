// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { Test, console } from "forge-std/Test.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";

/// @title SettlementDispatcherV2 Bytecode Verification (Optimism)
/// @notice Deploys V2 locally with the same constructor args used on OP and compares
///         bytecode against the on-chain implementations deployed via CREATE3.
///
/// Usage:
///   forge test --match-contract SettlementDispatcherV2OPVerifyBytecode --rpc-url optimism -vv
contract SettlementDispatcherV2OPVerifyBytecode is ContractCodeChecker, Test {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Must match salts in UpgradeSettlementDispatcherV2OP.s.sol
    bytes32 constant SALT_REAP_IMPL       = keccak256("UpgradeSettlementDispatcherV2OP.ReapImpl");
    bytes32 constant SALT_RAIN_IMPL       = keccak256("UpgradeSettlementDispatcherV2OP.RainImpl");
    bytes32 constant SALT_PIX_IMPL        = keccak256("UpgradeSettlementDispatcherV2OP.PixImpl");
    bytes32 constant SALT_CARD_ORDER_IMPL = keccak256("UpgradeSettlementDispatcherV2OP.CardOrderImpl");

    // OP mainnet DataProvider — read from deployments/mainnet/10/deployments.json after full deploy
    address constant dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

    function setUp() public {
        string memory opRpc = vm.envString("OPTIMISM_RPC");
        if (bytes(opRpc).length == 0) opRpc = "https://mainnet.optimism.io";
        vm.createSelectFork(opRpc);
    }

    function test_settlementDispatcherV2Reap_verifyBytecode() public {
        address deployed = CREATE3.predictDeterministicAddress(SALT_REAP_IMPL, NICKS_FACTORY);
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Reap, dataProvider);

        console.log("-------------- SettlementDispatcherV2 Reap (OP) ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", deployed);
        verifyContractByteCodeMatch(deployed, address(impl));
    }

    function test_settlementDispatcherV2Rain_verifyBytecode() public {
        address deployed = CREATE3.predictDeterministicAddress(SALT_RAIN_IMPL, NICKS_FACTORY);
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Rain, dataProvider);

        console.log("-------------- SettlementDispatcherV2 Rain (OP) ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", deployed);
        verifyContractByteCodeMatch(deployed, address(impl));
    }

    function test_settlementDispatcherV2Pix_verifyBytecode() public {
        address deployed = CREATE3.predictDeterministicAddress(SALT_PIX_IMPL, NICKS_FACTORY);
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.PIX, dataProvider);

        console.log("-------------- SettlementDispatcherV2 PIX (OP) ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", deployed);
        verifyContractByteCodeMatch(deployed, address(impl));
    }

    function test_settlementDispatcherV2CardOrder_verifyBytecode() public {
        address deployed = CREATE3.predictDeterministicAddress(SALT_CARD_ORDER_IMPL, NICKS_FACTORY);
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.CardOrder, dataProvider);

        console.log("-------------- SettlementDispatcherV2 CardOrder (OP) ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", deployed);
        verifyContractByteCodeMatch(deployed, address(impl));
    }
}
