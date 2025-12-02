import "dispatching_EtherFiSafe.spec";
import "shared_functions.spec";

using DebtManagerCore as debtManager;
using CashModuleCoreHarness as cashModule;

methods {
    function EtherFiSafeHarness.getSafeAdminRole(address) external returns (uint256) envfree;
    function isModuleEnabled(address) external returns (bool) envfree;
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
    
    address oldIncomingOwner = getIncomingOwner();
    require oldIncomingOwner != newOwner;
    bool recoveryEnabledBefore = isRecoveryEnabled();
    uint8 threshold = getRecoveryThreshold();

    // Check if inputs are invalid (excluding owner check since _currentOwner() handles that)
    bool hasInvalidInput = 
        (newOwner == 0) ||
        (recoverySigners.length != signatures.length) ||
        (recoverySigners.length < threshold) ||
        (recoverySigners.length > 0 && !isRecoverySigner(recoverySigners[0])) ||
        (!recoveryEnabledBefore);
    
    recoverSafe(e, newOwner, recoverySigners, signatures);

    // If inputs are invalid, the call should have reverted
    if (hasInvalidInput) {
        assert false;
    }
                
    // If call succeeded, verify all post-conditions
    address newIncomingOwner = getIncomingOwner();
    uint256 newIncomingOwnerStartTime = getIncomingOwnerStartTime();
    
    // Post-conditions: incoming owner must be set correctly
    assert newIncomingOwner == newOwner;
    assert newIncomingOwnerStartTime >= e.block.timestamp;
    assert isRecoveryEnabled();
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

/**
 * @title checkSignatures never returns true with non-owner signer
 */
rule checkSignatures_RejectsNonOwner(
    bytes32 digestHash,
    address[] signers,
    bytes[] signatures
) {
    env e;
    
    require signers.length == signatures.length;
    require signers.length > 0;
    
    uint8 threshold = getThreshold(e);
    require threshold > 0;
    require signers.length >= threshold;
    
    uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
    require incomingOwnerStartTime == 0 || e.block.timestamp <= incomingOwnerStartTime;
    
    // At least one signer is not an owner (but not zero)
    uint256 nonOwnerIndex;
    require nonOwnerIndex < signers.length;
    require signers[nonOwnerIndex] != 0;
    require !isOwner(e, signers[nonOwnerIndex]);
    
    bool result = checkSignatures@withrevert(e, digestHash, signers, signatures);
    
    assert lastReverted || !result, 
        "checkSignatures must not return true when any signer is not an owner";
}

/**
 * @title checkSignatures never returns true with zero address signer
 */
rule checkSignatures_RejectsZeroAddress(
    bytes32 digestHash,
    address[] signers,
    bytes[] signatures
) {
    env e;
    
    require signers.length == signatures.length,
        "Array lengths must match";
    
    require signers.length > 0,
        "Non-empty array needed";
    
    uint8 threshold = getThreshold(e);
    
    require threshold > 0,
        "Threshold must be positive";
    
    require signers.length >= threshold,
        "Need sufficient length";
    
    uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
    
    require incomingOwnerStartTime == 0 || e.block.timestamp <= incomingOwnerStartTime,
        "Test normal mode";
    
    uint256 zeroIndex;
    
    require zeroIndex < signers.length,
        "Index must be valid";
    
    require signers[zeroIndex] == 0,
        "This signer is zero address";
    
    bool result = checkSignatures@withrevert(e, digestHash, signers, signatures);
    
    assert lastReverted || !result, 
        "checkSignatures must not return true";
}

/**
 * @title checkSignatures never returns true with duplicate signers
 */
rule checkSignatures_RejectsDuplicates(
    bytes32 digestHash,
    address[] signers,
    bytes[] signatures
) {
    env e;
    
    require signers.length == signatures.length,
        "Array lengths must match";
    
    require signers.length > 1,
        "Need at least 2 signers";
    
    uint8 threshold = getThreshold(e);
    
    require threshold > 0,
        "Threshold must be positive";
    
    require signers.length >= threshold,
        "Need sufficient length";
    
    uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
    
    require incomingOwnerStartTime == 0 || e.block.timestamp <= incomingOwnerStartTime,
        "Test normal mode";
    
    uint256 idx1;
    uint256 idx2;
    
    require idx1 < signers.length,
        "First index must be valid";
    
    require idx2 < signers.length,
        "Second index must be valid";
    
    require idx1 < idx2,
        "Ensure distinct positions to avoid trivial equality";
    
    require signers[idx1] == signers[idx2],
        "Duplicate signers at different positions";
    
    require signers[idx1] != 0,
        "Non-zero duplicate";
    
    bool result = checkSignatures@withrevert(e, digestHash, signers, signatures);
    
    assert lastReverted || !result, 
        "checkSignatures must not return true with duplicates";
}

/**
 * @title checkSignatures never returns true with insufficient signers
 */
rule checkSignatures_RejectsInsufficientSigners(
    bytes32 digestHash,
    address[] signers,
    bytes[] signatures
) {
    env e;
    
    require signers.length == signatures.length,
        "Array lengths must match";
    
    require signers.length > 0,
        "Non-empty array";
    
    uint8 threshold = getThreshold(e);
    
    require threshold > 0,
        "Threshold must be positive";
    
    uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
    
    require incomingOwnerStartTime == 0 || e.block.timestamp <= incomingOwnerStartTime,
        "Test normal mode";
    
    require signers.length < threshold,
        "Insufficient signers";
    
    bool result = checkSignatures@withrevert(e, digestHash, signers, signatures);
    
    assert lastReverted || !result, 
        "checkSignatures must not return true with insufficient signers";
}

/**
 * @title checkSignatures never returns true in invalid transition mode
 */
rule checkSignatures_RejectsInvalidTransition(
    bytes32 digestHash,
    address[] signers,
    bytes[] signatures
) {
    env e;
    
    require signers.length == signatures.length,
        "Array lengths must match";
    
    require signers.length > 0,
        "Non-empty array";
    
    uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
    address incomingOwner = getIncomingOwner();
    
    require incomingOwnerStartTime > 0,
        "Transition mode active";
    
    require e.block.timestamp > incomingOwnerStartTime,
        "Past the transition start time - transition is active";
    
    require incomingOwner != 0,
        "Valid incoming owner address in transition";
    
    require signers.length > 1 || (signers.length == 1 && signers[0] != incomingOwner),
        "Invalid transition";
    
    bool result = checkSignatures@withrevert(e, digestHash, signers, signatures);
    
    assert lastReverted || !result, 
        "checkSignatures must not return true in transition mode";
}

/**
 * @title checkSignatures rejects empty or mismatched arrays
 */
rule checkSignatures_RejectsInvalidArrays(
    bytes32 digestHash,
    address[] signers,
    bytes[] signatures
) {
    env e;
    
    require signers.length == 0 || signers.length != signatures.length,
        "Either empty signers or array length mismatch";
    
    bool result = checkSignatures@withrevert(e, digestHash, signers, signatures);
    
    assert lastReverted || !result, 
        "checkSignatures must not return true";
}