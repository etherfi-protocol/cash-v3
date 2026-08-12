// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title StockWithdrawConfig
 * @author ether.fi
 * @notice Shared configuration for the stock-withdraw deploy + verification scripts on both
 *         chains: CREATE3 salts (env-prefixed so dev and prod land at distinct deterministic
 *         addresses), the wrapped-stock asset set, LayerZero chain constants, the prod Safe
 *         and the compose gas limit. Everything cross-chain-address-dependent (the OP module
 *         predicting the mainnet unwrapper and vice versa) derives from these salts, so they
 *         MUST only ever change together.
 */
abstract contract StockWithdrawConfig is EtherFiDeployerHelper {
    // ---- CREATE3 salts (env-prefixed) ----

    string internal constant DEV_SALT_MODULE_IMPL = "Dev.StockWithdraw.StockWithdrawModuleImpl";
    string internal constant DEV_SALT_MODULE_PROXY = "Dev.StockWithdraw.StockWithdrawModuleProxy";
    string internal constant DEV_SALT_UNWRAPPER_IMPL = "Dev.StockWithdraw.StockUnwrapperImpl";
    string internal constant DEV_SALT_UNWRAPPER_PROXY = "Dev.StockWithdraw.StockUnwrapperProxy";

    string internal constant PROD_SALT_MODULE_IMPL = "Prod.StockWithdraw.StockWithdrawModuleImpl";
    string internal constant PROD_SALT_MODULE_PROXY = "Prod.StockWithdraw.StockWithdrawModuleProxy";
    string internal constant PROD_SALT_UNWRAPPER_IMPL = "Prod.StockWithdraw.StockUnwrapperImpl";
    string internal constant PROD_SALT_UNWRAPPER_PROXY = "Prod.StockWithdraw.StockUnwrapperProxy";

    // ---- Chain / protocol constants ----

    /// @notice LayerZero V2 endpoint on Ethereum mainnet.
    address internal constant LZ_ENDPOINT_ETHEREUM = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @notice OP mainnet endpoint ID (source chain of every withdrawal).
    uint32 internal constant OP_EID = 30111;
    /// @notice Ethereum mainnet endpoint ID (destination of every withdrawal).
    uint32 internal constant ETHEREUM_EID = 30101;

    /// @notice Prod Safe holding the admin roles (same address on OP and Ethereum).
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @notice Executor gas limit for the destination lzReceive (OFTAdapter credit) call.
    ///         Carried in the module's own send options: the executor rejects options with
    ///         no lzReceive gas, and the third-party ShadowOFTs cannot be assumed to have
    ///         enforced options set for SEND_AND_CALL.
    /// @dev The executor passes this as the gas for the whole `endpoint.lzReceive` call, so it
    ///      must cover the endpoint wrapper (`clearPayload` + checks) AND the adapter's
    ///      `lzReceive` (Backed token credit + `sendCompose` store). Measured against the real
    ///      wSPYx adapter on mainnet: ~194k needed; the live recovery tx burned 210k end to
    ///      end. 150k stranded a real withdrawal mid-flight (LZ guid 0xff7dbce6...).
    uint128 internal constant LZ_RECEIVE_GAS_LIMIT = 300_000;
    /// @notice Executor gas limit for the destination lzCompose call.
    /// @dev Same rule: covers the endpoint wrapper plus `StockUnwrapper.lzCompose` (the
    ///      ERC-4626 redeem to the recipient). Measured ~145k on mainnet at the real message.
    ///      NOTE: measuring this on a fork in the SAME tx as the lzReceive leg reports only
    ///      ~75k — the compose runs in its own tx in production, so every account and slot the
    ///      redeem touches is COLD. Always measure the legs in separate transactions.
    uint128 internal constant COMPOSE_GAS_LIMIT = 500_000;

    /// @notice Provider (exit) fee in basis points taken from the wrapped-stock amount at
    ///         execute time (0 = disabled at launch; module admin can set up to 1000).
    uint16 internal constant PROVIDER_FEE_BPS = 0;
    /// @notice Recipient of the provider fee.
    address internal constant FEE_RECEIVER = SAFE;

    // ---- Wrapped-stock asset set (shared between envs today) ----
    //
    // Each asset is a PAIR that must stay in lockstep: the OP ShadowOFT (iTOKEN) the module
    // bridges, and the mainnet OFTAdapter the unwrapper accepts messages from. The adapter is
    // the ShadowOFT's LayerZero peer for ETHEREUM_EID, and the unwrapper's adapter allowlist is
    // load-bearing (`_from` is the only endpoint-authenticated field), so a wrong or missing
    // adapter here is a security bug, not just a broken route.
    //
    // Both assets are Backed `WrappedBackedTokenProxy` ERC-4626 wrappers sharing implementation
    // 0x76c6851eA0b2741eEDCBBED240715E8817e85583, and both adapters share identical runtime
    // code — so wQQQx rides the exact rail already proven in prod by wSPYx.

    /// @notice OP ShadowOFT for wSPYx (iwSPYx).
    address internal constant WSPYX_SHADOW_OFT = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;
    /// @notice Mainnet OFTAdapter for wSPYx — `token()` is wSPYx 0xE7E553Cd…, peer of iwSPYx.
    address internal constant WSPYX_ADAPTER = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;

    /// @notice OP ShadowOFT for wQQQx (iwQQQx). Same address book as the QQQx lend listing —
    ///         `StockLendAssets.wqqqx().iToken`.
    address internal constant WQQQX_SHADOW_OFT = 0x3c99d3a81b27583B2E26dbd387C10411f2763516;
    /// @notice Mainnet OFTAdapter for wQQQx — `token()` is wQQQx 0x4C1AE29c…, and its
    ///         `peers(OP_EID)` is iwQQQx (verified bidirectionally on-chain).
    address internal constant WQQQX_ADAPTER = 0xD33685E92f079E05F7e25a5F14e68e44eD53bBC5;

    // ---- Env-derived selectors ----

    /// @dev True when ENV=dev; picks salts and the admin address.
    function _isDev() internal view returns (bool) {
        return isEqualString(getEnv(), "dev");
    }

    function _moduleImplSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_IMPL : PROD_SALT_MODULE_IMPL;
    }

    function _moduleProxySalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_PROXY : PROD_SALT_MODULE_PROXY;
    }

    function _unwrapperImplSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_UNWRAPPER_IMPL : PROD_SALT_UNWRAPPER_IMPL;
    }

    function _unwrapperProxySalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_UNWRAPPER_PROXY : PROD_SALT_UNWRAPPER_PROXY;
    }

    /// @dev Admin-role recipient: the broadcaster on dev, the prod Safe on mainnet.
    function _adminFor(address devAdmin) internal view returns (address) {
        return _isDev() ? devAdmin : SAFE;
    }

    // ---- Asset arrays (shared shape between deploy init and verification) ----

    /// @dev The iTOKENs the OP module registers at initialize. Index-aligned with `_adapters()`
    ///      — entry i here and entry i there are the two ends of the same asset's rail.
    function _iTokens() internal pure returns (address[] memory iTokens, bool[] memory supported) {
        iTokens = new address[](2);
        iTokens[0] = WSPYX_SHADOW_OFT;
        iTokens[1] = WQQQX_SHADOW_OFT;
        supported = new bool[](2);
        supported[0] = true;
        supported[1] = true;
    }

    /// @dev The mainnet OFTAdapters the unwrapper registers at initialize. Index-aligned with
    ///      `_iTokens()`.
    function _adapters() internal pure returns (address[] memory adapters, bool[] memory registered) {
        adapters = new address[](2);
        adapters[0] = WSPYX_ADAPTER;
        adapters[1] = WQQQX_ADAPTER;
        registered = new bool[](2);
        registered[0] = true;
        registered[1] = true;
    }
}
