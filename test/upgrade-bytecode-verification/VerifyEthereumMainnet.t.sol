// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { TradingSafeWithdrawModule } from "../../src/trading-safe/TradingSafeWithdrawModule.sol";
import { TradingStackBytecode } from "./TradingStackBytecode.sol";

/// @title Ethereum Mainnet Bytecode Verification
/// @notice Verifies that the deployed Ethereum cash StockUnwrapper, the top-up contracts the trading stack
///         reads, and the trading stack match the bytecode from this repo. Implementations are read from
///         the EIP-1967 slot of each proxy. The contracts every trading stack shares (RoleRegistry,
///         EtherFiDataProvider, TradingSafeFactory, TradingSafe) come from TradingStackBytecode.
///
/// Usage:
///   ENV=mainnet forge test --match-contract VerifyEthereumMainnetBytecode -vv
contract VerifyEthereumMainnetBytecode is TradingStackBytecode {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;

    string deployments;

    function setUp() public {
        string memory rpc = _tryEnv("MAINNET_RPC", "https://ethereum-rpc.publicnode.com");
        vm.createSelectFork(rpc);
        _load();
    }

    function _load() internal {
        deployments = readDeploymentFile();
        _loadTrading();
    }

    function test_verifyBytecode_StockUnwrapper() public {
        address local = address(new StockUnwrapper());
        _verify("StockUnwrapper", _getImpl(_cash("StockUnwrapper")), local);
    }

    function test_verifyBytecode_TradingPriceProvider() public {
        address local = address(new PriceProviderV2());
        _verify("trading PriceProvider", _getImpl(_tradingAddr("PriceProvider")), local);
    }

    function test_verifyBytecode_TradingAcrossSwapModule() public {
        address local = address(new AcrossSwapModule(_tradingAddr("EtherFiDataProvider")));
        _verify("trading AcrossSwapModule", _getImpl(_tradingAddr("AcrossSwapModule")), local);
    }

    function test_verifyBytecode_TradingEnsoSwapModule() public {
        address local = address(new EnsoSwapModule(_tradingAddr("EtherFiDataProvider")));
        _verify("trading EnsoSwapModule", _getImpl(_tradingAddr("EnsoSwapModule")), local);
    }

    function test_verifyBytecode_TradingLens() public {
        // TradingLens gained TRADING_LENS_TOKEN_LISTER_ROLE (#343) after the live impl was deployed. Re-enable after
        // the prod upgrade.
        vm.skip(true);
        address local = address(new TradingLens(_tradingAddr("PriceProvider")));
        _verify("TradingLens", _getImpl(_tradingAddr("TradingLens")), local);
    }

    function test_verifyBytecode_TradingSafeWithdrawModule() public {
        address local = address(new TradingSafeWithdrawModule(_tradingAddr("EtherFiDataProvider")));
        _verify("TradingSafeWithdrawModule", _tradingAddr("TradingSafeWithdrawModule"), local);
    }

    /// @dev The Liquid vault routes live in storage, so one route read from the deployed module is enough to
    ///      satisfy the constructor.
    function test_verifyBytecode_TradingSafeLiquidDepositModule() public {
        TradingSafeLiquidDepositModule live = TradingSafeLiquidDepositModule(_tradingAddr("TradingSafeLiquidDepositModule"));
        address[] memory assets = new address[](1);
        assets[0] = LIQUID_BTC;
        address[] memory tellers = new address[](1);
        tellers[0] = address(live.liquidAssetToTeller(LIQUID_BTC));
        address local = address(new TradingSafeLiquidDepositModule(assets, tellers, _tradingAddr("EtherFiDataProvider")));
        _verify("TradingSafeLiquidDepositModule", address(live), local);
    }

    /// @dev The top-up source factory and its TopUp beacon implementation, recorded in the trading stack file
    function test_verifyBytecode_TopUpFactory() public {
        address local = address(new TopUpFactory());
        _verify("TopUpFactory", _getImpl(_cash("TopUpSourceFactory")), local);
    }

    function test_verifyBytecode_TopUp() public {
        address beacon = TopUpFactory(payable(_cash("TopUpSourceFactory"))).beacon();
        address deployed = UpgradeableBeacon(beacon).implementation();
        address local = address(new TopUpV2(WETH, _cash("AssetRecoveryDispatcher")));
        _verify("TopUp", deployed, local);
    }

    // ---- Helpers ----

    function _cash(string memory key) internal view returns (address) {
        return stdJson.readAddress(deployments, string.concat(".addresses.", key));
    }
}
