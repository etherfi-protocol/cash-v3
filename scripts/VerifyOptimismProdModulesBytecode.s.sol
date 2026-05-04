// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";
import { Utils } from "./utils/Utils.sol";

import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { FraxModule } from "../src/modules/frax/FraxModule.sol";
import { EtherFiStakeModule } from "../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierModule } from "../src/modules/etherfi/LiquidUSDLiquifier.sol";

/// @title Bytecode verification for OP Mainnet prod module deployment
/// @notice Deploys each contract locally with the same constructor args and compares
///         runtime bytecode against the on-chain deployed contracts.
///
/// Usage:
///   ENV=mainnet forge script scripts/VerifyOptimismProdModulesBytecode.s.sol --rpc-url $OPTIMISM_RPC -vvv
contract VerifyOptimismProdModulesBytecode is Script, ContractCodeChecker, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Must match DeployOptimismProdModules salts exactly
    bytes32 constant SALT_LIQUID_MODULE            = keccak256("DeployOptimismProdModules.EtherFiLiquidModule");
    bytes32 constant SALT_LIQUID_MODULE_REFERRER   = keccak256("DeployOptimismProdModules.EtherFiLiquidModuleWithReferrer");
    bytes32 constant SALT_STARGATE_MODULE          = keccak256("DeployOptimismProdModules.StargateModule");
    bytes32 constant SALT_FRAX_MODULE              = keccak256("DeployOptimismProdModules.FraxModule");
    bytes32 constant SALT_LIQUIFIER_IMPL           = keccak256("DeployOptimismProdModules.LiquidUSDLiquifierImpl");
    bytes32 constant SALT_LIQUIFIER_PROXY          = keccak256("DeployOptimismProdModules.LiquidUSDLiquifierProxy");
    bytes32 constant SALT_STAKE_MODULE             = keccak256("DeployOptimismProdModules.EtherFiStakeModule");

    // OP chain addresses (constructor args)
    address constant weth = 0x4200000000000000000000000000000000000006;
    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant weETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant syncPool = 0xC9475e18E2C5C26EA6ADCD55fabE07920beA887e;

    // Liquid vault assets (same as Scroll)
    address constant liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant liquidEthTeller = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant liquidUsdTeller = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant liquidBtcTeller = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant ebtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant ebtcTeller = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;

    // sETHFI
    address constant sethfi = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant sethfiTeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;

    // Stargate
    address constant stargateUsdcPool = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    // Frax
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant fraxCustodian = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address constant fraxRemoteHop = 0x31D982ebd82Ad900358984bd049207A4c2468640;

    address dp; // dataProvider
    address dm; // debtManager

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (chain 10)");

        string memory deployments = readDeploymentFile();
        dp = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        dm = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));

        console2.log("==========================================");
        console2.log("  OP Mainnet Module Bytecode Verification");
        console2.log("==========================================\n");

        _verifyLiquidModule();
        _verifyLiquidModuleWithReferrer();
        _verifyStargateModule();
        _verifyFraxModule();
        _verifyStakeModule();
        _verifyLiquifierImpl();

        console2.log("\n==========================================");
        console2.log("  Bytecode Verification Complete");
        console2.log("==========================================");
    }

    function _verifyLiquidModule() internal {
        console2.log("1. EtherFiLiquidModule");
        address onchain = CREATE3.predictDeterministicAddress(SALT_LIQUID_MODULE, NICKS_FACTORY);

        address[] memory assets = new address[](4);
        assets[0] = liquidEth;
        assets[1] = liquidBtc;
        assets[2] = liquidUsd;
        assets[3] = ebtc;

        address[] memory tellers = new address[](4);
        tellers[0] = liquidEthTeller;
        tellers[1] = liquidBtcTeller;
        tellers[2] = liquidUsdTeller;
        tellers[3] = ebtcTeller;

        address local = address(new EtherFiLiquidModule(assets, tellers, dp, weth));
        verifyContractByteCodeMatch(onchain, local);
    }

    function _verifyLiquidModuleWithReferrer() internal {
        console2.log("2. EtherFiLiquidModuleWithReferrer");
        address onchain = CREATE3.predictDeterministicAddress(SALT_LIQUID_MODULE_REFERRER, NICKS_FACTORY);

        address[] memory assets = new address[](1);
        assets[0] = sethfi;
        address[] memory tellers = new address[](1);
        tellers[0] = sethfiTeller;

        address local = address(new EtherFiLiquidModuleWithReferrer(assets, tellers, dp, weth));
        verifyContractByteCodeMatch(onchain, local);
    }

    function _verifyStargateModule() internal {
        console2.log("3. StargateModule");
        address onchain = CREATE3.predictDeterministicAddress(SALT_STARGATE_MODULE, NICKS_FACTORY);

        address[] memory assets = new address[](2);
        assets[0] = usdc;
        assets[1] = weETH;

        StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](2);
        configs[0] = StargateModule.AssetConfig({isOFT: false, pool: stargateUsdcPool});
        configs[1] = StargateModule.AssetConfig({isOFT: true, pool: weETH});

        address local = address(new StargateModule(assets, configs, dp));
        verifyContractByteCodeMatch(onchain, local);
    }

    function _verifyFraxModule() internal {
        console2.log("4. FraxModule");
        address onchain = CREATE3.predictDeterministicAddress(SALT_FRAX_MODULE, NICKS_FACTORY);

        address local = address(new FraxModule(dp, frxUSD, fraxCustodian, fraxRemoteHop));
        verifyContractByteCodeMatch(onchain, local);
    }

    function _verifyStakeModule() internal {
        console2.log("5. EtherFiStakeModule");
        address onchain = CREATE3.predictDeterministicAddress(SALT_STAKE_MODULE, NICKS_FACTORY);

        address local = address(new EtherFiStakeModule(dp, syncPool, weth, weETH));
        verifyContractByteCodeMatch(onchain, local);
    }

    function _verifyLiquifierImpl() internal {
        console2.log("6. LiquidUSDLiquifierModule (impl)");
        address liquifierProxy = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_PROXY, NICKS_FACTORY);
        address expectedImpl = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_IMPL, NICKS_FACTORY);

        // Verify proxy's impl slot points to our CREATE3-deployed impl
        address actualImpl = address(uint160(uint256(vm.load(liquifierProxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "LiquidUSDLiquifier impl slot mismatch - possible hijack");
        console2.log("  [OK] Impl slot matches CREATE3 prediction:", actualImpl);

        // Bytecode verification of the impl
        address local = address(new LiquidUSDLiquifierModule(dm, dp));
        verifyContractByteCodeMatch(actualImpl, local);
    }
}
