// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title StockRedirectWrappers
 * @author ether.fi
 * @notice The raw Backed xStock -> `WrappedBackedToken` pairs registered as redirect wrappers on
 *         the Ethereum `TopUpFactory`, so a raw xStock landing at a TopUp address can be wrapped
 *         on the way out to the user's TradingSafe.
 *
 * @dev ONE list serves BOTH environments. The dev and prod trading lenses were diffed on
 *      2026-08-14 and listed the identical 90 xStock wrappers, with identical raw and wrapper
 *      addresses — unsurprising, since both read the same Backed deployments on the same chain.
 *      Kept as a single table on purpose: two N-row copies would drift.
 *
 * @dev Derived from two sources, and reproducible from both:
 *      - membership: every token on the `TradingLens` that is an xStock wrapper, read from
 *        `getSupportedTokens()`. Dev lens 0xC6d33e123164e540431165C22dC9D9f09cFb00e9 → 90 of 102
 *        tokens; prod lens 0x7135AD135Ec21ec765C1930E93DEB7DA9c27290C → 90 of 100. The remainder
 *        in each case are plain ERC20s (USDT, WBTC, LINK, PEPE, ...).
 *      - addresses: `GET https://api.xstocks.fi/api/v2/public/assets?network=Ethereum` (paginated,
 *        718 Ethereum deployments at time of writing), whose per-deployment `address` is the raw
 *        stock and `wrapperAddressV2` the wrapper.
 *
 *      Collateral stocks are deliberately absent: wSPYx, wQQQx and wTBLLx back Summer Lend
 *      collateral rather than being redirect targets. On the prod lens they are not listed at all,
 *      so the exclusion is automatic there; on dev, wQQQx / wTBLLx are listed and excluded here.
 *
 *      The pairing is not taken on trust — `TopUpFactory.setRedirectWrappers` reverts unless
 *      `IERC4626(wrapper).asset()` is the raw token it is registered against, so a stale or
 *      transposed row cannot be configured.
 *
 * @dev SLVx (91st row, `scripts/gnosis-txs/ListSlvxEth3CP.s.sol`). wSLVx was a real ERC-4626
 *      wrapper over raw SLVx that had simply never been added to the `TradingLens`, so at the
 *      time of the 2026-08-14 diff it fell out of the lens ∩ xstocks-catalogue intersection this
 *      table is derived from — wGLDx and wPPLTx, the other two bullion xStocks, were already on
 *      the lens and already here. The SLVx listing 3CP adds wSLVx to the lens (tx 1) before this
 *      row is registered (tx 2), so once that bundle lands the lens ∩ catalogue derivation above
 *      holds again without qualification — SLVx is not a special case, just a later addition.
 */
