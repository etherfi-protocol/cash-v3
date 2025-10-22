import "dispatching_DebtManagerCore.spec";
import "shared_functions.spec";

using CashbackDispatcher as cashbackDispatcher;

methods {
    function DebtManagerCoreHarness.getSafeAdminRole(address) external returns (uint256) envfree;
}

// User normalized debt should not increase, without the balances of the Debt manager increasing as well
// https://prover.certora.com/output/31688/b429e01e1f41495ebf06015ae1187dc5/?anonymousKey=7e7c2fbb173a4c9eadf70a79febbc82bfd3ab81d
// https://prover.certora.com/output/31688/4e6b108904834852a696183312e3b7d9/?anonymousKey=7c97f9df77f14f5e0a7980ad988827ea78135305
// commit 8ddb641: https://prover.certora.com/output/31688/9057beb15aa647bfbfb7c02b699b09c9/?anonymousKey=140d410eac2a0d0b3cb2e0a89b7be184812a6724
rule p04(method f) filtered { f -> f.contract == currentContract && !f.isView && f.selector != sig:upgradeToAndCall(address,bytes).selector} {
  env e;
  address user;
  address token;
  uint256 origDebt = getNormalizedDebt(e, user, token);
  uint256 origBalance = getBalanceOf(e, currentContract, token);

  uint256 amount;
  if (f.selector == sig:repay(address,address,uint256).selector) {
    repay(e, user, token, amount);
  }
  else if (f.selector == sig:borrow(DebtManagerCoreHarness.BinSponsor,address,uint256).selector) {
    DebtManagerCoreHarness.BinSponsor binSponsor;
    require (getSettlementDispatcher(e, binSponsor) != currentContract);
    require (e.msg.sender == user); // we want user to borrow, since it does not make sense to check debt of some other user
    borrow(e, binSponsor, token, amount);
  } else {
    calldataarg args;
    f(e, args);
  }

  if (f.selector == sig:withdrawBorrowToken(address,uint256).selector) {
    assert origDebt == getNormalizedDebt(e, user, token);
  } else if (f.selector == sig:supply(address,address,uint256).selector) {
    assert getBalanceOf(e, currentContract, token) >= origBalance && origDebt == getNormalizedDebt(e, user, token);
  } else {
    assert getBalanceOf(e, currentContract, token) > origBalance <=> origDebt > getNormalizedDebt(e, user, token);
    assert getBalanceOf(e, currentContract, token) == origBalance <=> origDebt == getNormalizedDebt(e, user, token);
    assert getBalanceOf(e, currentContract, token) < origBalance <=> origDebt < getNormalizedDebt(e, user, token);
  }
}

// $.userNormalizedBorrowings[account][token] should never be  > than debt + fee. In practical terms calling borrowingOf(account, token) should not return an amount that is less than $.userNormalizedBorrowings
// https://prover.certora.com/output/31688/df34fe32a4eb4b9d9876673a0eacb5dc/?anonymousKey=956a74b2c8de24e05304495f8eacce4b759d72e8
// commit 8ddb641: https://prover.certora.com/output/31688/9057beb15aa647bfbfb7c02b699b09c9/?anonymousKey=140d410eac2a0d0b3cb2e0a89b7be184812a6724
rule p05(method f) filtered {f -> f.contract == currentContract && !f.isView && f.selector != sig:upgradeToAndCall(address,bytes).selector} {
  env e;
  address userSafe;
  address token;
  require borrowingOf(e, userSafe, token) >= getNormalizedDebt(e, userSafe, token);

  if (f.selector == sig:borrow(DebtManagerCoreHarness.BinSponsor,address,uint256).selector) {
    DebtManagerCoreHarness.BinSponsor binSponsor;
    uint256 amount;
    borrow(e, binSponsor, token, amount);
    require getInterestIndex(e, token) >= 10^18;
  } else if (f.selector == sig:liquidate(address, address, address[]).selector) {
    address[] collateralTokensPreference;
    liquidate(e, userSafe, token,  collateralTokensPreference);
    require getInterestIndex(e, token) >= 10^18;
  } else {
    calldataarg args;
    f(e, args);
  }

  assert borrowingOf(e, userSafe, token) >= getNormalizedDebt(e, userSafe, token);
}
