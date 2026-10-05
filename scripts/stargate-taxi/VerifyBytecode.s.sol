// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title VerifyStargateTaxiBytecode
 * @notice Verifies every contract deployed for the Stargate taxi migration against this source tree.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/stargate-taxi/VerifyBytecode.s.sol --rpc-url $BASE_RPC -vv
 *   ENV=mainnet forge script scripts/stargate-taxi/VerifyBytecode.s.sol --rpc-url $OPTIMISM_RPC -vv
 *
 * @dev The dispatcher implementations use UUPS and embed their deployment addresses in runtime
 *      bytecode. They require address-binding comparison. The module and adapter use exact runtime
 *      bytecode comparison. Proxy implementation slots only report rollout status, so this script
 *      works before and after the timelock transactions execute.
 */
contract VerifyStargateTaxiBytecode is EtherFiDeployerHelper, ContractCodeChecker {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant WEETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address internal constant ETHFI = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address internal constant WHYPE = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address internal constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address internal constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address internal constant USDC_STARGATE_POOL = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    string internal constant ADAPTER_SALT = "Prod.StargateTaxi.Base.StargateAdapter";
    string internal constant MODULE_SALT = "Prod.StargateTaxi.Optimism.StargateModule";
    string internal constant REAP_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherReapImpl";
    string internal constant RAIN_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherRainImpl";
    string internal constant PIX_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherPixImpl";
    string internal constant CARD_ORDER_IMPL_SALT = "Prod.StargateTaxi.Optimism.SettlementDispatcherCardOrderImpl";

    /// @notice Verifies the Stargate taxi deployment on the active Base or Optimism fork.
    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        if (block.chainid == 8453) {
            _verifyBase();
        } else if (block.chainid == 10) {
            _verifyOptimism();
        } else {
            revert("run on Base or Optimism");
        }

        console2.log("Stargate taxi bytecode verification passed");
    }

    /// @dev Rebuilds the Base adapter and verifies its deterministic address, code, and WETH value.
    function _verifyBase() internal {
        string memory deployments = readDeploymentFile();
        address adapter = deployments.readAddress(".addresses.StargateAdapter");

        require(adapter == _predictAddress(ADAPTER_SALT), "unexpected StargateAdapter address");
        requireExactCodeMatch("StargateAdapter", adapter, address(new StargateAdapter(BASE_WETH)));
        require(StargateAdapter(payable(adapter)).weth() == BASE_WETH, "StargateAdapter WETH mismatch");
    }

    /// @dev Rebuilds the Optimism module and dispatcher implementations and verifies their rollout state.
    function _verifyOptimism() internal {
        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address module = deployments.readAddress(".addresses.StargateModule");

        require(module == _predictAddress(MODULE_SALT), "unexpected StargateModule address");
        (address[] memory assets, StargateModule.AssetConfig[] memory configs) = _moduleConfig();
        requireExactCodeMatch("StargateModule", module, address(new StargateModule(assets, configs, dataProvider)));
        _verifyModuleConfig(module, dataProvider, assets, configs);

        _verifyDispatcher(deployments, "SettlementDispatcherReap", "SettlementDispatcherReapImpl", REAP_IMPL_SALT, BinSponsor.Reap, dataProvider);
        _verifyDispatcher(deployments, "SettlementDispatcherRain", "SettlementDispatcherRainImpl", RAIN_IMPL_SALT, BinSponsor.Rain, dataProvider);
        _verifyDispatcher(deployments, "SettlementDispatcherPix", "SettlementDispatcherPixImpl", PIX_IMPL_SALT, BinSponsor.PIX, dataProvider);
        _verifyDispatcher(deployments, "SettlementDispatcherCardOrder", "SettlementDispatcherCardOrderImpl", CARD_ORDER_IMPL_SALT, BinSponsor.CardOrder, dataProvider);
    }

    /// @dev Verifies one deterministic dispatcher implementation and reports its proxy upgrade state.
    function _verifyDispatcher(string memory deployments, string memory proxyKey, string memory implementationLabel, string memory implementationSalt, BinSponsor sponsor, address dataProvider) internal {
        address proxy = deployments.readAddress(string.concat(".addresses.", proxyKey));
        address implementation = _predictAddress(implementationSalt);

        address local = address(new SettlementDispatcherV2(sponsor, dataProvider));
        requireCodeMatchAllowingAddressEmbeds(implementationLabel, implementation, local);

        SettlementDispatcherV2 dispatcher = SettlementDispatcherV2(payable(implementation));
        require(dispatcher.binSponsor() == sponsor, string.concat(implementationLabel, " sponsor mismatch"));
        require(address(dispatcher.dataProvider()) == dataProvider, string.concat(implementationLabel, " data provider mismatch"));

        address activeImplementation = address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
        if (activeImplementation == implementation) {
            console2.log(string.concat("  [OK] ", proxyKey, " proxy uses verified implementation"));
        } else {
            console2.log(string.concat("  [PENDING] ", proxyKey, " proxy implementation:"), activeImplementation);
        }
    }

    /// @dev Verifies the module's immutable data provider and constructor-written asset configuration.
    function _verifyModuleConfig(address module, address dataProvider, address[] memory assets, StargateModule.AssetConfig[] memory configs) internal view {
        StargateModule deployed = StargateModule(payable(module));
        require(address(deployed.etherFiDataProvider()) == dataProvider, "StargateModule data provider mismatch");

        for (uint256 i = 0; i < assets.length; i++) {
            StargateModule.AssetConfig memory actual = deployed.getAssetConfig(assets[i]);
            require(actual.isOFT == configs[i].isOFT, "StargateModule asset type mismatch");
            require(actual.pool == configs[i].pool, "StargateModule asset pool mismatch");
        }
    }

    /// @dev Returns every asset configuration supplied to the deployed Optimism module.
    function _moduleConfig() internal pure returns (address[] memory assets, StargateModule.AssetConfig[] memory configs) {
        assets = new address[](6);
        assets[0] = USDC;
        assets[1] = WEETH;
        assets[2] = ETHFI;
        assets[3] = WHYPE;
        assets[4] = BEHYPE;
        assets[5] = EURC;

        configs = new StargateModule.AssetConfig[](6);
        configs[0] = StargateModule.AssetConfig({ isOFT: false, pool: USDC_STARGATE_POOL });
        for (uint256 i = 1; i < assets.length; i++) {
            configs[i] = StargateModule.AssetConfig({ isOFT: true, pool: assets[i] });
        }
    }
}
