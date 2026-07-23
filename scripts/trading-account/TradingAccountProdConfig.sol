// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

/// @notice Shared production addresses, salts, and permissionless CREATE3 helpers.
library TradingAccountProdConfig {
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant OPERATING_ADMIN = 0xB42833d6edd1241474D33ea99906fD4CBE893730;
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal constant ETHERFI_RECOVERY_SIGNER = OPERATING_SAFE;
    address internal constant THIRD_PARTY_RECOVERY_SIGNER = 0x4F5eB42edEce3285B97245f56b64598191b5A58E;
    address internal constant REFUND_WALLET = 0xF6B3422e3CC70fa9fce4fAb9A706ED2497c7bb9e;

    address internal constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_SPOKE_POOL = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
    address internal constant OP_SPOKE_POOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
    address internal constant MULTICALL_HANDLER = 0x0F7Ae28dE1C8532170AD4ee566B5801485c13a0E;
    address internal constant ACROSS_PERIPHERY = 0x10D8b8DaA26d307489803e10477De69C0492B610;
    address internal constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant SALT_ROLE_REGISTRY_IMPL = keccak256("TradingAccount.Prod.v1.RoleRegistryImpl");
    bytes32 internal constant SALT_ROLE_REGISTRY_PROXY = keccak256("TradingAccount.Prod.v1.RoleRegistryProxy");
    bytes32 internal constant SALT_PRICE_PROVIDER_IMPL = keccak256("TradingAccount.Prod.v1.PriceProviderImpl");
    bytes32 internal constant SALT_PRICE_PROVIDER_PROXY = keccak256("TradingAccount.Prod.v1.PriceProviderProxy");
    bytes32 internal constant SALT_TRADING_SAFE_IMPL = keccak256("TradingAccount.Prod.v1.TradingSafeImpl");
    bytes32 internal constant SALT_TRADING_SAFE_FACTORY_IMPL = keccak256("TradingAccount.Prod.v1.TradingSafeFactoryImpl");
    bytes32 internal constant SALT_TRADING_SAFE_FACTORY_PROXY = keccak256("TradingAccount.Prod.v1.TradingSafeFactoryProxy");
    bytes32 internal constant SALT_TRADING_LENS_IMPL = keccak256("TradingAccount.Prod.v1.TradingLensImpl");
    bytes32 internal constant SALT_TRADING_LENS_PROXY = keccak256("TradingAccount.Prod.v1.TradingLensProxy");
    bytes32 internal constant SALT_DATA_PROVIDER_IMPL = keccak256("TradingAccount.Prod.v1.DataProviderImpl");
    bytes32 internal constant SALT_DATA_PROVIDER_PROXY = keccak256("TradingAccount.Prod.v1.DataProviderProxy");
    bytes32 internal constant SALT_ACROSS_IMPL = keccak256("TradingAccount.Prod.v1.AcrossSwapModuleImpl");
    bytes32 internal constant SALT_ACROSS_PROXY = keccak256("TradingAccount.Prod.v1.AcrossSwapModuleProxy");
    bytes32 internal constant SALT_ENSO_IMPL = keccak256("TradingAccount.Prod.v1.EnsoSwapModuleImpl");
    bytes32 internal constant SALT_ENSO_PROXY = keccak256("TradingAccount.Prod.v1.EnsoSwapModuleProxy");
    bytes32 internal constant SALT_TOPUP_FACTORY_IMPL = keccak256("TradingAccount.Prod.v1.TopUpFactoryImpl");
    bytes32 internal constant SALT_TOPUP_IMPL = keccak256("TradingAccount.Prod.v1.TopUpImpl");

    function supportedTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](25);
        tokens[0] = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
        tokens[1] = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540; // wSPYx
        tokens[2] = 0x45804880De22913dAFE09f4980848ECE6EcbAf78; // PAXG
        tokens[3] = 0xD31a59c85aE9D8edEFeC411D448f90841571b89c; // SOL
        tokens[4] = 0x232CE3bd40fCd6f80f3d55A522d03f25Df784Ee2; // LIT
        tokens[5] = 0x6982508145454Ce325dDbE47a25d4ec3d2311933; // PEPE
        tokens[6] = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9; // AAVE
        tokens[7] = 0x514910771AF9Ca656af840dff83E8264EcF986CA; // LINK
        tokens[8] = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2; // MORPHO
        tokens[9] = 0x163f8C2467924be0ae7B5347228CABF260318753; // WLD
        tokens[10] = 0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66; // SYRUP
        tokens[11] = 0x4C1AE29c159838fC1b224636E28E086EB69101f7; // wQQQx
        tokens[12] = 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171; // wTSLAx
        tokens[13] = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5; // wNVDAx
        tokens[14] = 0xEe7CcB0d37A12862e7f92F6C92a93d9c2d304266; // wAMDx
        tokens[15] = 0x166Fbe68274b6a47e025F4ba17388c539f1fa1d0; // wMSFTx
        tokens[16] = 0xe840946FfEBCd66B7C4E95095effaFaDfa0D0e56; // wMETAx
        tokens[17] = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB; // wMSTRx
        tokens[18] = 0xb11134F14d5B94DB60d4599DfdC3bF1bbA2150e8; // wCRCLx
        tokens[19] = 0x59801175a9b2248F9bf4Ba7f82E17045C4672ec8; // wHOODx
        tokens[20] = 0xe2047ee3bdDb5C99ae428AB83df63f8730698e30; // wMUx
        tokens[21] = 0x33AA35B0271FFfE2048Cc093aB7fE60931786719; // wINTCx
        tokens[22] = 0xB4eE60B6B817ca7386422Ef1A0F45EaddEa13275; // wMRVLx
        tokens[23] = 0x75e82E2884Ea10f72FCA777449B73377f4646219; // wSNDKx
        tokens[24] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC
    }
}

abstract contract TradingAccountCreate3 {
    function _predict(bytes32 salt) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt, TradingAccountProdConfig.NICKS_FACTORY);
    }

    function _deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = _predict(salt);
        require(deployed.code.length == 0, "code already exists at predicted address");

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", TradingAccountProdConfig.NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = TradingAccountProdConfig.NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        } else {
            require(proxy.code.length == 8, "unexpected CREATE3 proxy code");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");
        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }
}
