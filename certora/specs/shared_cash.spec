methods {
    function CashModuleCoreHarness.getSafeAdminRole(address) external returns (uint256) envfree;
}

definition executesRepay(method f) returns bool =
    f.selector == sig:repay(address, address, uint256).selector;

definition executesBorrow(method f) returns bool =
    f.selector == sig:spend(address, bytes32, CashModuleCoreHarness.BinSponsor,  address[],  uint256[],  CashModuleCoreHarness.Cashback[]).selector;

definition executesTransfer(method f) returns bool =
    f.selector == sig:spend(address, bytes32, CashModuleCoreHarness.BinSponsor,  address[],  uint256[],  CashModuleCoreHarness.Cashback[]).selector ||
    f.selector == sig:postLiquidate(address, address, IDebtManager.LiquidationTokenData[]).selector ||
    f.selector == sig:processWithdrawal(address).selector ||
    f.selector == sig:requestWithdrawal(address, address[], uint256[], address, address[], bytes[]).selector;


function callSpend(env e, address userSafe) {
    bytes32 txId;
    CashModuleCore.BinSponsor binSponsor;
    address[] tokens;
    uint256[] amountsInUsd;
    CashModuleCore.Cashback[] cashbacks;

    require amountsInUsd.length == tokens.length;
    spend(e, userSafe, txId, binSponsor, tokens, amountsInUsd, cashbacks);
}
