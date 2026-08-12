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

    /// @dev HyperNative's automated-response executor. Already holds PAUSER on the cash registries
    ///      via 3CP-558 (Optimism) and 3CP-559 (Ethereum + 4 top-up source chains); the trading
    ///      stack's own registry was stood up later and never covered.
    address internal constant HYPERNATIVE_EXECUTOR = 0x9AF1298993DC1f397973C62A5D47a284CF76844D;

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
    /// @dev The withdraw module is immutable, so there is no impl/proxy pair to salt separately.
    bytes32 internal constant SALT_TRADING_SAFE_WITHDRAW_MODULE = keccak256("TradingAccount.Prod.v1.TradingSafeWithdrawModule");

    function supportedTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](104);
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
        tokens[25] = 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f; // wAAPLx
        tokens[26] = 0x7ad3DA1947926d0685496F6dAa2d786CA7f45E4a; // wABBVx
        tokens[27] = 0x87694E857BD0F7e9F7124088E010058AE30DEb43; // wABTx
        tokens[28] = 0xD37a850b99A8b80126E025c2ecFCDf853A1EB77D; // wACNx
        tokens[29] = 0x18423155Ea0F0e3c4FeB7DD4660DDc73799C8890; // wAMBRx
        tokens[30] = 0x910cabdE3EBa7Fc1Ce64fD14bD680b9f60fA0F90; // wAMZNx
        tokens[31] = 0x6F4C257A2AEA0653C728979D655526393846757c; // wAPPx
        tokens[32] = 0x9147b03c16B18FC4F686f610f189f91Ddf4347b4; // wASMLx
        tokens[33] = 0xF724EB71F31f9def5c0B6b5a52457FC7755A936B; // wASTSx
        tokens[34] = 0xE89572bfe500ac7E8Ecd8dc8119d274214e06F14; // wAVGOx
        tokens[35] = 0x6985b8D9AD0Dee3981a711fb5304DD974e7dc6c8; // wAZNx
        tokens[36] = 0x1ABa9C1224f26d9632D67A3E4FC0c8CeA9bBDFe6; // wBACx
        tokens[37] = 0xdaD5623B32C81AeAa75478fcfe934e9e97018c58; // wBMNRx
        tokens[38] = 0xC3A8D2e18D33e0800F84cb4ca6529D18fAd225df; // wBRK.Bx
        tokens[39] = 0x0dD03aF27d401EfC721B4F01d906E8dF2e385A90; // wBSPx
        tokens[40] = 0xC4Cc93aC26Edb4C19E3E4886c089fF9b52b8A228; // wBTGOx
        tokens[41] = 0x05751A815c33557dbe18858cf6b318212e87c218; // wCEGx
        tokens[42] = 0x0c9bbdb777764f9767542EFbBdba7d42DD8fE46e; // wCMCSAx
        tokens[43] = 0x44C7eD7fFDF8465c9d27F60AEC845EEd3d49d56e; // wCOINx
        tokens[44] = 0x8145A751B860f59BfbD5f7D33Aa3126329De107b; // wCOPXx
        tokens[45] = 0xA993e90Ed88A6d81a0d213024470Aab8e6E037b9; // wCORZx
        tokens[46] = 0xE0881D96bd6CD9343D2dAF3F4C6f3830620E2b41; // wCRMx
        tokens[47] = 0xDC7784DE9c30651f094Dfc87D47019796548c0cE; // wCRWDx
        tokens[48] = 0xD54429a08Eb3bA2b828FA79e65229c6d683Bbb6E; // wCSCOx
        tokens[49] = 0xEF40ea1cbBaEEe54C753a763A88013AAfdaEeBB7; // wCVXx
        tokens[50] = 0x9bAD4AF78B27396079a2bDc96300A8eef9a24057; // wDFDVx
        tokens[51] = 0x65834fF305b82cdbFd8073d79FFe66841B38C648; // wDHRx
        tokens[52] = 0x92A927371744Fb3CBc88b6a6B4C361EaC7501cfD; // wETNx
        tokens[53] = 0x735f1509Bff25e27Cd442B9bFb231324648eAD9B; // wGLDx
        tokens[54] = 0x5299041Fd0678c08648fa3b7EE7Bb97e2b84CB30; // wGLXYx
        tokens[55] = 0x459D3ae62B86cC6125e06260DddFd3AFED24A877; // wGMEx
        tokens[56] = 0xf8c5308F80E459bb53d9EbE689854d9cBb2Caa6f; // wGOOGLx
        tokens[57] = 0x53BeebF9167d5cBd9b8E53FE2Deb35E95acB86Ec; // wGSx
        tokens[58] = 0x05b9816f21D9DF559d843d2B20f72a072dAc9cc8; // wHDx
        tokens[59] = 0xd762788960C607109151eF84EFCCB19c3AD18012; // wHONx
        tokens[60] = 0xbF69D85055642A9C6450BdFDe3C49Baac50F8286; // wIBMx
        tokens[61] = 0xB3Bb8aa61e6fE743f92795b7945C5658C9964c27; // wIEMGx
        tokens[62] = 0x25d218F19B706C8680Aa26Fb64e676CF84B58f65; // wIWMx
        tokens[63] = 0x9503B89937D442348e7Def6dba5e6Cb7D422a27c; // wJMKEx
        tokens[64] = 0xB509eB6a307B3603450e7D4446BB0866F3CaE38A; // wJNJx
        tokens[65] = 0x15302e0D167EfBcf61129125C89035411842809B; // wJPMx
        tokens[66] = 0xE4784B45415AAc58b289f9373314261c788C91e8; // wKOx
        tokens[67] = 0x3c1f325660f96864Ecaee6A98511ca0b80a6491b; // wLINx
        tokens[68] = 0x9daea2fe63D4C8A7DF8373909fccB27b640f9516; // wLLYx
        tokens[69] = 0xFe3cf5eC058eadFe9592c7cBef59941ADbF0FBbb; // wMARAx
        tokens[70] = 0x8837d9c0565b05A1dd1907C59EB9222039FB6525; // wMAx
        tokens[71] = 0xc6639026a3a862cd4fcbae3f67cB2D25A2959d37; // wMCDx
        tokens[72] = 0x5874E07f911496154959E54e88c12773437592Fc; // wMDTx
        tokens[73] = 0x7d218D8a2ab4c1f03fdd7B655b4E724d48200050; // wMRKx
        tokens[74] = 0x7d87fD6A379714194a797c0bBB8B40c30D250856; // wNFLXx
        tokens[75] = 0x02c7eba704fC8DD930BC07252eb178104b8d96cb; // wNVOx
        tokens[76] = 0x08B2987505E7A3FF5874a20eA7caE9433814Ed3F; // wOPENx
        tokens[77] = 0x1349456830Ddc3D8599E4d6A63698883Eca67ADa; // wORCLx
        tokens[78] = 0x9622a9983F254f45a188BDAF3b3BbFB5343E5493; // wPEPx
        tokens[79] = 0x8bBaD91B2b3dd25DF162C2FE3bCe67ad556d1B4B; // wPFEx
        tokens[80] = 0xf8154adaA88Cb3929B27EE627A530ED9fFA17e49; // wPGx
        tokens[81] = 0x4A2df09536F62341C9f946427D16414C04e21342; // wPLTRx
        tokens[82] = 0xC10a58d806d80c632CF5475cc3357E5c9cA0d48B; // wPMx
        tokens[83] = 0xe00f467a97D3D53DF1C5Ef05cc40c349aCA74c2F; // wPPLTx
        tokens[84] = 0x7220192353B02Dde0392eeD5aa39109071770900; // wRIOTx
        tokens[85] = 0x05F6035b7c42F7ACd13249C56f4ca7eBe52eEb83; // wSBETx
        tokens[86] = 0xb461ACb818F5cB3E9dB1F23D4D4a2018B5Cb4988; // wSCHFx
        tokens[87] = 0x6215a58ed045d71F2561AaAbe54f4C885C522998; // wSKHYx
        tokens[88] = 0x705c971E9F919b36AB396C76EE02BBAA07b0862E; // wSPCEx
        tokens[89] = 0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072; // wSPCXx
        tokens[90] = 0x0B2456017C5Df2dFc0289740C4b352049892780C; // wSTRCx
        tokens[91] = 0x461b25b99606Fe169D6F0dD6816650eF6536403E; // wTBLLx
        tokens[92] = 0x5C730581A6a33c64c26Eb06014A5fd163Ba71ab4; // wTMOx
        tokens[93] = 0xf0ad3df8643b2f8554DB983529CD3f4A892748b0; // wTONXx
        tokens[94] = 0x0b6cEC8Ded816651dB478411fDc2c5bFc269b1e1; // wTQQQx
        tokens[95] = 0x27D62249488fc66ECBb92C8da3F56f700B8e8501; // wTSMx
        tokens[96] = 0x1789a222C560DDd62E7E422d64D82E3Fe2BF7eCC; // wUBERx
        tokens[97] = 0x1F652b05eFB825a068304972BC506Fb43Fac4D6F; // wUNHx
        tokens[98] = 0x2eE96832126dC446808BaBcbCc9A04905114f880; // wVTIx
        tokens[99] = 0x0e61556b8c1CfE86257003B2F3d689FF875911D4; // wVTx
        tokens[100] = 0x11704Bb8fDf32Af2f70fB3F085d437b9b3E66a94; // wVx
        tokens[101] = 0x3b4336e3958913984C2E36b8Ed0E7C87a5bDee33; // wWMTx
        tokens[102] = 0x577954fcDb16755d2AC02a5a0F305E45AD13Fcff; // wXLEx
        tokens[103] = 0xe407Ca0C99338d210Ca06Aa9E4A5Eada8BE442de; // wXOMx
    }
}

abstract contract TradingAccountCreate3 {
    function _predict(bytes32 salt) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt, TradingAccountProdConfig.NICKS_FACTORY);
    }

    function _deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = _predict(salt);
        // Idempotent: CREATE3 addresses are deterministic, so an already-populated address means this
        // contract was deployed by a prior (possibly partial) run. Reuse it instead of reverting.
        if (deployed.code.length > 0) return deployed;

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
