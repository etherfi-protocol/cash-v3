// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IOFT } from "../../src/interfaces/IOFT.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title StockTopupConfig
 * @author ether.fi
 * @notice Shared configuration for the Ethereum-side stock topup rail: raw Backed stock
 *         (SPYx) deposited into a TopUp is wrapped into its ERC-4626 wrapper (wSPYx) and
 *         OFT-sent to the TopUpDest on Optimism, where it lands as the iwSPYx ShadowOFT.
 *
 *         Holds the CREATE3 salt for `StockOFTBridgeAdapter` (env-prefixed so dev and prod
 *         land at distinct deterministic addresses), the asset set, and the bridge
 *         parameters baked into the TopUpFactory token config.
 *
 * @dev The wrapper is NEVER passed to the adapter: it derives it as
 *      `IOFT(oftAdapter).token()` and requires `IERC4626(wrapper).asset() == token`.
 *      `_assertAssetWiring()` asserts that same chain off-line so a wrong constant fails
 *      before anything is broadcast.
 */
abstract contract StockTopupConfig is EtherFiDeployerHelper {
    using stdJson for string;

    // ---- CREATE3 salts (env-prefixed) ----

    string internal constant DEV_SALT_ADAPTER = "Dev.StockTopup.StockOFTBridgeAdapter";
    string internal constant PROD_SALT_ADAPTER = "Prod.StockTopup.StockOFTBridgeAdapter";

    /// @notice Key the adapter address is recorded under in deployments/{ENV}/1/deployments.json.
    string internal constant ADAPTER_DEPLOYMENT_KEY = "StockOFTBridgeAdapter";

    // ---- Asset set (Ethereum mainnet; identical between dev and prod) ----

    /// @notice Raw Backed stock token users top up with (rebasing, shares-based).
    address internal constant SPYX = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    /// @notice ERC-4626 wrapper the stock is deposited into before the OFT send.
    address internal constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    /// @notice Backed's LayerZero OFTAdapter that locks wSPYx on Ethereum.
    address internal constant WSPYX_OFT_ADAPTER = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;
    /// @notice The OP-side ShadowOFT the send mints (iwSPYx, already listed as collateral).
    address internal constant IWSPYX_OPTIMISM = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;

    // ---- Chain / bridge constants ----

    /// @notice Optimism mainnet endpoint ID (destination of every stock topup).
    uint32 internal constant OP_EID = 30111;
    /// @notice Optimism chain ID — the `destChainId` key of the TopUpFactory token config.
    uint256 internal constant OP_CHAIN_ID = 10;

    /// @notice Executor gas limit for the destination lzReceive (ShadowOFT mint) call.
    /// @dev The Backed OFTs have NO enforced SEND options, so empty options make the executor
    ///      fee library revert with `Executor_NoOptions` — the send must carry this explicitly.
    ///      Value reused from the withdraw direction (`StockWithdrawConfig.LZ_RECEIVE_GAS_LIMIT`),
    ///      where the mainnet OFTAdapter credit measured ~194k and the live tx burned 210k end
    ///      to end; 300k leaves headroom over the endpoint wrapper + mint on OP.
    uint128 internal constant LZ_RECEIVE_GAS = 300_000;

    /// @notice Slippage floor applied to the WRAPPED SHARES, in basis points.
    /// @dev This is dust absorption, not price slippage: the lock/mint OFT takes no fee, the
    ///      only loss is the OFT's shared-decimals truncation (<= 1e12 wei of an 18-decimal
    ///      wSPYx, i.e. ~1e-6 shares). At 0 bps that dust reverts the send — the route cannot
    ///      even be quoted. 100 bps keeps topups down to ~1e-4 shares bridgeable.
    uint96 internal constant MAX_SLIPPAGE_BPS = 100;

    /// @notice Prod operating Safe; owns the RoleRegistry that gates `setTokenConfig`.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ---- Env-derived selectors ----

    /// @dev True when ENV=dev; picks the salt and the privileged-call path.
    function _isDev() internal view returns (bool) {
        return isEqualString(getEnv(), "dev");
    }

    function _adapterSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_ADAPTER : PROD_SALT_ADAPTER;
    }

    /// @dev Deterministic address of the `StockOFTBridgeAdapter` for the current ENV.
    function _adapterAddress() internal view returns (address) {
        return _predictAddress(_adapterSalt());
    }

    // ---- Token config ----

    /// @dev `additionalData` the adapter decodes: (oftAdapter, destEid, lzReceiveGas).
    function _additionalData() internal pure returns (bytes memory) {
        return abi.encode(WSPYX_OFT_ADAPTER, OP_EID, LZ_RECEIVE_GAS);
    }

    /// @dev The single (SPYx, chain 10) config written to the TopUpFactory.
    function _spyxTokenConfig(address bridgeAdapter, address recipientOnOptimism) internal pure returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({ bridgeAdapter: bridgeAdapter, recipientOnDestChain: recipientOnOptimism, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: _additionalData() });
    }

    /// @dev Reads the destination recipient (TopUpDest on Optimism) for the current ENV.
    function _topUpDestOptimism() internal view returns (address) {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(OP_CHAIN_ID), "/deployments.json");
        return vm.readFile(file).readAddress(".addresses.TopUpDest");
    }

    /// @dev Path of the Ethereum deployment manifest for the current ENV.
    function _ethereumDeploymentPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/1/deployments.json");
    }

    /**
     * @dev Asserts on-chain that the constants describe one consistent wrap-and-send chain:
     *      the OFTAdapter locks wSPYx, and wSPYx's underlying is SPYx. This is exactly the
     *      derivation `StockOFTBridgeAdapter._resolveWrapper` performs at bridge time, so a
     *      mismatch here is a config that would revert `InvalidWrapperAsset` in production.
     */
    function _assertAssetWiring() internal view {
        require(IOFT(WSPYX_OFT_ADAPTER).token() == WSPYX, "OFT adapter does not lock wSPYx");
        require(IERC4626(WSPYX).asset() == SPYX, "wSPYx underlying is not SPYx");
    }
}
