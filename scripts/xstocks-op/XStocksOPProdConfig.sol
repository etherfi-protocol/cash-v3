// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev One stock of the Phase 1 rollout: the raw Backed token and its ERC-4626 wrapper (same address on
///      Ethereum and Optimism), the LayerZero stand-in it replaces on Optimism, and the feed identity.
struct XStock {
    string symbol;
    address raw;
    address wrapper;
    address standIn;
    string legKey; // summer-lend-feeds.json key of the <STOCK>/USD Aave v4 leg already in use
    string feedKey; // summer-lend-feeds.json key written for the wrapper feed
    string feedSalt; // CREATE3 salt name of the wrapper feed
    string feedDesc; // wrapper feed description
}

/**
 * @title XStocksOPProd
 * @notice Fixed addresses and identity strings for moving SPYx, QQQx and TBLLx collateral from the LayerZero
 *         stand-ins to Backed's native Optimism wrappers. Everything else the bundles need (modules, feeds,
 *         risk parameters) is read live or from the deployment manifests at generation time.
 */
library XStocksOPProd {
    // ---------------------------------------------------------------- governance (verified on chain 2026-10-02)
    /// @dev Operating Safe: ADMIN_ROLE plus the module admin roles on Optimism, RoleRegistry owner on Ethereum
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev RoleRegistry owner on Optimism: upgrades
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    /// @dev ADMIN_TIMELOCK_ROLE holder on both chains: module setters, TopUpFactory token config
    address internal constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 internal constant UPGRADE_DELAY = 2 days;
    uint256 internal constant ADMIN_DELAY = 8 hours;
    /// @dev Admin Safe (3 of 6): proposer and executor on the 8h admin timelock, signs what it schedules
    address internal constant ADMIN_SAFE = 0x47992A4E7920EE57eb3dD06131C1a086963b240B;
    /// @dev Upgrade Safe (4 of 7): proposer and executor on the 2d upgrade timelock, signs what it schedules
    address internal constant UPGRADE_SAFE = 0xBAf0E1af05c5ab8Bb709d13e1B6DeDd53b492588;
    /// @dev EtherFiTimelock of the Summer Lend instance; pranked on forks to rehearse the aave-v4 listing
    address internal constant LEND_TIMELOCK = 0xbaCa0cD6B69Eef3257e2D122b22ddEE8AeE5e283;

    // ---------------------------------------------------------------- Backed bridge (same address on both chains)
    address internal constant BACKED_BRIDGE = 0x9eC0e4A4c411493773E01e2ABF4D42395788846b;
    uint64 internal constant ETHEREUM_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant OPTIMISM_SELECTOR = 3_734_403_246_176_062_136;
    uint256 internal constant OP_CHAIN_ID = 10;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    // ---------------------------------------------------------------- deployment manifest keys and salts
    string internal constant KEY_MIGRATION = "StockMigrationModule";
    string internal constant KEY_WRAP = "StockWrapModule";
    string internal constant KEY_BRIDGE_WITHDRAW = "StockBridgeWithdrawModule";
    string internal constant KEY_TOP_UP_DEST_IMPL = "TopUpDestImplV2";
    string internal constant KEY_CCIP_ADAPTER = "BackedCCIPBridgeAdapter";
    string internal constant KEY_CCIP_WRAPPER_ADAPTER = "BackedCCIPWrapperBridgeAdapter";
    string internal constant SALT_PREFIX = "XStocksOP.";
    string internal constant SALT_CCIP_ADAPTER = "Prod.StockTopup.BackedCCIPBridgeAdapter";
    string internal constant SALT_CCIP_WRAPPER_ADAPTER = "Prod.StockTopup.BackedCCIPWrapperBridgeAdapter";

    function stocks() internal pure returns (XStock[] memory) {
        XStock[] memory list = new XStock[](3);
        list[0] = XStock({ symbol: "SPYx", raw: 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48, wrapper: 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, standIn: 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c, legKey: "SPY", feedKey: "wSPYx", feedSalt: "XStocksOP.WSpyxUsdFeed", feedDesc: "wSPYx / USD" });
        list[1] = XStock({ symbol: "QQQx", raw: 0xa753A7395cAe905Cd615Da0B82A53E0560f250af, wrapper: 0x4C1AE29c159838fC1b224636E28E086EB69101f7, standIn: 0x3c99d3a81b27583B2E26dbd387C10411f2763516, legKey: "QQQ", feedKey: "wQQQx", feedSalt: "XStocksOP.WQqqxUsdFeed", feedDesc: "wQQQx / USD" });
        list[2] = XStock({ symbol: "TBLLx", raw: 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b, wrapper: 0x461b25b99606Fe169D6F0dD6816650eF6536403E, standIn: 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387, legKey: "TBLL", feedKey: "wTBLLx", feedSalt: "XStocksOP.WTbllxUsdFeed", feedDesc: "wTBLLx / USD" });
        return list;
    }

    function raws() internal pure returns (address[] memory) {
        XStock[] memory list = stocks();
        address[] memory out = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            out[i] = list[i].raw;
        }
        return out;
    }

    function wrappers() internal pure returns (address[] memory) {
        XStock[] memory list = stocks();
        address[] memory out = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            out[i] = list[i].wrapper;
        }
        return out;
    }

    function standIns() internal pure returns (address[] memory) {
        XStock[] memory list = stocks();
        address[] memory out = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            out[i] = list[i].standIn;
        }
        return out;
    }

    /// @dev The 20 Phase 2 stocks the top-up service watches on Ethereum: the only raw stocks that get a
    ///      TopUpFactory route, since a route disables TopUpV2.executeRecovery for that token. The other 71
    ///      stay recoverable and get a route when they are listed for top-ups.
    function phase2TopUpRaws() internal pure returns (address[] memory) {
        address[] memory out = new address[](20);
        out[0] = 0x68fa48B1C2FE52b3D776E1953e0E782b5044Ce28; // SPCXx
        out[1] = 0x4833e7f4f0460f4B72A3a5879A6C9841bCC5B58B; // SLVx
        out[2] = 0x12992613fDd35aBe95DEc5a4964331b1ee23B50d; // BRK.Bx
        out[3] = 0xfEbDEd1B0986a8ee107f5AB1a1c5a813491DeCEB; // CRCLx
        out[4] = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0; // TSLAx
        out[5] = 0xe92f673Ca36C5E2Efd2DE7628f815f84807e803F; // GOOGLx
        out[6] = 0x364f210f430eC2448Fc68A49203040F6124096F0; // COINx
        out[7] = 0xc845b2894dBddd03858fd2D643B4eF725fE0849d; // NVDAx
        out[8] = 0xf8A80D1cb9cFD70D03D655D9dF42339846F3B3C8; // INTCx
        out[9] = 0xAE2f842EF90C0d5213259Ab82639D5BBF649b08E; // MSTRx
        out[10] = 0x3522513E5F146a2006e2901b05f16B2821485E19; // AMDx
        out[11] = 0x96702be57Cd9777f835117a809C7124fe4ec989A; // METAx
        out[12] = 0x9e3bf4Ecfc44EeDD624F26656B6736a3F093b073; // TSMx
        out[13] = 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a; // AAPLx
        out[14] = 0xE1385FDd5ffB10081Cd52C56584F25EFa9084015; // HOODx
        out[15] = 0x5621737f42dAE558b81269FcB9E9E70c19Aa6b35; // MSFTx
        out[16] = 0x1Aad217B8F78dbA5E6693460e8470F8b1A3977f3; // STRCx
        out[17] = 0x3557Ba345B01EFa20A1bdDC61F573BFD87195081; // AMZNx
        out[18] = 0x2380F2673C640fB67E2d6B55B44C62F0E0e69DA9; // GLDx
        out[19] = 0xb63EFBc28860c8097e341DE1fCF59456161E9D98; // SNDKx
        return out;
    }

    function flags(uint256 len, bool value) internal pure returns (bool[] memory) {
        bool[] memory out = new bool[](len);
        for (uint256 i; i < len; ++i) {
            out[i] = value;
        }
        return out;
    }
}
