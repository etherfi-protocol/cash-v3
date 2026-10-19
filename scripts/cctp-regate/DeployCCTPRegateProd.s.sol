// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { CCTPModule } from "../../src/modules/cctp/CCTPModule.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title DeployCCTPRegateProd
 * @notice CREATE3-deploys the prod contracts for cash-v3 #343 through the on-chain EtherFiDeployer:
 *           Optimism (10): the re-gated CCTPModule (setters on ADMIN_TIMELOCK_ROLE), constructed with the live
 *                          module's USDC config (TokenMessengerV2, maxFeeBps 200, providerFeeBps 0)
 *           Ethereum (1):  the TradingLens impl with TRADING_LENS_TOKEN_LISTER_ROLE
 *         Deploying changes no live state: the module is enabled and the lens upgraded by the 3CP bundles from
 *         CCTPRegateProd3CP.s.sol. Idempotent: an address that already holds code is not redeployed.
 * @dev Prod only.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/cctp-regate/DeployCCTPRegateProd.s.sol --rpc-url $OPTIMISM_RPC --broadcast --verify
 *   ENV=mainnet forge script scripts/cctp-regate/DeployCCTPRegateProd.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployCCTPRegateProd is EtherFiDeployerHelper {
    using stdJson for string;

    string internal constant MODULE_SALT = "Prod.CCTPRegate.Optimism.CCTPModule";
    address internal constant EXPECTED_MODULE = 0xD3f5c617EF328b73130467b0ec867aD9058a1784;
    string internal constant LENS_IMPL_SALT = "Prod.CCTPRegate.Ethereum.TradingLensImpl";
    address internal constant EXPECTED_LENS_IMPL = 0x8E0C445d86c1Bf904e5e460B5c8F725eA34d968c;

    // Optimism: the live module the new one replaces, and its constructor config
    address internal constant OLD_MODULE = 0xFEF147ce61614aa787B6E68c24Ff096D13593A9d;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint256 internal constant MAX_FEE_BPS = 200;
    uint256 internal constant PROVIDER_FEE_BPS = 0;

    // Ethereum: the live TradingLens proxy and its price provider
    address internal constant TRADING_LENS = 0x7135AD135Ec21ec765C1930E93DEB7DA9c27290C;
    address internal constant TRADING_PRICE_PROVIDER = 0x5e67363807764b90Cb7E86b33F2163224eFCb1A2;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        require(block.chainid == 10 || block.chainid == 1, "run on Optimism or Ethereum");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        require(DEPLOYER.isDeployer(vm.addr(deployerPk)), "broadcaster is not an EtherFiDeployer deployer");

        if (block.chainid == 10) _deployModule(deployerPk);
        else _deployLensImpl(deployerPk);
    }

    function _deployModule(uint256 deployerPk) internal {
        require(_predictAddress(MODULE_SALT) == EXPECTED_MODULE, "module salt does not resolve to the pinned address");
        address dataProvider = readDeploymentFile().readAddress(".addresses.EtherFiDataProvider");

        CCTPModule.AssetConfig memory live = CCTPModule(OLD_MODULE).getAssetConfig(USDC);
        require(live.tokenMessenger == TOKEN_MESSENGER && live.maxFeeBps == MAX_FEE_BPS && live.providerFeeBps == PROVIDER_FEE_BPS, "live module USDC config changed");
        require(address(CCTPModule(OLD_MODULE).etherFiDataProvider()) == dataProvider, "live module points at another data provider");

        address[] memory assets = new address[](1);
        assets[0] = USDC;
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: TOKEN_MESSENGER, maxFeeBps: MAX_FEE_BPS, providerFeeBps: PROVIDER_FEE_BPS });

        vm.startBroadcast(deployerPk);
        address module = _create3(MODULE_SALT, type(CCTPModule).creationCode, abi.encode(assets, cfgs, dataProvider));
        vm.stopBroadcast();

        require(module == EXPECTED_MODULE, "module did not land at the pinned address");
        CCTPModule.AssetConfig memory cfg = CCTPModule(module).getAssetConfig(USDC);
        require(cfg.tokenMessenger == TOKEN_MESSENGER && cfg.maxFeeBps == MAX_FEE_BPS && cfg.providerFeeBps == PROVIDER_FEE_BPS, "module USDC config mismatch");
        require(address(CCTPModule(module).etherFiDataProvider()) == dataProvider, "module data provider mismatch");
        console.log("CCTPModule:", module);
    }

    function _deployLensImpl(uint256 deployerPk) internal {
        require(_predictAddress(LENS_IMPL_SALT) == EXPECTED_LENS_IMPL, "lens impl salt does not resolve to the pinned address");
        require(address(TradingLens(TRADING_LENS).priceProvider()) == TRADING_PRICE_PROVIDER, "live lens price provider changed");

        vm.startBroadcast(deployerPk);
        address impl = _create3(LENS_IMPL_SALT, type(TradingLens).creationCode, abi.encode(TRADING_PRICE_PROVIDER));
        vm.stopBroadcast();

        require(impl == EXPECTED_LENS_IMPL, "lens impl did not land at the pinned address");
        require(address(TradingLens(impl).priceProvider()) == TRADING_PRICE_PROVIDER, "lens impl price provider mismatch");
        console.log("TradingLensImpl:", impl);
    }
}
