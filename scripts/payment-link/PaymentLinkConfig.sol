// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title PaymentLinkConfig
 * @author ether.fi
 * @notice Shared configuration for the PaymentLinkModule deploy, verify and 3CP scripts on
 *         Optimism: env-prefixed CREATE3 salts (dev and prod land at distinct deterministic
 *         addresses through the EtherFiDeployer), the pinned addresses those salts resolve to,
 *         the prod governance addresses and the fee.
 * @dev The dev instance is a separate deployment on Optimism mainnet that registers only with
 *      the dev cash-v3 stack (deployments/dev/10). There are no testnet or fork environments.
 */
abstract contract PaymentLinkConfig is EtherFiDeployerHelper, ContractCodeChecker {
    using stdJson for string;

    // ---- CREATE3 salts (env-prefixed) ----

    string internal constant DEV_SALT_MODULE_IMPL = "Dev.PaymentLink.PaymentLinkModuleImpl.V2";
    string internal constant DEV_SALT_MODULE_PROXY = "Dev.PaymentLink.PaymentLinkModuleProxy.V2";
    string internal constant PROD_SALT_MODULE_IMPL = "Prod.PaymentLink.PaymentLinkModuleImpl";
    string internal constant PROD_SALT_MODULE_PROXY = "Prod.PaymentLink.PaymentLinkModuleProxy";

    // ---- Pinned addresses ----
    //
    // CREATE3 addresses are a pure function of the salt strings and the EtherFiDeployer address,
    // so pinning them turns a salt typo into a loud pre-broadcast failure instead of a deploy at
    // an address that off-chain consumers and the enable bundle do not expect.

    /// @notice `Dev.PaymentLink.PaymentLinkModuleImpl.V2` (Optimism).
    address internal constant EXPECTED_DEV_MODULE_IMPL = 0x7ead558E8e8918590414d2B8E4A02E18716d45d8;
    /// @notice `Dev.PaymentLink.PaymentLinkModuleProxy.V2` (Optimism).
    address internal constant EXPECTED_DEV_MODULE_PROXY = 0x3753EB90B48028e64f4F042E08358b00E9B11822;
    /// @notice `Prod.PaymentLink.PaymentLinkModuleImpl` (Optimism).
    address internal constant EXPECTED_PROD_MODULE_IMPL = 0x4d3B98947f10c36FE495110186fF854aB0F5593f;
    /// @notice `Prod.PaymentLink.PaymentLinkModuleProxy` (Optimism).
    address internal constant EXPECTED_PROD_MODULE_PROXY = 0x7402a988651bAF0558642647e0D7366D939d35c4;

    // ---- Prod governance (Optimism, deployments/mainnet/10/roles.json) ----

    /// @notice Prod Safe: proposer and executor on both timelocks, holds PAUSER and UNPAUSER.
    address internal constant PROD_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @notice 8h operating timelock; the only holder of `ADMIN_TIMELOCK_ROLE` on Optimism.
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    /// @notice `OPERATING_TIMELOCK.getMinDelay()`.
    uint256 internal constant OPERATING_TIMELOCK_DELAY = 8 hours;
    /// @notice 2-day upgrade timelock; owner of the prod RoleRegistry, so the module's upgrader.
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;

    // ---- Fees ----

    /// @notice The proxy is initialised with the fee off, and the module launches with it off:
    ///         the enable step (3CP on prod) does not call `setFee`, so claims carry no fee. An
    ///         unprivileged deployer key never chooses a fee receiver.
    uint16 internal constant DEPLOY_FEE_BPS = 0;
    address internal constant DEPLOY_FEE_RECEIVER = address(0);

    // ---- Token allowlist ----

    // Launch tokens: the assets on CashModule's Optimism withdraw-asset list that suit the escrow.
    // Each must move exact amounts in and out of the module and must not rebase;
    // test/payment-link/PaymentLinkLaunchTokens.t.sol round-trips every one against the real token
    // contract on a fork. Issuer powers such as pause, deny lists and admin burn remain. Left out: LayerZero copies of three xStock wrappers that are listed in
    // their native form, and a retired token whose admin can redeem any holder's balance. Further
    // tokens are allowed later through another timelocked `setTokenAllowed`, under the same condition.

    /// @notice USDC (native, Circle). 6 decimals.
    address internal constant LAUNCH_TOKEN_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    /// @notice EURC (Circle). 6 decimals.
    address internal constant LAUNCH_TOKEN_EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    /// @notice USDT0 (symbol "USD₮0"), not the legacy bridged USDT. 6 decimals.
    address internal constant LAUNCH_TOKEN_USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    /// @notice ZCHF (Frankencoin). 18 decimals.
    address internal constant LAUNCH_TOKEN_ZCHF = 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553;
    /// @notice WETH (the WETH9 predeploy). 18 decimals.
    address internal constant LAUNCH_TOKEN_WETH = 0x4200000000000000000000000000000000000006;

    /// @dev The launch tokens, in the order the enable batch allows them.
    function _launchTokens() internal pure returns (address[] memory tokens) {
        address[119] memory list = [
            // Stablecoins and WETH
            LAUNCH_TOKEN_USDC,
            LAUNCH_TOKEN_EURC,
            LAUNCH_TOKEN_USDT0,
            LAUNCH_TOKEN_ZCHF,
            LAUNCH_TOKEN_WETH,
            // Other assets: ether.fi tokens and vault shares, USDT, frxUSD, OP, HYPE, gold
            0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF, // weETH
            0x94b008aA00579c1307B0EF2c499aD98a8ce58e58, // USDT
            0x86B5780b606940Eb59A062aA85a07959518c0161, // sETHFI
            0x80Eede496655FB9047dd39d9f418d5483ED600df, // frxUSD
            0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C, // liquidUSD
            0x657e8C867D8B37dCC18fA4Caead9C45EB088C642, // eBTC
            0xf0bb20865277aBd641a307eCe5Ee04E79073416C, // liquidETH
            0x5f46d540b6eD704C3c8789105F30E075AA900726, // liquidBTC
            0x939778D83b46B456224A33Fb59630B11DEC56663, // eUSD
            0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f, // ETHFI
            0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E, // WHYPE
            0xA519AfBc91986c0e7501d7e34968FEE51CD901aC, // beHYPE
            0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898, // liquidReserve
            0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13, // liquidEUR
            0x17bC8Ffd82b8a36e737Ca1141C025089589B915e, // liquidRWA
            0x4200000000000000000000000000000000000042, // OP
            0x41a7f2bb9789199654c206f09392674c1Af6676c, // iPAXG
            0x5168E0cDeb3f308F47fDF0D9A2E250A2135C3cF5, // iPAXGy
            0x4299b11815F25DB50fC56CD8a1C24cCCDD2AEECe, // liquidDeFi
            // xStock wrappers: ERC-4626 shares over Backed's xStocks on Optimism. The underlying
            // xStock rebases through a multiplier; the wrapper's share balances don't rebase.
            0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, // wSPYx
            0x4C1AE29c159838fC1b224636E28E086EB69101f7, // wQQQx
            0x461b25b99606Fe169D6F0dD6816650eF6536403E, // wTBLLx
            0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f, // wAAPLx
            0x7ad3DA1947926d0685496F6dAa2d786CA7f45E4a, // wABBVx
            0x87694E857BD0F7e9F7124088E010058AE30DEb43, // wABTx
            0xD37a850b99A8b80126E025c2ecFCDf853A1EB77D, // wACNx
            0x18423155Ea0F0e3c4FeB7DD4660DDc73799C8890, // wAMBRx
            0xEe7CcB0d37A12862e7f92F6C92a93d9c2d304266, // wAMDx
            0x910cabdE3EBa7Fc1Ce64fD14bD680b9f60fA0F90, // wAMZNx
            0xabec6AeAb037b77c09a2a99264F9C81a35B02649, // wANTx
            0x6F4C257A2AEA0653C728979D655526393846757c, // wAPPx
            0x9147b03c16B18FC4F686f610f189f91Ddf4347b4, // wASMLx
            0xF724EB71F31f9def5c0B6b5a52457FC7755A936B, // wASTSx
            0xE89572bfe500ac7E8Ecd8dc8119d274214e06F14, // wAVGOx
            0x6985b8D9AD0Dee3981a711fb5304DD974e7dc6c8, // wAZNx
            0x1ABa9C1224f26d9632D67A3E4FC0c8CeA9bBDFe6, // wBACx
            0xdaD5623B32C81AeAa75478fcfe934e9e97018c58, // wBMNRx
            0xC3A8D2e18D33e0800F84cb4ca6529D18fAd225df, // wBRK.Bx
            0x0dD03aF27d401EfC721B4F01d906E8dF2e385A90, // wBSPx
            0xC4Cc93aC26Edb4C19E3E4886c089fF9b52b8A228, // wBTGOx
            0x05751A815c33557dbe18858cf6b318212e87c218, // wCEGx
            0x0c9bbdb777764f9767542EFbBdba7d42DD8fE46e, // wCMCSAx
            0x44C7eD7fFDF8465c9d27F60AEC845EEd3d49d56e, // wCOINx
            0x8145A751B860f59BfbD5f7D33Aa3126329De107b, // wCOPXx
            0xA993e90Ed88A6d81a0d213024470Aab8e6E037b9, // wCORZx
            0xb11134F14d5B94DB60d4599DfdC3bF1bbA2150e8, // wCRCLx
            0xE0881D96bd6CD9343D2dAF3F4C6f3830620E2b41, // wCRMx
            0xDC7784DE9c30651f094Dfc87D47019796548c0cE, // wCRWDx
            0xD54429a08Eb3bA2b828FA79e65229c6d683Bbb6E, // wCSCOx
            0xEF40ea1cbBaEEe54C753a763A88013AAfdaEeBB7, // wCVXx
            0x9bAD4AF78B27396079a2bDc96300A8eef9a24057, // wDFDVx
            0x65834fF305b82cdbFd8073d79FFe66841B38C648, // wDHRx
            0x92A927371744Fb3CBc88b6a6B4C361EaC7501cfD, // wETNx
            0x735f1509Bff25e27Cd442B9bFb231324648eAD9B, // wGLDx
            0x5299041Fd0678c08648fa3b7EE7Bb97e2b84CB30, // wGLXYx
            0x459D3ae62B86cC6125e06260DddFd3AFED24A877, // wGMEx
            0xf8c5308F80E459bb53d9EbE689854d9cBb2Caa6f, // wGOOGLx
            0x53BeebF9167d5cBd9b8E53FE2Deb35E95acB86Ec, // wGSx
            0x05b9816f21D9DF559d843d2B20f72a072dAc9cc8, // wHDx
            0xd762788960C607109151eF84EFCCB19c3AD18012, // wHONx
            0x59801175a9b2248F9bf4Ba7f82E17045C4672ec8, // wHOODx
            0xbF69D85055642A9C6450BdFDe3C49Baac50F8286, // wIBMx
            0xB3Bb8aa61e6fE743f92795b7945C5658C9964c27, // wIEMGx
            0x33AA35B0271FFfE2048Cc093aB7fE60931786719, // wINTCx
            0x25d218F19B706C8680Aa26Fb64e676CF84B58f65, // wIWMx
            0x9503B89937D442348e7Def6dba5e6Cb7D422a27c, // wJMKEx
            0xB509eB6a307B3603450e7D4446BB0866F3CaE38A, // wJNJx
            0x15302e0D167EfBcf61129125C89035411842809B, // wJPMx
            0xE4784B45415AAc58b289f9373314261c788C91e8, // wKOx
            0x3c1f325660f96864Ecaee6A98511ca0b80a6491b, // wLINx
            0x9daea2fe63D4C8A7DF8373909fccB27b640f9516, // wLLYx
            0xFe3cf5eC058eadFe9592c7cBef59941ADbF0FBbb, // wMARAx
            0x8837d9c0565b05A1dd1907C59EB9222039FB6525, // wMAx
            0xc6639026a3a862cd4fcbae3f67cB2D25A2959d37, // wMCDx
            0x5874E07f911496154959E54e88c12773437592Fc, // wMDTx
            0xe840946FfEBCd66B7C4E95095effaFaDfa0D0e56, // wMETAx
            0x7d218D8a2ab4c1f03fdd7B655b4E724d48200050, // wMRKx
            0xB4eE60B6B817ca7386422Ef1A0F45EaddEa13275, // wMRVLx
            0x166Fbe68274b6a47e025F4ba17388c539f1fa1d0, // wMSFTx
            0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB, // wMSTRx
            0xe2047ee3bdDb5C99ae428AB83df63f8730698e30, // wMUx
            0x7d87fD6A379714194a797c0bBB8B40c30D250856, // wNFLXx
            0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5, // wNVDAx
            0x02c7eba704fC8DD930BC07252eb178104b8d96cb, // wNVOx
            0x08B2987505E7A3FF5874a20eA7caE9433814Ed3F, // wOPENx
            0x1349456830Ddc3D8599E4d6A63698883Eca67ADa, // wORCLx
            0x9622a9983F254f45a188BDAF3b3BbFB5343E5493, // wPEPx
            0x8bBaD91B2b3dd25DF162C2FE3bCe67ad556d1B4B, // wPFEx
            0xf8154adaA88Cb3929B27EE627A530ED9fFA17e49, // wPGx
            0x4A2df09536F62341C9f946427D16414C04e21342, // wPLTRx
            0xC10a58d806d80c632CF5475cc3357E5c9cA0d48B, // wPMx
            0xe00f467a97D3D53DF1C5Ef05cc40c349aCA74c2F, // wPPLTx
            0x7220192353B02Dde0392eeD5aa39109071770900, // wRIOTx
            0x05F6035b7c42F7ACd13249C56f4ca7eBe52eEb83, // wSBETx
            0xb461ACb818F5cB3E9dB1F23D4D4a2018B5Cb4988, // wSCHFx
            0x6215a58ed045d71F2561AaAbe54f4C885C522998, // wSKHYx
            0xB842EacB35Fd9c1bEDA53749072Ef22823f2cA8c, // wSLVx
            0x75e82E2884Ea10f72FCA777449B73377f4646219, // wSNDKx
            0x705c971E9F919b36AB396C76EE02BBAA07b0862E, // wSPCEx
            0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072, // wSPCXx
            0x0B2456017C5Df2dFc0289740C4b352049892780C, // wSTRCx
            0x5C730581A6a33c64c26Eb06014A5fd163Ba71ab4, // wTMOx
            0xf0ad3df8643b2f8554DB983529CD3f4A892748b0, // wTONXx
            0x0b6cEC8Ded816651dB478411fDc2c5bFc269b1e1, // wTQQQx
            0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171, // wTSLAx
            0x27D62249488fc66ECBb92C8da3F56f700B8e8501, // wTSMx
            0x1789a222C560DDd62E7E422d64D82E3Fe2BF7eCC, // wUBERx
            0x1F652b05eFB825a068304972BC506Fb43Fac4D6F, // wUNHx
            0x2eE96832126dC446808BaBcbCc9A04905114f880, // wVTIx
            0x0e61556b8c1CfE86257003B2F3d689FF875911D4, // wVTx
            0x11704Bb8fDf32Af2f70fB3F085d437b9b3E66a94, // wVx
            0x3b4336e3958913984C2E36b8Ed0E7C87a5bDee33, // wWMTx
            0x577954fcDb16755d2AC02a5a0F305E45AD13Fcff, // wXLEx
            0xe407Ca0C99338d210Ca06Aa9E4A5Eada8BE442de // wXOMx
        ];
        tokens = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            tokens[i] = list[i];
        }
    }

    // ---- Storage slots read by the verifiers ----

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev UpgradeableProxy ERC-7201 slot; its first member is the roleRegistry (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;
    /// @dev OZ v5 Initializable ERC-7201 slot; the low 8 bytes are `_initialized`.
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev Optimism chain id.
    uint256 internal constant OPTIMISM_CHAIN_ID = 10;

    // ---- Env-derived selectors ----

    /// @dev The target environment, from ENV (`dev` or `mainnet`, default `mainnet`). Virtual so
    ///      script tests can pick an environment without mutating the process-wide ENV variable.
    function _env() internal view virtual returns (string memory) {
        return getEnv();
    }

    /// @dev True when the target is dev; picks salts, the deployments file and the privileged-call path.
    function _isDev() internal view returns (bool) {
        return isEqualString(_env(), "dev");
    }

    function _moduleImplSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_IMPL : PROD_SALT_MODULE_IMPL;
    }

    function _moduleProxySalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_PROXY : PROD_SALT_MODULE_PROXY;
    }

    function _expectedImpl() internal view returns (address) {
        return _isDev() ? EXPECTED_DEV_MODULE_IMPL : EXPECTED_PROD_MODULE_IMPL;
    }

    function _expectedProxy() internal view returns (address) {
        return _isDev() ? EXPECTED_DEV_MODULE_PROXY : EXPECTED_PROD_MODULE_PROXY;
    }

    // ---- Stack addresses ----

    struct Stack {
        EtherFiDataProvider dataProvider;
        RoleRegistry roleRegistry;
        ICashModule cashModule;
    }

    /// @dev Reads the cash-v3 stack for `env` from deployments/{env}/10/deployments.json,
    ///      independently of the ENV variable (so dev scripts can also read prod).
    function _stack(string memory env) internal view returns (Stack memory s) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", env, "/10/deployments.json"));
        s.dataProvider = EtherFiDataProvider(json.readAddress(".addresses.EtherFiDataProvider"));
        s.roleRegistry = RoleRegistry(json.readAddress(".addresses.RoleRegistry"));
        s.cashModule = ICashModule(json.readAddress(".addresses.CashModule"));
    }

    /// @dev The stack the current environment targets.
    function _currentStack() internal view returns (Stack memory) {
        return _stack(_env());
    }

    // ---- Guards ----

    /// @dev Both envs' salts must resolve to the pinned addresses, and dev must never alias prod.
    function _assertPinnedAddresses() internal view {
        require(_predictAddress(DEV_SALT_MODULE_IMPL) == EXPECTED_DEV_MODULE_IMPL, "dev impl salt does not resolve to the pinned address");
        require(_predictAddress(DEV_SALT_MODULE_PROXY) == EXPECTED_DEV_MODULE_PROXY, "dev proxy salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_MODULE_IMPL) == EXPECTED_PROD_MODULE_IMPL, "prod impl salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_MODULE_PROXY) == EXPECTED_PROD_MODULE_PROXY, "prod proxy salt does not resolve to the pinned address");
    }

    /// @dev The stack is internally consistent: the module is built against exactly this
    ///      DataProvider, its CashModule and its RoleRegistry. On dev it must not be the prod stack.
    function _assertStack(Stack memory s) internal view {
        require(address(s.dataProvider).code.length > 0, "DataProvider has no code");
        require(s.dataProvider.getCashModule() == address(s.cashModule), "DataProvider.getCashModule() != deployments CashModule");
        require(address(s.dataProvider.roleRegistry()) == address(s.roleRegistry), "DataProvider.roleRegistry() != deployments RoleRegistry");
        if (_isDev()) {
            Stack memory prod = _stack("mainnet");
            require(address(s.dataProvider) != address(prod.dataProvider), "dev stack resolves to the prod DataProvider");
            require(address(s.cashModule) != address(prod.cashModule), "dev stack resolves to the prod CashModule");
            require(address(s.roleRegistry) != address(prod.roleRegistry), "dev stack resolves to the prod RoleRegistry");
        }
    }

    /**
     * @dev Deployment checks: what sits at the pinned addresses must be exactly what this commit builds and
     *      deploys. A CREATE3 address commits to neither bytecode nor constructor state, so:
     *      - the impl's immutables must be THIS stack's DataProvider and CashModule (checked by
     *        getter: the code comparison alone would accept other addresses whose code matches,
     *        such as another stack's proxies);
     *      - the impl must equal a local build byte for byte once EVERY copy of the local build's
     *        own address (UUPS `__self`) is rebound to the impl's address (`_requireImplCodeMatch`),
     *        and the proxy must match a local `UUPSProxy` exactly and point at that impl;
     *      - the impl's `proxiableUUID()` must answer when called directly (defence in depth: the
     *        rebinding comparison already rejects any `__self` copy that is not the impl);
     *      - the proxy must have run its initializer exactly once and the impl's initializers
     *        must be disabled (`_requireInitialized`), so nobody can initialize it later.
     *      Runtime code and these slots cannot prove the rest of the proxy's storage is empty: a
     *      custom constructor could seed links. The enable 3CP therefore also checks the proxy's
     *      deployment transaction (`_requireProxyProvenance`).
     */
    function _requireBuiltCode(Stack memory s, address impl, address proxy) internal {
        PaymentLinkModule deployed = PaymentLinkModule(impl);
        require(address(deployed.etherFiDataProvider()) == address(s.dataProvider), "PaymentLinkModule impl: etherFiDataProvider immutable is not this stack's");
        require(address(deployed.cashModule()) == address(s.cashModule), "PaymentLinkModule impl: cashModule immutable is not this stack's");

        address localImpl = address(new PaymentLinkModule(address(s.dataProvider), address(s.cashModule)));
        _requireImplCodeMatch(impl, localImpl);
        requireExactCodeMatch("PaymentLinkModuleProxy", proxy, address(new UUPSProxy(localImpl, "")));
        require(_implOf(proxy) == impl, "PaymentLinkModule: proxy impl slot does not point at the verified impl - possible hijack");
        try UUPSUpgradeable(impl).proxiableUUID() returns (bytes32 slot) {
            require(slot == EIP1967_IMPL_SLOT, "PaymentLinkModule impl: unexpected proxiableUUID");
        } catch {
            revert("PaymentLinkModule impl: proxiableUUID reverts when called directly - embedded __self is not the impl address");
        }
        _requireInitialized(impl, proxy);
    }

    /**
     * @dev Exact implementation comparison. The impl's only address-dependent bytes are its UUPS
     *      `__self` immutable, which the compiler copies into several places; the other immutables
     *      (DataProvider, CashModule) are the same constructor arguments on both sides. So rebind
     *      every 20-byte copy of `localImpl` in the local build to `impl` and require the result
     *      to equal the deployed code exactly. Unlike `requireCodeMatchAllowingAddressEmbeds`,
     *      which skips bytes that already match, this rejects a deployed impl that keeps one
     *      `__self` copy (say the one `proxiableUUID` reads) correct and points another (say the
     *      one `_checkProxy` compares against) elsewhere, including at `localImpl` itself.
     */
    function _requireImplCodeMatch(address impl, address localImpl) internal view {
        require(impl.code.length != 0, "PaymentLinkModuleImpl: not deployed on-chain");
        bytes memory expected = localImpl.code;
        bytes20 from = bytes20(localImpl);
        bytes20 to = bytes20(impl);
        uint256 rebound;
        for (uint256 i = 0; i + 20 <= expected.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20 && hit; j++) {
                hit = expected[i + j] == from[j];
            }
            if (!hit) continue;
            for (uint256 j = 0; j < 20; j++) {
                expected[i + j] = to[j];
            }
            rebound++;
            i += 19;
        }
        require(rebound > 0, "PaymentLinkModuleImpl: local build embeds no own address - comparison would be meaningless");
        require(keccak256(impl.code) == keccak256(expected), "PaymentLinkModuleImpl: bytecode differs from the local build with every __self rebound to the impl");
    }

    /// @dev The proxy initcode the deploy script sends to the EtherFiDeployer: `UUPSProxy` with
    ///      `impl` and the atomic `initialize(roleRegistry, 0, address(0))` call. The 3CP's
    ///      provenance check compares against the same bytes.
    function _expectedProxyInitCode(Stack memory s, address impl) internal pure returns (bytes memory) {
        bytes memory initData = abi.encodeCall(PaymentLinkModule.initialize, (address(s.roleRegistry), DEPLOY_FEE_BPS, DEPLOY_FEE_RECEIVER));
        return abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    // ---- Deployment provenance ----

    /// @dev What `_requireProxyProvenance` needs from a transaction.
    struct DeployTx {
        address to;
        bytes input;
        bool success;
        bytes32 blockHash;
        uint256 blockNumber;
    }

    /**
     * @dev Requires `txHash` to be a successful direct call to `EtherFiDeployer.deploy` with the
     *      proxy salt and exactly `_expectedProxyInitCode`, mined in a finalized block that is an
     *      ancestor of the state under review. `deploy` reverts when the CREATE3 address is
     *      occupied, so such a call proves this initcode created the proxy and that its storage is
     *      only what `UUPSProxy`'s constructor and `initialize` wrote, not something a custom
     *      constructor seeded. See `_requireCanonicalOnReviewedChain` for the chain binding.
     */
    function _requireProxyProvenance(Stack memory s, address impl, string memory proxySalt, bytes32 txHash) internal {
        require(txHash != bytes32(0), "proxy deploy tx hash not provided (set PAYMENT_LINK_PROXY_DEPLOY_TX)");
        DeployTx memory t = _fetchTx(txHash);
        require(t.success, "proxy deploy tx did not succeed");
        require(t.to == address(DEPLOYER), "proxy deploy tx was not a direct call to the EtherFiDeployer");
        bytes memory expected = abi.encodeCall(EtherFiDeployer.deploy, (getSalt(proxySalt), _expectedProxyInitCode(s, impl)));
        require(keccak256(t.input) == keccak256(expected), "proxy deploy tx is not the expected EtherFiDeployer.deploy call - proxy storage unverified");
        _requireCanonicalOnReviewedChain(t.blockHash, t.blockNumber);
    }

    /**
     * @dev Binds a block to the history of the state this script reviews. The transaction comes
     *      from the provenance endpoint, and the fork only exposes `blockhash` for its last 256
     *      blocks, so the endpoint is anchored to the fork first:
     *      1. the endpoint's canonical hash at the fork's parent height equals the fork's own
     *         `blockhash` there, so both follow the same chain and branch;
     *      2. the endpoint's canonical hash at `blockNumber` equals `blockHash`, so the block was
     *         not reorged out (a block the node merely knows, on an abandoned branch, fails);
     *      3. `blockNumber` is below the fork's head (an ancestor of the reviewed state) and at or
     *         below the endpoint's finalized head, so it cannot be reorged out later.
     *      The endpoint is trusted not to fabricate answers; this guards against pointing it at
     *      another chain, another fork or a reorged branch.
     */
    function _requireCanonicalOnReviewedChain(bytes32 blockHash, uint256 blockNumber) internal {
        require(block.number > 1 && blockNumber < block.number - 1, "proxy deploy tx's block is not before the state under review");
        bytes32 forkParent = blockhash(block.number - 1);
        require(forkParent != bytes32(0) && _castBlockHash(vm.toString(block.number - 1)) == forkParent, "provenance RPC does not follow the chain under review");
        require(_castBlockHash(vm.toString(blockNumber)) == blockHash, "proxy deploy tx's block is not canonical on the chain under review");
        require(blockNumber <= _castDecimal(_castArgs3("block", "finalized", "--field", "number")), "proxy deploy tx's block is not finalized yet");
    }

    /// @dev Reads a transaction's recipient, calldata, status and block from Optimism through
    ///      `cast` (ffi, enabled in foundry.toml). Virtual for script tests.
    function _fetchTx(bytes32 txHash) internal virtual returns (DeployTx memory t) {
        string memory hash = vm.toString(txHash);
        bytes memory to = _castArgs3("tx", hash, "to", "");
        require(to.length == 20, "could not read the deploy tx recipient");
        t.to = address(bytes20(to));
        t.input = _castArgs3("tx", hash, "input", "");
        bytes32 status = keccak256(_castArgs3("receipt", hash, "status", ""));
        t.success = status == keccak256("true") || status == keccak256("1") || status == keccak256("0x1") || status == keccak256(hex"01");
        bytes memory blockHash = _castArgs3("receipt", hash, "blockHash", "");
        require(blockHash.length == 32, "could not read the deploy tx block hash");
        t.blockHash = bytes32(blockHash);
        t.blockNumber = _castDecimal(_castArgs3("receipt", hash, "blockNumber", ""));
    }

    /// @dev RPC for the provenance reads: PAYMENT_LINK_PROVENANCE_RPC, else OPTIMISM_RPC, else the
    ///      public endpoint (an empty variable counts as unset). Virtual for script tests.
    function _provenanceRpc() internal view virtual returns (string memory) {
        string memory rpc = vm.envOr("PAYMENT_LINK_PROVENANCE_RPC", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("OPTIMISM_RPC", string(""));
        if (bytes(rpc).length == 0) rpc = "https://mainnet.optimism.io";
        return rpc;
    }

    function _castBlockHash(string memory blockNumber) internal returns (bytes32) {
        bytes memory h = _castArgs3("block", blockNumber, "--field", "hash");
        require(h.length == 32, "could not read a block hash from the provenance RPC");
        return bytes32(h);
    }

    /// @dev `cast <a> <b> <c> [<d>] --rpc-url <provenance RPC>` through ffi; empty `d` is omitted.
    function _castArgs3(string memory a, string memory b, string memory c, string memory d) internal returns (bytes memory) {
        bool withD = bytes(d).length > 0;
        string[] memory cmd = new string[](withD ? 7 : 6);
        cmd[0] = "cast";
        cmd[1] = a;
        cmd[2] = b;
        cmd[3] = c;
        uint256 i = 4;
        if (withD) cmd[i++] = d;
        cmd[i++] = "--rpc-url";
        cmd[i] = _provenanceRpc();
        return vm.ffi(cmd);
    }

    /// @dev Parses a decimal number printed by `cast`. ffi hex-decodes output that looks like hex,
    ///      which an even-length run of digits does; re-printing those bytes as hex restores them.
    function _castDecimal(bytes memory out) internal pure returns (uint256) {
        bool digits = out.length > 0;
        for (uint256 i = 0; i < out.length && digits; i++) {
            digits = out[i] >= "0" && out[i] <= "9";
        }
        if (digits) return vm.parseUint(string(out));
        string memory asHex = vm.toString(out); // "0x" + the original digits
        bytes memory stripped = new bytes(bytes(asHex).length - 2);
        for (uint256 i = 0; i < stripped.length; i++) {
            stripped[i] = bytes(asHex)[i + 2];
        }
        return vm.parseUint(string(stripped));
    }

    /// @dev The whole OZ Initializable slot, not just the version: the proxy is at version 1 and
    ///      not mid-initialization; the impl is locked at `type(uint64).max`.
    function _requireInitialized(address impl, address proxy) internal view {
        require(uint256(vm.load(proxy, INITIALIZABLE_STORAGE_SLOT)) == 1, "proxy not initialised exactly once");
        require(uint256(vm.load(impl, INITIALIZABLE_STORAGE_SLOT)) == uint256(type(uint64).max), "impl initializers not disabled");
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function _registryOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
    }

    /// @dev Every launch token must be on CashModule's withdraw-asset list: allowing a token
    ///      CashModule cannot withdraw would make every `requestLink` in it revert.
    function _requireLaunchTokensWithdrawable(ICashModule cashModule) internal view {
        address[] memory listed = cashModule.getWhitelistedWithdrawAssets();
        address[] memory tokens = _launchTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            bool found;
            for (uint256 j = 0; j < listed.length && !found; j++) {
                found = listed[j] == tokens[i];
            }
            require(found, string.concat("launch token not on CashModule's withdraw-asset list: ", vm.toString(tokens[i])));
        }
    }

    function _canRequestWithdraw(ICashModule cashModule, address module) internal view returns (bool) {
        address[] memory allowed = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == module) return true;
        }
        return false;
    }
}