library StockRedirectWrappers {
    /// @return raws Raw Backed xStock tokens, ordered by symbol.
    /// @return wrappers `wrappers[i]` is the ERC-4626 over `raws[i]`.
    function pairs() internal pure returns (address[] memory raws, address[] memory wrappers) {
        raws = new address[](91);
        wrappers = new address[](91);

        raws[0] = 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a; wrappers[0] = 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f; // AAPLx
        raws[1] = 0xfBF2398dF672cEE4aFcC2A4A733222331c742a6A; wrappers[1] = 0x7ad3DA1947926d0685496F6dAa2d786CA7f45E4a; // ABBVx
        raws[2] = 0x89233399708C18Ac6887F90A2B4Cd8Ba5fEdD06e; wrappers[2] = 0x87694E857BD0F7e9F7124088E010058AE30DEb43; // ABTx
        raws[3] = 0x03183Ce31b1656B72A55fa6056e287f50C35BbEB; wrappers[3] = 0xD37a850b99A8b80126E025c2ecFCDf853A1EB77D; // ACNx
        raws[4] = 0x2f9a35aB5dDFBc49927BFdEab98A86c53DC6E763; wrappers[4] = 0x18423155Ea0F0e3c4FeB7DD4660DDc73799C8890; // AMBRx
        raws[5] = 0x3522513E5F146a2006e2901b05f16B2821485E19; wrappers[5] = 0xEe7CcB0d37A12862e7f92F6C92a93d9c2d304266; // AMDx
        raws[6] = 0x3557Ba345B01EFa20A1bdDC61F573BFD87195081; wrappers[6] = 0x910cabdE3EBa7Fc1Ce64fD14bD680b9f60fA0F90; // AMZNx
        raws[7] = 0x50a1291F69D9d3853Def8209cFb1AF0b46927BE1; wrappers[7] = 0x6F4C257A2AEA0653C728979D655526393846757c; // APPx
        raws[8] = 0xC0B417e7F83db438631Eb5E096684dd742E5294F; wrappers[8] = 0x9147b03c16B18FC4F686f610f189f91Ddf4347b4; // ASMLx
        raws[9] = 0x89b2607878ae19baB8020b8140eD550Ef3E953bb; wrappers[9] = 0xF724EB71F31f9def5c0B6b5a52457FC7755A936B; // ASTSx
        raws[10] = 0x38BAC69cbBd28156796e4163B2B6dcb81E336565; wrappers[10] = 0xE89572bfe500ac7E8Ecd8dc8119d274214e06F14; // AVGOx
        raws[11] = 0x5D642505FE1a28897eb3BaBA665F454755D8daA2; wrappers[11] = 0x6985b8D9AD0Dee3981a711fb5304DD974e7dc6c8; // AZNx
        raws[12] = 0x314938c596F5ce31C3f75307d2979338C346D7F2; wrappers[12] = 0x1ABa9C1224f26d9632D67A3E4FC0c8CeA9bBDFe6; // BACx
        raws[13] = 0xaeB681B69E5094E04d11BCeF51A71358A374C3ED; wrappers[13] = 0xdaD5623B32C81AeAa75478fcfe934e9e97018c58; // BMNRx
        raws[14] = 0x12992613fDd35aBe95DEc5a4964331b1ee23B50d; wrappers[14] = 0xC3A8D2e18D33e0800F84cb4ca6529D18fAd225df; // BRK.Bx
        raws[15] = 0x7796F4E23a62eF3653829c21032A9E24bEaf4Cf5; wrappers[15] = 0x0dD03aF27d401EfC721B4F01d906E8dF2e385A90; // BSPx
        raws[16] = 0x60Ae7D760a1C7B528C0384Bc945fadF1438F47A5; wrappers[16] = 0xC4Cc93aC26Edb4C19E3E4886c089fF9b52b8A228; // BTGOx
        raws[17] = 0x7636244Bab612264e1B2dFd4bA6E26d0311b1Eb7; wrappers[17] = 0x05751A815c33557dbe18858cf6b318212e87c218; // CEGx
        raws[18] = 0xBC7170a1280Be28513B4e940C681537EB25e39f4; wrappers[18] = 0x0c9bbdb777764f9767542EFbBdba7d42DD8fE46e; // CMCSAx
        raws[19] = 0x364f210f430eC2448Fc68A49203040F6124096F0; wrappers[19] = 0x44C7eD7fFDF8465c9d27F60AEC845EEd3d49d56e; // COINx
        raws[20] = 0x89BAB39D627A9e34f0dc782C53457e80Ee8Fb9D9; wrappers[20] = 0x8145A751B860f59BfbD5f7D33Aa3126329De107b; // COPXx
        raws[21] = 0x51eD5b74A05F256DbD9Ebb4e4f68Bb41ba10160b; wrappers[21] = 0xA993e90Ed88A6d81a0d213024470Aab8e6E037b9; // CORZx
        raws[22] = 0xfEbDEd1B0986a8ee107f5AB1a1c5a813491DeCEB; wrappers[22] = 0xb11134F14d5B94DB60d4599DfdC3bF1bbA2150e8; // CRCLx
        raws[23] = 0x4A4073f2EAF299A1be22254DCD2C41727F6F54a2; wrappers[23] = 0xE0881D96bd6CD9343D2dAF3F4C6f3830620E2b41; // CRMx
        raws[24] = 0x214151022C2a5E380aB80CdaC31f23Ae554a7345; wrappers[24] = 0xDC7784DE9c30651f094Dfc87D47019796548c0cE; // CRWDx
        raws[25] = 0x053C784cD87B74f42e0c089f98643E79c1A3ff16; wrappers[25] = 0xD54429a08Eb3bA2b828FA79e65229c6d683Bbb6E; // CSCOx
        raws[26] = 0xad5cdc3340904285B8159089974A99a1A09EB4C0; wrappers[26] = 0xEF40ea1cbBaEEe54C753a763A88013AAfdaEeBB7; // CVXx
        raws[27] = 0x521860bB5dF5468358875266B89BFE90d990C6e7; wrappers[27] = 0x9bAD4AF78B27396079a2bDc96300A8eef9a24057; // DFDVx
        raws[28] = 0xdbA228936F4079DaF9Aa906fd48a87f2300405F4; wrappers[28] = 0x65834fF305b82cdbFd8073d79FFe66841B38C648; // DHRx
        raws[29] = 0xBca703C64f616A17b4f2763F34f93400Dbe20F17; wrappers[29] = 0x92A927371744Fb3CBc88b6a6B4C361EaC7501cfD; // ETNx
        raws[30] = 0x2380F2673C640fB67E2d6B55B44C62F0E0e69DA9; wrappers[30] = 0x735f1509Bff25e27Cd442B9bFb231324648eAD9B; // GLDx
        raws[31] = 0xf7F4fAC56f012dE7Dd6adFF54C761986B9E0655a; wrappers[31] = 0x5299041Fd0678c08648fa3b7EE7Bb97e2b84CB30; // GLXYx
        raws[32] = 0xE5f6d3b2405ABdfE6F660e63202B25D23763160d; wrappers[32] = 0x459D3ae62B86cC6125e06260DddFd3AFED24A877; // GMEx
        raws[33] = 0xe92f673Ca36C5E2Efd2DE7628f815f84807e803F; wrappers[33] = 0xf8c5308F80E459bb53d9EbE689854d9cBb2Caa6f; // GOOGLx
        raws[34] = 0x3Ee7E9B3A992fD23CD1C363B0e296856B04ab149; wrappers[34] = 0x53BeebF9167d5cBd9b8E53FE2Deb35E95acB86Ec; // GSx
        raws[35] = 0x766b0CD6ED6D90B5d49d2c36a3761E9728501BA9; wrappers[35] = 0x05b9816f21D9DF559d843d2B20f72a072dAc9cc8; // HDx
        raws[36] = 0x62a48560861B0b451654bFffdb5be6E47aa8ff1B; wrappers[36] = 0xd762788960C607109151eF84EFCCB19c3AD18012; // HONx
        raws[37] = 0xE1385FDd5ffB10081Cd52C56584F25EFa9084015; wrappers[37] = 0x59801175a9b2248F9bf4Ba7f82E17045C4672ec8; // HOODx
        raws[38] = 0xd9913208647671Fe0F48F7F260076B2C6F310Aac; wrappers[38] = 0xbF69D85055642A9C6450BdFDe3C49Baac50F8286; // IBMx
        raws[39] = 0x6a668332825450ACD2e449372057d31b3de16a1E; wrappers[39] = 0xB3Bb8aa61e6fE743f92795b7945C5658C9964c27; // IEMGx
        raws[40] = 0xf8A80D1cb9cFD70D03D655D9dF42339846F3B3C8; wrappers[40] = 0x33AA35B0271FFfE2048Cc093aB7fE60931786719; // INTCx
        raws[41] = 0xdadfb355c6110eda0908740d52c834d6C2BCDDc7; wrappers[41] = 0x25d218F19B706C8680Aa26Fb64e676CF84B58f65; // IWMx
        raws[42] = 0x97FcF4dD5275Ab0De96420CBe36E4C947D5d8edf; wrappers[42] = 0x9503B89937D442348e7Def6dba5e6Cb7D422a27c; // JMKEx
        raws[43] = 0xdb0482cfaD4789798623E64b15eebA01b16e917C; wrappers[43] = 0xB509eB6a307B3603450e7D4446BB0866F3CaE38A; // JNJx
        raws[44] = 0xD9FC3E075d45254a1D834fEa18AF8041207DeA0A; wrappers[44] = 0x15302e0D167EfBcf61129125C89035411842809B; // JPMx
        raws[45] = 0xdCC1a2699441079dA889B1F49e12B69cC791129b; wrappers[45] = 0xE4784B45415AAc58b289f9373314261c788C91e8; // KOx
        raws[46] = 0x15059c599C16Fd8f70B633Ade165502D6402CD49; wrappers[46] = 0x3c1f325660f96864Ecaee6A98511ca0b80a6491b; // LINx
        raws[47] = 0x19c41EA77b34BbDEe61c3A87A75D1ABDA2ED0be4; wrappers[47] = 0x9daea2fe63D4C8A7DF8373909fccB27b640f9516; // LLYx
        raws[48] = 0x9D692bffEf6f6BedF4274053ff9998EFE3B2539E; wrappers[48] = 0xFe3cf5eC058eadFe9592c7cBef59941ADbF0FBbb; // MARAx
        raws[49] = 0xb365Cd2588065F522D379AD19e903304f6B622C6; wrappers[49] = 0x8837d9c0565b05A1dd1907C59EB9222039FB6525; // MAx
        raws[50] = 0x80A77a372c1e12AcCdA84299492f404902E2DA67; wrappers[50] = 0xc6639026a3a862cd4fcbae3f67cB2D25A2959d37; // MCDx
        raws[51] = 0x0588e851ec0418d660BeE81230d6c678dAF21d46; wrappers[51] = 0x5874E07f911496154959E54e88c12773437592Fc; // MDTx
        raws[52] = 0x96702be57Cd9777f835117a809C7124fe4ec989A; wrappers[52] = 0xe840946FfEBCd66B7C4E95095effaFaDfa0D0e56; // METAx
        raws[53] = 0x17D8186Ed8F68059124190D147174D0f6697dc40; wrappers[53] = 0x7d218D8a2ab4c1f03fdd7B655b4E724d48200050; // MRKx
        raws[54] = 0xeAAd46F4146Ded5a47B55AA7F6c48c191dEAEC88; wrappers[54] = 0xB4eE60B6B817ca7386422Ef1A0F45EaddEa13275; // MRVLx
        raws[55] = 0x5621737f42dAE558b81269FcB9E9E70c19Aa6b35; wrappers[55] = 0x166Fbe68274b6a47e025F4ba17388c539f1fa1d0; // MSFTx
        raws[56] = 0xAE2f842EF90C0d5213259Ab82639D5BBF649b08E; wrappers[56] = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB; // MSTRx
        raws[57] = 0xf6a873BAe4Ba1B304e45dF52A4b7D176E1C6a8c4; wrappers[57] = 0xe2047ee3bdDb5C99ae428AB83df63f8730698e30; // MUx
        raws[58] = 0xA6a65AC27E76cD53cB790473E4345c46e5eBf961; wrappers[58] = 0x7d87fD6A379714194a797c0bBB8B40c30D250856; // NFLXx
        raws[59] = 0xc845b2894dBddd03858fd2D643B4eF725fE0849d; wrappers[59] = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5; // NVDAx
        raws[60] = 0xF9523E369c5f55ad72DbAA75B0a9b92B3D8b147e; wrappers[60] = 0x02c7eba704fC8DD930BC07252eb178104b8d96cb; // NVOx
        raws[61] = 0xbEe6b69345F376598Fe16AbD5592c6F844825E66; wrappers[61] = 0x08B2987505E7A3FF5874a20eA7caE9433814Ed3F; // OPENx
        raws[62] = 0x548308E91ec9F285C7bFf05295baDBD56a6e4971; wrappers[62] = 0x1349456830Ddc3D8599E4d6A63698883Eca67ADa; // ORCLx
        raws[63] = 0x36c424a6EC0e264b1616102Ad63eD2aD7857413e; wrappers[63] = 0x9622a9983F254f45a188BDAF3b3BbFB5343E5493; // PEPx
        raws[64] = 0x1Ac765B5BEa23184802C7d2d497f7c33f1444A9e; wrappers[64] = 0x8bBaD91B2b3dd25DF162C2FE3bCe67ad556d1B4B; // PFEx
        raws[65] = 0xa90424D5D3E770e8644103AB503ed775dD1318FD; wrappers[65] = 0xf8154adaA88Cb3929B27EE627A530ED9fFA17e49; // PGx
        raws[66] = 0x6d482CeC5f9dd1f05CCee9Fd3ff79B246170F8e2; wrappers[66] = 0x4A2df09536F62341C9f946427D16414C04e21342; // PLTRx
        raws[67] = 0x02a6c1789c3B4FDb1a7a3DfA39F90e5d3c94F4F9; wrappers[67] = 0xC10a58d806d80c632CF5475cc3357E5c9cA0d48B; // PMx
        raws[68] = 0x8e9e4a8d7f1C65dcB42D9103832b27E75946055D; wrappers[68] = 0xe00f467a97D3D53DF1C5Ef05cc40c349aCA74c2F; // PPLTx
        raws[69] = 0x6Ac47387f0a2798dF4C4eE5bb31ab9517ac97cb8; wrappers[69] = 0x7220192353B02Dde0392eeD5aa39109071770900; // RIOTx
        raws[70] = 0x338791c58fdED314b81EAb139A1A2Fb7967D90d6; wrappers[70] = 0x05F6035b7c42F7ACd13249C56f4ca7eBe52eEb83; // SBETx
        raws[71] = 0xF6D87E523512704C29E9b7cA3e9e6226bDCE3EA1; wrappers[71] = 0xb461ACb818F5cB3E9dB1F23D4D4a2018B5Cb4988; // SCHFx
        raws[72] = 0x58100046a4Afcd4eE4faDbD4244f3f895a341c56; wrappers[72] = 0x6215a58ed045d71F2561AaAbe54f4C885C522998; // SKHYx
        raws[73] = 0x4833e7f4f0460f4B72A3a5879A6C9841bCC5B58B; wrappers[73] = 0xB842EacB35Fd9c1bEDA53749072Ef22823f2cA8c; // SLVx
        raws[74] = 0xb63EFBc28860c8097e341DE1fCF59456161E9D98; wrappers[74] = 0x75e82E2884Ea10f72FCA777449B73377f4646219; // SNDKx
        raws[75] = 0x7F8ba411ECBC0A135d669d5EaE5D15b0Ca0b0ea1; wrappers[75] = 0x705c971E9F919b36AB396C76EE02BBAA07b0862E; // SPCEx
        raws[76] = 0x68fa48B1C2FE52b3D776E1953e0E782b5044Ce28; wrappers[76] = 0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072; // SPCXx
        raws[77] = 0x1Aad217B8F78dbA5E6693460e8470F8b1A3977f3; wrappers[77] = 0x0B2456017C5Df2dFc0289740C4b352049892780C; // STRCx
        raws[78] = 0xAF072F109A2C173D822a4fe9af311A1B18F83d19; wrappers[78] = 0x5C730581A6a33c64c26Eb06014A5fd163Ba71ab4; // TMOx
        raws[79] = 0xe95ab205e333443D7970336D5fD827eF9eD97608; wrappers[79] = 0xf0ad3df8643b2f8554DB983529CD3f4A892748b0; // TONXx
        raws[80] = 0xfDDDb57878eF9D6f681Ec4381DCB626b9E69AC86; wrappers[80] = 0x0b6cEC8Ded816651dB478411fDc2c5bFc269b1e1; // TQQQx
        raws[81] = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0; wrappers[81] = 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171; // TSLAx
        raws[82] = 0x9e3bf4Ecfc44EeDD624F26656B6736a3F093b073; wrappers[82] = 0x27D62249488fc66ECBb92C8da3F56f700B8e8501; // TSMx
        raws[83] = 0xdb9783Ca04bBD64fe2c6d7B9503A979b3DE30729; wrappers[83] = 0x1789a222C560DDd62E7E422d64D82E3Fe2BF7eCC; // UBERx
        raws[84] = 0x167A6375DA1eFc4a5BE0f470E73eCEfd66245048; wrappers[84] = 0x1F652b05eFB825a068304972BC506Fb43Fac4D6F; // UNHx
        raws[85] = 0xbD730E618bcD88C82dDeE52e10275CF2f88A4777; wrappers[85] = 0x2eE96832126dC446808BaBcbCc9A04905114f880; // VTIx
        raws[86] = 0x6d5edEEbBc6A4099Eb8bb289EB3b80D799f7b28C; wrappers[86] = 0x0e61556b8c1CfE86257003B2F3d689FF875911D4; // VTx
        raws[87] = 0x2363FD1235C1B6d3A5088DdF8dF3A0b3A30C5293; wrappers[87] = 0x11704Bb8fDf32Af2f70fB3F085d437b9b3E66a94; // Vx
        raws[88] = 0x7AEfc9965699fBea943e03264d96e50CD4A97b21; wrappers[88] = 0x3b4336e3958913984C2E36b8Ed0E7C87a5bDee33; // WMTx
        raws[89] = 0x6F75AC3b1b6Fbe8Bb5F948e25aF03620f26Ae838; wrappers[89] = 0x577954fcDb16755d2AC02a5a0F305E45AD13Fcff; // XLEx
        raws[90] = 0xEEdb0273c5Af792745180e9fF568cD01550fFA13; wrappers[90] = 0xe407Ca0C99338d210Ca06Aa9E4A5Eada8BE442de; // XOMx
    }
}
