// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Cashback, CashbackTokens, TokenDataInUsd } from "../../interfaces/ICashModule.sol";
import { ICashEventEmitter } from "../../interfaces/ICashEventEmitter.sol";
import { ICashbackDispatcher } from "../../interfaces/ICashbackDispatcher.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashbackLib
 * @notice Cashback accounting for the CashModule, extracted into an external (delegatecalled) library.
 * @dev Deployed once and linked into CashModuleCore, so this logic does not count against CashModuleCore's
 *      EIP-170 runtime code-size limit. Every function is called via delegatecall and therefore runs in the
 *      CashModule's storage context: the caller passes its CashModuleStorage pointer and the library reads and
 *      writes the same namespaced storage the module would. Behaviour is identical to the previous in-module
 *      implementation.
 * @author ether.fi
 */
library CashbackLib {
    using ArrayDeDupLib for address[];

    /// @dev Same selector as CashModule's InvalidInput, so reverts are indistinguishable to callers
    error InvalidInput();

    /**
     * @notice Gets the pending cashback amounts for an account across a set of tokens
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param account Address of the account (safe or spender)
     * @param tokens Addresses of tokens for cashback
     * @return data Pending cashback data for the tokens that have a nonzero pending amount
     * @return totalCashbackInUsd Total pending cashback amount in USD across the tokens
     */
    function getPendingCashback(CashModuleStorageContract.CashModuleStorage storage $, address account, address[] memory tokens) external view returns (TokenDataInUsd[] memory data, uint256 totalCashbackInUsd) {
        uint256 len = tokens.length;
        if (len > 1) tokens.checkDuplicates();
        data = new TokenDataInUsd[](len);
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            uint256 pendingCashbackInUsd = $.pendingCashbackForTokenInUsd[account][tokens[i]];
            if (pendingCashbackInUsd > 0) {
                data[m] = TokenDataInUsd({ token: tokens[i], amountInUsd: pendingCashbackInUsd });

                totalCashbackInUsd += pendingCashbackInUsd;

                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(data, m)
        }
    }

    /**
     * @notice Attempts to retrieve (pay out) the pending cashback for a set of users and tokens
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param users Addresses of users who may have pending cashback
     * @param tokens Addresses of cashback tokens
     * @custom:throws InvalidInput if users is empty or any user/token is the zero address
     */
    function clearPending(CashModuleStorageContract.CashModuleStorage storage $, address[] calldata users, address[] calldata tokens) external {
        uint256 len = users.length;
        if (len == 0) revert InvalidInput();
        if (tokens.length > 1) tokens.checkDuplicates();
        if (len > 1) users.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (users[i] == address(0)) revert InvalidInput();

            for (uint256 j = 0; j < tokens.length;) {
                if (tokens[j] == address(0)) revert InvalidInput();

                _retrievePendingCashback($, users[i], tokens[j]);
                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Processes cashback for a spending transaction, paying what it can and queuing the rest
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe that spent
     * @param spendAmount Amount spent in USD (for the emitted event)
     * @param cashbacks Array of Cashback structs describing recipients, tokens, and amounts
     */
    function processCashback(CashModuleStorageContract.CashModuleStorage storage $, address safe, uint256 spendAmount, Cashback[] calldata cashbacks) external {
        uint256 len = cashbacks.length;

        for (uint256 i = 0; i < len;) {
            address to = cashbacks[i].to;
            if (to == address(0)) continue;
            CashbackTokens[] memory cashbackTokens = cashbacks[i].cashbackTokens;

            for (uint256 j = 0; j < cashbackTokens.length;) {
                address token = cashbackTokens[j].token;
                _retrievePendingCashback($, to, token);

                uint256 amountInUsd = cashbackTokens[j].amountInUsd;
                $.safeCashConfig[to].totalCashbackEarnedInUsd += amountInUsd;

                if (amountInUsd != 0) {
                    try $.cashbackDispatcher.cashback(to, token, amountInUsd) returns (uint256 cashbackAmountInToken, bool paid) {
                        if (!paid) $.pendingCashbackForTokenInUsd[to][token] += amountInUsd;
                        $.cashEventEmitter.emitCashbackEvent(safe, spendAmount, to, token, cashbackAmountInToken, amountInUsd, cashbackTokens[j].cashbackType, paid);
                    } catch {
                        $.pendingCashbackForTokenInUsd[to][token] += amountInUsd;
                        $.cashEventEmitter.emitCashbackEvent(safe, spendAmount, to, token, 0, amountInUsd, cashbackTokens[j].cashbackType, false);
                    }
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Attempts to retrieve pending cashback for a single user/token, clearing storage on success
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param user Address of the user who may have pending cashback
     * @param token Address of the cashback token
     */
    function _retrievePendingCashback(CashModuleStorageContract.CashModuleStorage storage $, address user, address token) internal {
        uint256 amountInUsd = $.pendingCashbackForTokenInUsd[user][token];

        if (amountInUsd > 0) {
            try $.cashbackDispatcher.clearPendingCashback(user, token, amountInUsd) returns (uint256 cashbackAmountInToken, bool paid) {
                if (paid) {
                    $.cashEventEmitter.emitPendingCashbackClearedEvent(user, token, cashbackAmountInToken, amountInUsd);
                    delete $.pendingCashbackForTokenInUsd[user][token];
                }
            } catch { }
        }
    }
}
