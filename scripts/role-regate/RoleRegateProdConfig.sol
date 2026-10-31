// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title RoleRegateProdConfig
 * @notice Shared constants for the cash-v3 #356 prod rollout (deploy, 3CP and verify scripts), so a pin cannot drift
 *         between them. Every new address is the CREATE3 address of its salt through the EtherFiDeployer; the scripts
 *         check that. The live constructor args were read on 2026-10-31: Midas from the live module's constructor
 *         call (no MidasVaultsAdded or MidasVaultsRemoved since its deploy at OP block 157542931), the deposit module
 *         from its constructor call (no LiquidAssetsAdded beyond the constructor's, no LiquidAssetsRemoved since
 *         Ethereum block 26041478), Frax, LendGateway and LiquidUSDLiquifierOP from their immutables.
 */
abstract contract RoleRegateProdConfig {
    // ─────────────────────────────── governance ───────────────────────────────

    /// @dev Governance Safe, proposer and executor on the 2-day upgrade timelock on both chains
    address internal constant GOVERNANCE_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Admin Timelock Safe (OP), proposer and executor on the 8-hour operating timelock
    address internal constant ADMIN_TIMELOCK_SAFE = 0x47992A4E7920EE57eb3dD06131C1a086963b240B;
    /// @dev Owns the cash RoleRegistry (OP) and the trading RoleRegistry (Ethereum)
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    /// @dev Sole ADMIN_TIMELOCK_ROLE holder on the cash RoleRegistry (OP)
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 internal constant UPGRADE_DELAY = 2 days;
    uint256 internal constant OPERATING_DELAY = 8 hours;

    // ─────────────────────────────── salts ───────────────────────────────

    string internal constant LIB_SALT = "Prod.RoleRegate.Optimism.LendReserveLib";
    string internal constant OP_DP_IMPL_SALT = "Prod.RoleRegate.Optimism.EtherFiDataProviderImpl";
    string internal constant SETTERS_SALT = "Prod.RoleRegate.Optimism.CashModuleSetters";
    string internal constant GW_IMPL_SALT = "Prod.RoleRegate.Optimism.LendGatewayImpl";
    string internal constant LIQUIFIER_IMPL_SALT = "Prod.RoleRegate.Optimism.LiquidUSDLiquifierOPImpl";
    string internal constant FRAX_SALT = "Prod.RoleRegate.Optimism.FraxModule";
    string internal constant MIDAS_SALT = "Prod.RoleRegate.Optimism.MidasModule";
    string internal constant ETH_DP_IMPL_SALT = "Prod.RoleRegate.Ethereum.EtherFiDataProviderImpl";
    string internal constant DEPOSIT_SALT = "Prod.RoleRegate.Ethereum.TradingSafeLiquidDepositModule";

    // ─────────────────────────────── Optimism: new ───────────────────────────────

    address internal constant LEND_RESERVE_LIB = 0xd65eCb4E22D578Bc732d51AAa4F0449D225fd723;
    address internal constant OP_DP_IMPL = 0x8851270e83e7281266b7bdF8cd6B52A2421d7bB4;
    address internal constant NEW_SETTERS = 0x84ae75c9b2A38dDA378AE89960AD4cba4Cc99636;
    address internal constant NEW_GW_IMPL = 0x5b8F1931a8763195303E66969e93187f98C42779;
    address internal constant NEW_LIQUIFIER_IMPL = 0x4315a0C0a35b78eBcF7317Fc179c037Afbc18ba5;
    address internal constant NEW_FRAX = 0xBf5B06EA58c51D8eC0728d78928B8F38c4102720;
    address internal constant NEW_MIDAS = 0x78ae8D275A80AD6635B74e70e2358478E9c3Fd3E;

    // ─────────────────────────────── Optimism: live ───────────────────────────────

    address internal constant OP_DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address internal constant OP_ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address internal constant CASH_MODULE = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;
    address internal constant OP_LEND_GATEWAY = 0x01F8cDFb1694eA8fE4ED6c38a0fD78d1188E03F4;
    address internal constant OP_LIQUIFIER = 0x39161A44588ec2327a18D4707EA5216C721ba539;
    address internal constant OLD_FRAX = 0x3C97a4899a92b7e84d92c5032dC7d865E7471EcE;
    address internal constant OLD_MIDAS = 0x1052fDcE6CBE3D2AD265050e1426D41E23fc54dc;
    address internal constant OLD_OP_DP_IMPL = 0x7b0c84E0959F92725D7ed2c0E83317A633bE3191;
    address internal constant OLD_SETTERS = 0x7a6F89881B252f3EC4a269891A73c16BE8BAE254;
    address internal constant OLD_GW_IMPL = 0x43d1c047CC32bC08507e9B27758ACBdDedf7083F;
    address internal constant OLD_LIQUIFIER_IMPL = 0x606A50FE014603e47D108bcCB415BFC260C880b1;

    address internal constant AAVE_SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address internal constant DEBT_MANAGER = 0x0078C5a459132e279056B2371fE8A8eC973A9553;
    address internal constant FRAXUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address internal constant FRAX_CUSTODIAN = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address internal constant FRAX_REMOTE_HOP = 0x31D982ebd82Ad900358984bd049207A4c2468640;

    // ─────────────────────────────── Ethereum ───────────────────────────────

    address internal constant ETH_DP_IMPL = 0x3ff2c902e756ed4662205ecD7d9710419770a39b;
    address internal constant NEW_DEPOSIT_MODULE = 0x68D7207234c9c05d2a206c1A28D86e229F7565dC;
    address internal constant ETH_DATA_PROVIDER = 0xcaC7ec798A9561B00Ff2F3C7505a0C2c1B543d0C;
    address internal constant ETH_ROLE_REGISTRY = 0xBdAe3A2EfDFf4f27Dc1D89E0BEdb88F3e9A62Bd0;
    address internal constant OLD_ETH_DP_IMPL = 0x595ECE3e8b75B2292921A07405D68707909C59E0;
    address internal constant OLD_DEPOSIT_MODULE = 0x94c7A5bcC41ccF40e366115eaA9150d4B3ebD815;
    address internal constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address internal constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev The live MidasModule's constructor args, in its order: liquidRESERVE, weEUR, liquidRWA
    function _midasArgs() internal pure returns (address[] memory tokens, address[] memory deposits, address[] memory redemptions) {
        tokens = new address[](3);
        deposits = new address[](3);
        redemptions = new address[](3);
        tokens[0] = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898; // liquidRESERVE
        deposits[0] = 0x1561eC30da97108Df46535CBd9bAD8C8d8611B3a;
        redemptions[0] = 0xC87b51735ea5Eeee59D3e12601dC931F77F2837a;
        tokens[1] = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13; // weEUR
        deposits[1] = 0xF1b45eE795C8e1B858e191654C95A1B33c573632;
        redemptions[1] = 0xDC87653FCc5c16407Cd2e199d5Db48BaB71e7861;
        tokens[2] = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e; // liquidRWA
        deposits[2] = 0x97b30c9D53A010009136b830f8A12f8d5624Bc43;
        redemptions[2] = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;
    }

    /// @dev The live TradingSafeLiquidDepositModule's constructor args
    function _depositArgs() internal pure returns (address[] memory assets, address[] memory tellers) {
        assets = new address[](1);
        tellers = new address[](1);
        assets[0] = LIQUID_BTC;
        tellers[0] = LIQUID_BTC_TELLER;
    }
}
