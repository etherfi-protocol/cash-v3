// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {OracleProvider} from "../src/oracle/OracleProvider.sol";
import {PriceProvider} from "../src/oracle/PriceProvider.sol";
import {Utils} from "./utils/Utils.sol";

/// @title UpdateDevOpPriceProviderOracleConfigs
/// @notice Updates PriceProvider oracle configs for EURC, wHYPE, ETHFI, sETHFI, beHYPE on Optimism dev.
///         Reads oracle proxy addresses from `deployments/{ENV}/{chainId}/oracles.json`.
///
/// Usage:
///   ENV=dev forge script scripts/UpdateDevOpPriceProviderOracleConfigs.s.sol --rpc-url $OPTIMISM_RPC --broadcast
contract UpdateDevOpPriceProviderOracleConfigs is Utils {
    address constant LIQUID_RESERVE = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");

        string memory oraclesFile =
            string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/oracles.json");
        string memory oracles = vm.readFile(oraclesFile);

        address liquidReserveOracle = stdJson.readAddress(oracles, ".addresses.LiquidReserve-USD");

        address[] memory tokens = new address[](1);
        tokens[0] = LIQUID_RESERVE;


        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
                oracle: liquidReserveOracle,
                priceFunctionCalldata: abi.encodeWithSelector(OracleProvider.getRate.selector),
                isChainlinkType: false,
                oraclePriceDecimals: 8,
                maxStaleness: 2 days,
                dataType: PriceProvider.ReturnType.Uint256,
                isBaseTokenEth: false,
                isStableToken: false,
                isBaseTokenBtc: false
        });

        console.log("PriceProvider:", priceProvider);
        console.log("Updating oracle configs from:", oraclesFile);
        PriceProvider(priceProvider).setTokenConfig(tokens, configs);
        console.log("  [OK] setTokenConfig for 1 token");

        vm.stopBroadcast();
    }
}
