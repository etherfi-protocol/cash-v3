// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { CCTPModule } from "../../src/modules/cctp/CCTPModule.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title VerifyCCTPRegateProd
 * @notice Verifies the contracts DeployCCTPRegateProd.s.sol deployed for cash-v3 #343 against this source tree:
 *           Optimism (10): the re-gated CCTPModule
 *           Ethereum (1):  the TradingLens impl with TRADING_LENS_TOKEN_LISTER_ROLE
 *         Each address must be the CREATE3 address of its salt, and its runtime bytecode must match a local build
 *         with the same constructor args.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/cctp-regate/VerifyCCTPRegateProd.s.sol --rpc-url $OPTIMISM_RPC -vv
 *   ENV=mainnet forge script scripts/cctp-regate/VerifyCCTPRegateProd.s.sol --rpc-url $MAINNET_RPC -vv
 *
 * @dev CCTPModule is not upgradeable and uses an exact runtime bytecode comparison. The TradingLens impl is UUPS and
 *      embeds its own deployment address, so it needs the address-binding comparison. Rollout status (whether the
 *      module is enabled, whether the lens proxy points at the new impl) is only logged, so this script works
 *      before and after the 3CP executes.
 */
contract VerifyCCTPRegateProd is EtherFiDeployerHelper, ContractCodeChecker {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Optimism
    string internal constant MODULE_SALT = "Prod.CCTPRegate.Optimism.CCTPModule";
    address internal constant MODULE = 0xD3f5c617EF328b73130467b0ec867aD9058a1784;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint256 internal constant MAX_FEE_BPS = 200;
    uint256 internal constant PROVIDER_FEE_BPS = 0;

    // Ethereum
    string internal constant LENS_IMPL_SALT = "Prod.CCTPRegate.Ethereum.TradingLensImpl";
    address internal constant LENS_IMPL = 0x8E0C445d86c1Bf904e5e460B5c8F725eA34d968c;
    address internal constant TRADING_LENS = 0x7135AD135Ec21ec765C1930E93DEB7DA9c27290C;
    address internal constant TRADING_PRICE_PROVIDER = 0x5e67363807764b90Cb7E86b33F2163224eFCb1A2;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        if (block.chainid == 10) {
            _verifyOptimism();
        } else if (block.chainid == 1) {
            _verifyEthereum();
        } else {
            revert("run on Optimism or Ethereum");
        }

        console2.log("CCTP re-gate bytecode verification passed");
    }

    /// @dev Rebuilds the module with its deploy args and verifies its deterministic address, code and config
    function _verifyOptimism() internal {
        address dataProvider = readDeploymentFile().readAddress(".addresses.EtherFiDataProvider");
        require(MODULE == _predictAddress(MODULE_SALT), "unexpected CCTPModule address");

        address[] memory assets = new address[](1);
        assets[0] = USDC;
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: TOKEN_MESSENGER, maxFeeBps: MAX_FEE_BPS, providerFeeBps: PROVIDER_FEE_BPS });
        requireExactCodeMatch("CCTPModule", MODULE, address(new CCTPModule(assets, cfgs, dataProvider)));

        CCTPModule module = CCTPModule(MODULE);
        require(address(module.etherFiDataProvider()) == dataProvider, "CCTPModule data provider mismatch");
        CCTPModule.AssetConfig memory cfg = module.getAssetConfig(USDC);
        require(cfg.tokenMessenger == TOKEN_MESSENGER && cfg.maxFeeBps == MAX_FEE_BPS && cfg.providerFeeBps == PROVIDER_FEE_BPS, "CCTPModule USDC config mismatch");

        (bool ok, bytes memory ret) = dataProvider.staticcall(abi.encodeWithSignature("isDefaultModule(address)", MODULE));
        require(ok, "isDefaultModule failed");
        console2.log("  rollout: CCTPModule is a default module:", abi.decode(ret, (bool)));
    }

    /// @dev Rebuilds the lens impl and verifies its deterministic address, code and price provider
    function _verifyEthereum() internal {
        require(LENS_IMPL == _predictAddress(LENS_IMPL_SALT), "unexpected TradingLensImpl address");
        requireCodeMatchAllowingAddressEmbeds("TradingLensImpl", LENS_IMPL, address(new TradingLens(TRADING_PRICE_PROVIDER)));
        require(address(TradingLens(LENS_IMPL).priceProvider()) == TRADING_PRICE_PROVIDER, "TradingLensImpl price provider mismatch");
        require(TradingLens(LENS_IMPL).TRADING_LENS_TOKEN_LISTER_ROLE() == keccak256("TRADING_LENS_TOKEN_LISTER_ROLE"), "unexpected lister role hash");

        address current = address(uint160(uint256(vm.load(TRADING_LENS, EIP1967_IMPLEMENTATION_SLOT))));
        console2.log("  rollout: TradingLens proxy is on the new impl:", current == LENS_IMPL);
    }
}
