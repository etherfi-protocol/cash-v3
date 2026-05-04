// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title SetPythOraclesOP
/// @notice Generates a Gnosis Safe batch transaction to:
///         1. Configure Pyth price feeds for sETHFI, ETHFI, wHYPE, beHYPE, EURC
///         2. Add wHYPE, beHYPE, EURC, ETHFI as OFT assets on StargateModule
///
/// Usage:
///   ENV=mainnet forge script scripts/gnosis-txs/SetPythOraclesOP.s.sol --rpc-url optimism -vvv
contract SetPythOraclesOP is Utils, GnosisHelpers, Test {
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Token addresses on OP
    address constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant ETHFI  = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address constant WHYPE  = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant EURC   = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;

    // Pyth oracle addresses on OP
    address constant SETHFI_USD_ORACLE = 0x8454985aA5bc30162aC258D3CCf89E9BA6604d99;
    address constant ETHFI_USD_ORACLE  = 0x3E377b4e02bc848Ade3c289477F21441b7e014C2;
    address constant WHYPE_USD_ORACLE  = 0x1f860581483253B81ECB0E89b2b978A202de553d;
    address constant BEHYPE_USD_ORACLE = 0x2ACd77fefED51Fa80FBF1520701c73Ac506D4381;
    address constant EURC_USD_ORACLE   = 0x62779cdAadd1eB782eb4fF534739B55763A48385;

    address priceProvider;
    address stargateModule;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        stargateModule = stdJson.readAddress(deployments, ".addresses.StargateModule");
        string memory chainId = vm.toString(block.chainid);

        console.log("PriceProvider:", priceProvider);
        console.log("StargateModule:", stargateModule);
        console.log("Safe:", cashControllerSafe);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // ── 1. Price oracle config ──
        {
            address[] memory tokens = new address[](5);
            tokens[0] = SETHFI;
            tokens[1] = ETHFI;
            tokens[2] = WHYPE;
            tokens[3] = BEHYPE;
            tokens[4] = EURC;

            PriceProvider.Config[] memory configs = new PriceProvider.Config[](5);
            configs[0] = _pythConfig(SETHFI_USD_ORACLE);
            configs[1] = _pythConfig(ETHFI_USD_ORACLE);
            configs[2] = _pythConfig(WHYPE_USD_ORACLE);
            configs[3] = _pythConfig(BEHYPE_USD_ORACLE);
            configs[4] = _pythConfig(EURC_USD_ORACLE);

            string memory data = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, configs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), data, "0", false)));
        }

        // ── 2. Add OFT assets to StargateModule (wHYPE, beHYPE, EURC, ETHFI) ──
        {
            address[] memory oftAssets = new address[](4);
            oftAssets[0] = WHYPE;
            oftAssets[1] = BEHYPE;
            oftAssets[2] = EURC;
            oftAssets[3] = ETHFI;

            StargateModule.AssetConfig[] memory oftConfigs = new StargateModule.AssetConfig[](4);
            oftConfigs[0] = StargateModule.AssetConfig({ isOFT: true, pool: WHYPE });
            oftConfigs[1] = StargateModule.AssetConfig({ isOFT: true, pool: BEHYPE });
            oftConfigs[2] = StargateModule.AssetConfig({ isOFT: true, pool: EURC });
            oftConfigs[3] = StargateModule.AssetConfig({ isOFT: true, pool: ETHFI });

            string memory data = iToHex(abi.encodeWithSelector(StargateModule.setAssetConfig.selector, oftAssets, oftConfigs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(stargateModule), data, "0", true)));
        }

        vm.createDir("./output", true);
        string memory path = "./output/SetPythOraclesOP.json";
        vm.writeFile(path, txs);
        console.log("Bundle written to:", path);

        // Simulate
        executeGnosisTransactionBundle(path);
        console.log("Simulation OK");

        // Verify prices
        _verifyPrices();

        // Verify OFT configs on StargateModule
        _verifyOftConfigs();
    }

    function _pythConfig(address oracle) internal pure returns (PriceProvider.Config memory) {
        return PriceProvider.Config({
            oracle: oracle,
            priceFunctionCalldata: abi.encodeWithSignature("price()"),
            isChainlinkType: false,
            oraclePriceDecimals: 16,
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
    }

    function _verifyPrices() internal view {
        PriceProvider pp = PriceProvider(priceProvider);
        address[5] memory tokens = [SETHFI, ETHFI, WHYPE, BEHYPE, EURC];
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 p = pp.price(tokens[i]);
            require(p > 0, string.concat("Zero price for ", vm.toString(tokens[i])));
            console.log("  [OK]", vm.toString(tokens[i]), "price =", p);
        }
    }

    function _verifyOftConfigs() internal view {
        StargateModule sm = StargateModule(payable(stargateModule));
        address[4] memory oftTokens = [WHYPE, BEHYPE, EURC, ETHFI];
        string[4] memory names = ["wHYPE", "beHYPE", "EURC", "ETHFI"];
        for (uint256 i = 0; i < oftTokens.length; i++) {
            StargateModule.AssetConfig memory cfg = sm.getAssetConfig(oftTokens[i]);
            require(cfg.isOFT, string.concat(names[i], " not set as OFT"));
            require(cfg.pool == oftTokens[i], string.concat(names[i], " pool mismatch"));
            console.log(string.concat("  [OK] ", names[i], " OFT config"));
        }
    }
}
