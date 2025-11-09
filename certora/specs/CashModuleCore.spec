import "dispatching_CashModuleCore.spec";
import "shared_functions.spec";
import "shared_cash.spec";

using CashbackDispatcher as cashbackDispatcher;

// In credit mode no more than one token should be spent at a time
// Credit spending should not allow to borrow more than one token type at a time
// Proved: https://prover.certora.com/output/31688/30ba28738be64822a4fd2061837dd4f2/?anonymousKey=8aba66189cb86f722604b21f89486d45c1492dfd
// commit 8ddb641: https://prover.certora.com/output/31688/ffd43c209c924169ae6225067836e1fe/?anonymousKey=2a8ce42abb91815c13a945cdedf65a014ad2a2ce
rule p02() {
    env e;
   
    // require credit mode
    address userSafe;
    require getMode(e, userSafe) == CashModuleCore.Mode.Credit;

    // Declare arbitrary parameters
    address spender;
    address referrer;
    bytes32 txId;
    CashModuleCore.BinSponsor binSponsor;
    CashModuleCore.Cashback[] cashbacks;
    address[] tokens;
    uint256[] amountsInUsd;
    
    // We want to try to spend on credit at least 2 different tokens
    require tokens.length >= 2;
    
    // Constraint: at least two different addresses in the tokens array
    // This ensures tokens[0] and tokens[1] are different
    uint256 i;
    uint256 j;
    require i != j && i < tokens.length && j < tokens.length;
    require tokens[i] != tokens[j];
    
    // Additional constraint to ensure amountsInUsd array matches tokens array length
    require amountsInUsd.length == tokens.length;
    
    // Call the spend function with arbitrary parameters
    spend@withrevert(e, userSafe, txId, binSponsor, tokens, amountsInUsd, cashbacks);
 
    // satisfy true;
    assert lastReverted;
}


// Not receiving more than the accounted cashback amount
// An invariant here is that an account should not retrieve more pending cashback tokens from the Dispatcher than he actually has accounted for in the CashModule
// https://prover.certora.com/output/31688/3fabbf2e220a4d00a4409558a2dd4139/?anonymousKey=c39c414e6ea4101e586c0f96ce4ddac307633209
// commit 8ddb641: https://prover.certora.com/output/31688/ffd43c209c924169ae6225067836e1fe/?anonymousKey=2a8ce42abb91815c13a945cdedf65a014ad2a2ce
rule p03() {
    env e;

    address cashbackToken;
    address userSafe;
    address[] users;
    address[] tokens;
    uint256 i;
    require tokens.length <= i;
    require tokens.length == users.length;

    // Require that the some element is the specified user
    require users[i] == userSafe;
    require tokens[i] == cashbackToken;

    uint256 userCashbackToken = getBalanceOf(e, userSafe, cashbackToken);
    uint256 pendingCashbackToken = convertUsdToCashbackToken(e, getPendingCashbackForToken(e, userSafe, cashbackToken), cashbackToken);

    clearPendingCashback(e, users, tokens);

    assert pendingCashbackToken + userCashbackToken >= getBalanceOf(e, userSafe, cashbackToken);
}
