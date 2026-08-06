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
    uint128 internal constant LZ_RECEIVE_GAS_LIMIT = 150_000;
    /// @notice Executor gas limit for the destination lzCompose call.
    uint128 internal constant COMPOSE_GAS_LIMIT = 500_000;

    /// @notice Provider (exit) fee in basis points taken from the wrapped-stock amount at
    ///         execute time (0 = disabled at launch; module admin can set up to 1000).
    uint16 internal constant PROVIDER_FEE_BPS = 0;
    /// @notice Recipient of the provider fee.
    address internal constant FEE_RECEIVER = SAFE;

    // ---- Wrapped-stock asset set (shared between envs today) ----

    /// @notice OP ShadowOFTs (the iTOKENs the module bridges).
    address internal constant WSPYX_SHADOW_OFT = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;

    /// @notice Mainnet OFTAdapters (lock/unlock counterparts of the ShadowOFTs).
    address internal constant WSPYX_ADAPTER = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;

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

    /// @dev The iTOKENs the OP module registers at initialize.
    function _iTokens() internal pure returns (address[] memory iTokens, bool[] memory supported) {
        iTokens = new address[](1);
        iTokens[0] = WSPYX_SHADOW_OFT;
        supported = new bool[](1);
        supported[0] = true;
    }

    /// @dev The mainnet OFTAdapters the unwrapper registers at initialize.
    function _adapters() internal pure returns (address[] memory adapters, bool[] memory registered) {
        adapters = new address[](1);
        adapters[0] = WSPYX_ADAPTER;
        registered = new bool[](1);
        registered[0] = true;
    }
}
