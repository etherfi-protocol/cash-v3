// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { TopUpConfigHelper } from "../../scripts/utils/TopUpConfigHelper.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";

/// @title HyperEVM TopUp Config Verification
/// @notice Verifies that the on-chain TopUpFactory token configs on HyperEVM
///         match the expected values from the top-up-fixtures.json file.
///
/// Usage:
///   forge test --match-contract VerifyTopUpConfigHyperEVM -vv
contract VerifyTopUpConfigHyperEVM is TopUpConfigHelper, Test {
    string deployments;

    function setUp() public {
        vm.createSelectFork("https://rpc.hyperliquid.xyz/evm");

        deployments = readDeploymentFile();
        topUpFactory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        _loadAdapters(deployments);
    }

    function test_allTokenConfigsMatchFixture() public view {
        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory expectedConfigs) = parseAllTokenConfigs();
        for (uint256 i = 0; i < tokens.length; i++) {
            TopUpFactory.TokenConfig memory actual = topUpFactory.getTokenConfig(tokens[i], chainIds[i]);
            string memory label = string.concat(vm.toString(tokens[i]), " -> chain ", vm.toString(chainIds[i]));
            assertEq(actual.bridgeAdapter, expectedConfigs[i].bridgeAdapter, string.concat("bridgeAdapter mismatch: ", label));
            assertEq(actual.recipientOnDestChain, expectedConfigs[i].recipientOnDestChain, string.concat("recipient mismatch: ", label));
            assertEq(uint256(actual.maxSlippageInBps), uint256(expectedConfigs[i].maxSlippageInBps), string.concat("maxSlippage mismatch: ", label));
            assertEq(keccak256(actual.additionalData), keccak256(expectedConfigs[i].additionalData), string.concat("additionalData mismatch: ", label));
        }
        console.log("Verified", tokens.length, "token configs against fixture");
    }

    function test_allTokenConfigsHaveNonZeroAdapter() public view {
        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory expectedConfigs) = parseAllTokenConfigs();
        for (uint256 i = 0; i < tokens.length; i++) {
            TopUpFactory.TokenConfig memory actual = topUpFactory.getTokenConfig(tokens[i], chainIds[i]);
            string memory label = string.concat(vm.toString(tokens[i]), " -> chain ", vm.toString(chainIds[i]));
            assertTrue(actual.bridgeAdapter != address(0), string.concat("zero adapter: ", label));
            assertTrue(expectedConfigs[i].bridgeAdapter != address(0), string.concat("zero expected adapter: ", label));
        }
    }

    function test_allTokenConfigsHaveNonZeroRecipient() public view {
        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory expectedConfigs) = parseAllTokenConfigs();
        for (uint256 i = 0; i < tokens.length; i++) {
            TopUpFactory.TokenConfig memory actual = topUpFactory.getTokenConfig(tokens[i], chainIds[i]);
            string memory label = string.concat(vm.toString(tokens[i]), " -> chain ", vm.toString(chainIds[i]));
            assertTrue(actual.recipientOnDestChain != address(0), string.concat("zero recipient: ", label));
            assertTrue(expectedConfigs[i].recipientOnDestChain != address(0), string.concat("zero expected recipient: ", label));
        }
    }

    // ---- Helpers ----

    function _readDeployments() internal view returns (string memory) {
        return readDeploymentFile();
    }
}
