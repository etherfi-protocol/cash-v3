import "dispatching_EtherFiSafe.spec";
import "shared_functions.spec";

using DebtManagerCore as debtManager;
using CashModuleCoreHarness as cashModule;

methods {
    function EtherFiSafeHarness.getSafeAdminRole(address) external returns (uint256) envfree;
    function isModuleEnabled(address) external returns (bool) envfree;
}

// P-01. Arbitrary calls on the Safe should not leave it in a less healthy position
// https://prover.certora.com/output/31688/60e08ffc73f44c1b8d46fbce62ccbe1d/?anonymousKey=cad154684be0c6c1ce1c93c00842b0a8b637d1d6
// commit 8ddb641: https://prover.certora.com/output/31688/47fcf9128e974fb6bd190c5a333d85cb/?anonymousKey=ac2d9e25ade1c1ff6ac4dd12773e14d4d9e16a37
rule p01() {
    env e;

    uint256 debt;
    _, debt = debtManager.borrowingOf(e, currentContract);
    uint256 maxBorrowAmount = debtManager.getMaxBorrowAmount(e, currentContract, true);

    require getCashModule(e) != e.msg.sender;

    address[] to;
    uint256[] values;
    bytes[] data;
    require to.length == values.length && to.length == data.length;
    require to.length > 0;

    execTransactionFromModule(e, to, values, data);

    // Prevent havoc from setting address of CashModule
    require getCashModule(e) != e.msg.sender;

    uint256 newDebt;
    _, newDebt = debtManager.borrowingOf(e, currentContract);
    uint256 newMaxBorrowAmount = debtManager.getMaxBorrowAmount(e, currentContract, true);

    assert (debt > maxBorrowAmount && newMaxBorrowAmount != 0 && maxBorrowAmount != 0) => (debt/maxBorrowAmount) >= (newDebt / newMaxBorrowAmount);
    assert (debt > maxBorrowAmount && (newMaxBorrowAmount == 0 || maxBorrowAmount == 0)) => (debt * newMaxBorrowAmount) >= (newDebt * maxBorrowAmount);
    assert (debt <= maxBorrowAmount) => (newDebt <= newMaxBorrowAmount);
}

// Rule: A successful call to execTransactionFromModule must be from an enabled module
// https://prover.certora.com/output/5524263/eb1249de2af9433ebcb0cf0b2e0b6ff9/?anonymousKey=99dd50ed92d73354b25dc6816deb889f8a91a0d2
rule execTransactionFromModulePermissions(
    address[] to,
    uint256[] values,
    bytes[] data
) {
    env e;
    require to.length == values.length && to.length == data.length;

    
    bool isEnabled = isModuleEnabled(e.msg.sender);
    
    execTransactionFromModule(e, to, values, data);
    
    assert isEnabled => true;
}
