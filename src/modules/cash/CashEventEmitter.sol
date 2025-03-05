// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable, UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { Mode, SafeTiers } from "../../interfaces/ICashModule.sol";
import { SpendingLimit } from "../../libraries/SpendingLimitLib.sol";

contract CashEventEmitter is Initializable, UUPSUpgradeable, AccessControlDefaultAdminRulesUpgradeable {
    address public cashModule;

    error OnlyCashModule();

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _cashModule) external initializer {
        __UUPSUpgradeable_init();
        __AccessControlDefaultAdminRules_init_unchained(5 * 60, _owner);
        cashModule = _cashModule;
    }

    function initializeOnUpgrade(address _cashModule) external reinitializer(2) {
        cashModule = _cashModule;
    }

    event WithdrawalRequested(address indexed safe, address[] tokens, uint256[] amounts, address indexed recipient, uint256 finalizeTimestamp);
    event WithdrawalAmountUpdated(address indexed safe, address indexed token, uint256 amount);
    event WithdrawalCancelled(address indexed safe, address[] tokens, uint256[] amounts, address indexed recipient);
    event WithdrawalProcessed(address indexed safe, address[] tokens, uint256[] amounts, address indexed recipient);
    event RepayDebtManager(address indexed safe, address indexed token, uint256 debtAmount, uint256 debtAmountInUsd);
    event SpendingLimitChanged(address indexed safe, SpendingLimit oldLimit, SpendingLimit newLimit);
    event ModeSet(address indexed safe, Mode prevMode, Mode newMode, uint256 incomingModeStartTime);
    event Spend(address indexed safe, address indexed token, uint256 amount, uint256 amountInUsd, Mode mode);
    event Cashback(address indexed safe, address indexed spender, uint256 spendingInUsd, address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool indexed paid);
    event PendingCashbackCleared(address indexed safe, address indexed recipient, address cashbackToken, uint256 cashbackAmount, uint256 cashbackInUsd);
    event SafeTiersSet(address[] safes, SafeTiers[] tiers);
    event TierCashbackPercentageSet(SafeTiers[] tiers, uint256[] cashbackPercentages);
    event CashbackSplitToSafeBpsSet(address safe, uint256 oldSplitInBps, uint256 newSplitInBps);
    event DelaysSet(uint64 withdrawalDelay, uint64 spendingLimitDelay, uint64 modeDelay);
    event WithdrawRecipientsConfigured(address safe, address[] withdrawRecipients, bool[] shouldWhitelist);

    function emitConfigureWithdrawRecipients(address safe, address[] calldata withdrawRecipients, bool[] calldata shouldWhitelist) external onlyCashModule {
        emit WithdrawRecipientsConfigured(safe, withdrawRecipients, shouldWhitelist);
    }

    function emitSetSafeTiers(address[] memory safes, SafeTiers[] memory safeTiers) external onlyCashModule {
        emit SafeTiersSet(safes, safeTiers);
    }

    function emitSetTierCashbackPercentage(SafeTiers[] memory safeTiers, uint256[] memory cashbackPercentages) external onlyCashModule {
        emit TierCashbackPercentageSet(safeTiers, cashbackPercentages);
    }

    function emitSetCashbackSplitToSafeBps(address safe, uint256 oldSplitInBps, uint256 newSplitInBps) external onlyCashModule {
        emit CashbackSplitToSafeBpsSet(safe, oldSplitInBps, newSplitInBps);
    }

    function emitSetDelays(uint64 withdrawalDelay, uint64 spendingLimitDelay, uint64 modeDelay) external onlyCashModule {
        emit DelaysSet(withdrawalDelay, spendingLimitDelay, modeDelay);
    }

    function emitPendingCashbackClearedEvent(address safe, address recipient, address cashbackToken, uint256 cashbackAmount, uint256 cashbackInUsd) external onlyCashModule {
        emit PendingCashbackCleared(safe, recipient, cashbackToken, cashbackAmount, cashbackInUsd);
    }

    function emitCashbackEvent(address safe, address spender, uint256 spendingInUsd, address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) external onlyCashModule {
        emit Cashback(safe, spender, spendingInUsd, cashbackToken, cashbackAmountToSafe, cashbackInUsdToSafe, cashbackAmountToSpender, cashbackInUsdToSpender, paid);
    }

    function emitSpend(address safe, address token, uint256 amount, uint256 amountInUsd, Mode mode) external onlyCashModule {
        emit Spend(safe, token, amount, amountInUsd, mode);
    }

    function emitSetMode(address safe, Mode prevMode, Mode newMode, uint256 incomingModeStartTime) external onlyCashModule {
        emit ModeSet(safe, prevMode, newMode, incomingModeStartTime);
    }

    function emitWithdrawalRequested(address safe, address[] memory tokens, uint256[] memory amounts, address recipient, uint256 finalizeTimestamp) external onlyCashModule {
        emit WithdrawalRequested(safe, tokens, amounts, recipient, finalizeTimestamp);
    }

    function emitWithdrawalAmountUpdated(address safe, address token, uint256 amount) external onlyCashModule {
        emit WithdrawalAmountUpdated(safe, token, amount);
    }

    function emitWithdrawalCancelled(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) external onlyCashModule {
        emit WithdrawalCancelled(safe, tokens, amounts, recipient);
    }

    function emitWithdrawalProcessed(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) external onlyCashModule {
        emit WithdrawalProcessed(safe, tokens, amounts, recipient);
    }

    function emitRepayDebtManager(address safe, address token, uint256 amount, uint256 amountInUsd) external onlyCashModule {
        emit RepayDebtManager(safe, token, amount, amountInUsd);
    }

    function emitSpendingLimitChanged(address safe, SpendingLimit memory oldLimit, SpendingLimit memory newLimit) external onlyCashModule {
        emit SpendingLimitChanged(safe, oldLimit, newLimit);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

    function _onlyCashModule() private view {
        if (cashModule != msg.sender) revert OnlyCashModule();
    }

    modifier onlyCashModule() {
        _onlyCashModule();
        _;
    }
}
