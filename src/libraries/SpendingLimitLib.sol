// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { TimeLib } from "./TimeLib.sol";

/**
 * @title SpendingLimit
 * @notice Data structure for managing daily and monthly spending limits with time-based renewals
 * @dev Includes current limits, spent amounts, pending limit changes, and renewal timestamps
 */
struct SpendingLimit {
    uint256 dailyLimit; // in USD with 6 decimals
    uint256 monthlyLimit; // in USD with 6 decimals
    uint256 spentToday; // in USD with 6 decimals
    uint256 spentThisMonth; // in USD with 6 decimals
    uint256 newDailyLimit; // in USD with 6 decimals
    uint256 newMonthlyLimit; // in USD with 6 decimals
    uint64 dailyRenewalTimestamp;
    uint64 monthlyRenewalTimestamp;
    uint64 dailyLimitChangeActivationTime;
    uint64 monthlyLimitChangeActivationTime;
    int256 timezoneOffset;
}

/**
 * @title SpendingLimitLib
 * @notice Library for managing spending limits with daily and monthly caps
 * @dev Provides functionality for initializing, updating, and enforcing spending limits
 * @author ether.fi
 */
library SpendingLimitLib {
    using TimeLib for uint256;
    using Math for uint256;

    /**
     * @notice Error thrown when a spend would exceed the daily limit
     */
    error ExceededDailySpendingLimit();
    
    /**
     * @notice Error thrown when a spend would exceed the monthly limit
     */
    error ExceededMonthlySpendingLimit();
    
    /**
     * @notice Error thrown when daily limit is set higher than monthly limit
     */
    error DailyLimitCannotBeGreaterThanMonthlyLimit();
    
    /**
     * @notice Error thrown when timezone offset is invalid
     */
    error InvalidTimezoneOffset();

    /**
     * @notice Initializes a new SpendingLimit with daily and monthly caps
     * @dev Sets up initial renewal timestamps based on current time and timezone offset
     * @param limit Storage reference to the SpendingLimit to initialize
     * @param dailyLimit Maximum amount that can be spent in a day (USD with 6 decimals)
     * @param monthlyLimit Maximum amount that can be spent in a month (USD with 6 decimals)
     * @param timezoneOffset User's timezone offset in seconds
     * @return The initialized SpendingLimit
     * @custom:throws DailyLimitCannotBeGreaterThanMonthlyLimit if daily limit exceeds monthly limit
     * @custom:throws InvalidTimezoneOffset if timezone offset is outside valid range
     */
    function initialize(SpendingLimit storage limit, uint256 dailyLimit, uint256 monthlyLimit, int256 timezoneOffset) internal sanity(dailyLimit, monthlyLimit) returns (SpendingLimit memory) {
        if (timezoneOffset > 24 * 60 * 60 || timezoneOffset < -24 * 60 * 60) revert InvalidTimezoneOffset();
        limit.dailyLimit = dailyLimit;
        limit.monthlyLimit = monthlyLimit;
        limit.timezoneOffset = timezoneOffset;
        limit.dailyRenewalTimestamp = block.timestamp.getStartOfNextDay(limit.timezoneOffset);
        limit.monthlyRenewalTimestamp = block.timestamp.getStartOfNextMonth(limit.timezoneOffset);

        return limit;
    }

    /**
     * @notice Updates storage with the current limit state
     * @dev Refreshes all fields of the limit struct with current values
     * @param limit Storage reference to the SpendingLimit to update
     */
    function currentLimit(SpendingLimit storage limit) internal {
        SpendingLimit memory finalLimit = getCurrentLimit(limit);

        limit.dailyLimit = finalLimit.dailyLimit;
        limit.monthlyLimit = finalLimit.monthlyLimit;
        limit.spentToday = finalLimit.spentToday;
        limit.spentThisMonth = finalLimit.spentThisMonth;
        limit.newDailyLimit = finalLimit.newDailyLimit;
        limit.newMonthlyLimit = finalLimit.newMonthlyLimit;
        limit.dailyRenewalTimestamp = finalLimit.dailyRenewalTimestamp;
        limit.monthlyRenewalTimestamp = finalLimit.monthlyRenewalTimestamp;
        limit.dailyLimitChangeActivationTime = finalLimit.dailyLimitChangeActivationTime;
        limit.monthlyLimitChangeActivationTime = finalLimit.monthlyLimitChangeActivationTime;
    }

    /**
     * @notice Records a spend against the daily and monthly limits
     * @dev Updates current limits first, then applies the spend if within limits
     * @param limit Storage reference to the SpendingLimit
     * @param amount Amount to spend (USD with 6 decimals)
     * @custom:throws ExceededDailySpendingLimit if spend would exceed daily limit
     * @custom:throws ExceededMonthlySpendingLimit if spend would exceed monthly limit
     */
    function spend(SpendingLimit storage limit, uint256 amount) internal {
        currentLimit(limit);

        if (limit.spentToday + amount > limit.dailyLimit) revert ExceededDailySpendingLimit();
        if (limit.spentThisMonth + amount > limit.monthlyLimit) revert ExceededMonthlySpendingLimit();

        limit.spentToday += amount;
        limit.spentThisMonth += amount;
    }

    /**
     * @notice Updates spending limits with optional delay for decreases
     * @dev Immediate increases, delayed decreases with activation timestamp
     * @param limit Storage reference to the SpendingLimit
     * @param newDailyLimit New daily spending limit (USD with 6 decimals)
     * @param newMonthlyLimit New monthly spending limit (USD with 6 decimals)
     * @param delay Seconds to delay limit decreases (0 for immediate)
     * @return Original limit before changes
     * @return Updated limit after changes
     * @custom:throws DailyLimitCannotBeGreaterThanMonthlyLimit if daily limit exceeds monthly limit
     */
    function updateSpendingLimit(SpendingLimit storage limit, uint256 newDailyLimit, uint256 newMonthlyLimit, uint64 delay) internal sanity(newDailyLimit, newMonthlyLimit) returns (SpendingLimit memory, SpendingLimit memory) {
        currentLimit(limit);
        SpendingLimit memory oldLimit = limit;

        if (newDailyLimit < limit.dailyLimit) {
            limit.newDailyLimit = newDailyLimit;
            limit.dailyLimitChangeActivationTime = uint64(block.timestamp) + delay;
        } else {
            limit.dailyLimit = newDailyLimit;
            limit.newDailyLimit = 0;
            limit.dailyLimitChangeActivationTime = 0;
        }

        if (newMonthlyLimit < limit.monthlyLimit) {
            limit.newMonthlyLimit = newMonthlyLimit;
            limit.monthlyLimitChangeActivationTime = uint64(block.timestamp) + delay;
        } else {
            limit.monthlyLimit = newMonthlyLimit;
            limit.newMonthlyLimit = 0;
            limit.monthlyLimitChangeActivationTime = 0;
        }

        return (oldLimit, limit);
    }

    /**
     * @notice Calculates the maximum amount that can be spent right now
     * @dev Considers both daily and monthly limits, returning the lower of the two remaining amounts
     * @param limit Memory copy of the SpendingLimit
     * @return Maximum spendable amount in USD with 6 decimals
     */
    function maxCanSpend(SpendingLimit memory limit) internal view returns (uint256) {
        limit = getCurrentLimit(limit);
        bool usingIncomingDailyLimit = false;
        bool usingIncomingMonthlyLimit = false;
        uint256 applicableDailyLimit = limit.dailyLimit;
        uint256 applicableMonthlyLimit = limit.monthlyLimit;

        if (limit.dailyLimitChangeActivationTime != 0) {
            applicableDailyLimit = limit.newDailyLimit;
            usingIncomingDailyLimit = true;
        }
        if (limit.monthlyLimitChangeActivationTime != 0) {
            applicableMonthlyLimit = limit.newMonthlyLimit;
            usingIncomingMonthlyLimit = true;
        }

        if (limit.spentToday > applicableDailyLimit) return 0;
        if (limit.spentThisMonth > applicableMonthlyLimit) return 0;

        return Math.min(applicableDailyLimit - limit.spentToday, applicableMonthlyLimit - limit.spentThisMonth);
    }

    /**
     * @notice Checks if a specific amount can be spent
     * @dev Considers both daily and monthly limits, including pending limit changes
     * @param limit Memory copy of the SpendingLimit
     * @param amount Amount to check if spendable (USD with 6 decimals)
     * @return canSpend Boolean indicating if the amount can be spent
     * @return message Error message if amount cannot be spent
     */
    function canSpend(SpendingLimit memory limit, uint256 amount) internal view returns (bool, string memory) {
        limit = getCurrentLimit(limit);

        bool usingIncomingDailyLimit = false;
        bool usingIncomingMonthlyLimit = false;
        uint256 applicableDailyLimit = limit.dailyLimit;
        uint256 applicableMonthlyLimit = limit.monthlyLimit;

        if (limit.dailyLimitChangeActivationTime != 0) {
            applicableDailyLimit = limit.newDailyLimit;
            usingIncomingDailyLimit = true;
        }
        if (limit.monthlyLimitChangeActivationTime != 0) {
            applicableMonthlyLimit = limit.newMonthlyLimit;
            usingIncomingMonthlyLimit = true;
        }

        if (limit.spentToday > applicableDailyLimit) {
            if (usingIncomingDailyLimit) return (false, "Incoming daily spending limit already exhausted");
            else return (false, "Daily spending limit already exhausted");
        }

        if (limit.spentThisMonth > applicableMonthlyLimit) {
            if (usingIncomingMonthlyLimit) return (false, "Incoming monthly spending limit already exhausted");
            else return (false, "Monthly spending limit already exhausted");
        }

        uint256 availableDaily = applicableDailyLimit - limit.spentToday;
        uint256 availableMonthly = applicableMonthlyLimit - limit.spentThisMonth;

        if (amount > availableDaily) {
            if (usingIncomingDailyLimit) return (false, "Incoming daily available spending limit less than amount requested");
            return (false, "Daily available spending limit less than amount requested");
        }

        if (amount > availableMonthly) {
            if (usingIncomingMonthlyLimit) return (false, "Incoming monthly available spending limit less than amount requested");
            return (false, "Monthly available spending limit less than amount requested");
        }

        return (true, "");
    }

    /**
     * @notice Gets the current limit state with all time-based updates applied
     * @dev Applies pending limit changes and resets counters on renewal timestamps
     * @param limit Memory copy of the SpendingLimit
     * @return Updated SpendingLimit reflecting current state
     */
    function getCurrentLimit(SpendingLimit memory limit) internal view returns (SpendingLimit memory) {
        if (limit.dailyLimitChangeActivationTime != 0 && block.timestamp > limit.dailyLimitChangeActivationTime) {
            limit.dailyLimit = limit.newDailyLimit;
            limit.newDailyLimit = 0;
            limit.dailyLimitChangeActivationTime = 0;
        }

        if (limit.monthlyLimitChangeActivationTime != 0 && block.timestamp > limit.monthlyLimitChangeActivationTime) {
            limit.monthlyLimit = limit.newMonthlyLimit;
            limit.newMonthlyLimit = 0;
            limit.monthlyLimitChangeActivationTime = 0;
        }

        if (block.timestamp > limit.dailyRenewalTimestamp) {
            limit.spentToday = 0;
            limit.dailyRenewalTimestamp = getFinalDailyRenewalTimestamp(limit.dailyRenewalTimestamp, limit.timezoneOffset);
        }

        if (block.timestamp > limit.monthlyRenewalTimestamp) {
            limit.spentThisMonth = 0;
            limit.monthlyRenewalTimestamp = getFinalMonthlyRenewalTimestamp(limit.monthlyRenewalTimestamp, limit.timezoneOffset);
        }

        return limit;
    }

    /**
     * @notice Calculates the next valid daily renewal timestamp
     * @dev Handles cases where multiple renewal periods have elapsed
     * @param renewalTimestamp Current renewal timestamp
     * @param timezoneOffset User's timezone offset in seconds
     * @return Next valid daily renewal timestamp
     */
    function getFinalDailyRenewalTimestamp(uint64 renewalTimestamp, int256 timezoneOffset) internal view returns (uint64) {
        do {
            renewalTimestamp = uint256(renewalTimestamp).getStartOfNextDay(timezoneOffset);
        } while (block.timestamp > renewalTimestamp);

        return renewalTimestamp;
    }

    /**
     * @notice Calculates the next valid monthly renewal timestamp
     * @dev Handles cases where multiple renewal periods have elapsed
     * @param renewalTimestamp Current renewal timestamp
     * @param timezoneOffset User's timezone offset in seconds
     * @return Next valid monthly renewal timestamp
     */
    function getFinalMonthlyRenewalTimestamp(uint64 renewalTimestamp, int256 timezoneOffset) internal view returns (uint64) {
        do {
            renewalTimestamp = uint256(renewalTimestamp).getStartOfNextMonth(timezoneOffset);
        } while (block.timestamp > renewalTimestamp);

        return renewalTimestamp;
    }

    /**
     * @dev Modifier to ensure daily limit is not greater than monthly limit
     * @param dailyLimit Daily spending limit to validate
     * @param monthlyLimit Monthly spending limit to validate
     * @custom:throws DailyLimitCannotBeGreaterThanMonthlyLimit if daily limit exceeds monthly limit
     */
    modifier sanity(uint256 dailyLimit, uint256 monthlyLimit) {
        if (dailyLimit > monthlyLimit) revert DailyLimitCannotBeGreaterThanMonthlyLimit();
        _;
    }
}