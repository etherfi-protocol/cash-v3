import "dispatching_EtherFiSafe.spec";
import "shared_functions.spec";

using DebtManagerCore as debtManager;
using CashModuleCoreHarness as cashModule;

methods {
    function EtherFiSafeHarness.getSafeAdminRole(address) external returns (uint256) envfree;
    function isModuleEnabled(address) external returns (bool) envfree;
    function isOwner(address) external returns (bool) envfree;
    function isRecoveryEnabled() external returns (bool) envfree;
    function getRecoveryThreshold() external returns (uint8) envfree;
    function isRecoverySigner(address) external returns (bool) envfree;
    function getIncomingOwner() external returns (address) envfree;
    function getIncomingOwnerStartTime() external returns (uint256) envfree;
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

// This rule checks that:
// 1. Invalid inputs cause the call to revert (assert false if invalid input succeeds)
// 2. Valid inputs result in correct post-conditions when call succeeds
rule recoverSafeProperties(
    address newOwner,
    address[] recoverySigners,
    bytes[] signatures
) {
    env e;
    
    bool isCurrentOwner = isOwner(e.msg.sender);
    address oldIncomingOwner = getIncomingOwner();
    uint256 oldIncomingOwnerStartTime = getIncomingOwnerStartTime();
    
    require newOwner != 0 && recoverySigners.length <= signatures.length && recoverySigners.length >= getRecoveryThreshold() && recoverySigners.length > 0 && isRecoverySigner(recoverySigners[0]) && isCurrentOwner && isRecoveryEnabled();
    
    recoverSafe(e, newOwner, recoverySigners, signatures);
                
    address newIncomingOwner = getIncomingOwner();
    uint256 newIncomingOwnerStartTime = getIncomingOwnerStartTime();
    
    assert newIncomingOwner == newOwner && newIncomingOwnerStartTime > e.block.timestamp && (oldIncomingOwnerStartTime == 0 || newIncomingOwnerStartTime != oldIncomingOwnerStartTime) && isRecoveryEnabled();
}

/**
 * @title Recovery is idempotent regarding contract state
 * @notice Multiple recoveries can overwrite pending recovery
 */
rule recoveryCanBeOverwritten(
    address newOwner1,
    address[] recoverySigners1,
    bytes[] signatures1,
    address newOwner2,
    address[] recoverySigners2,
    bytes[] signatures2
) {
    env e1;
    env e2;
    require e2.block.timestamp >= e1.block.timestamp;
    require isRecoveryEnabled() && newOwner1 != 0 && newOwner2 != 0;
    require recoverySigners1.length <= signatures1.length && recoverySigners1.length >= getRecoveryThreshold() && recoverySigners1.length > 0;
    require recoverySigners2.length <= signatures2.length && recoverySigners2.length >= getRecoveryThreshold() && recoverySigners2.length > 0;

    // First recovery
    recoverSafe@withrevert(e1, newOwner1, recoverySigners1, signatures1);
    require !lastReverted;
    
    address incomingAfterFirst = getIncomingOwner();
    assert incomingAfterFirst == newOwner1;
    
    // Second recovery
    recoverSafe@withrevert(e2, newOwner2, recoverySigners2, signatures2);
    require !lastReverted;
    
    address incomingAfterSecond = getIncomingOwner();
    
    assert incomingAfterSecond == newOwner2,
        "Second recovery must overwrite first pending recovery";
}
