// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Mode } from "../interfaces/ICashModule.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { SignatureUtils } from "./SignatureUtils.sol";

/**
 * @title CashVerificationLib
 * @notice Library providing signature verification functionality for Cash operations
 * @dev Uses SignatureUtils and MessageHashUtils for ECDSA signature verification
 * @author ether.fi
 */
library CashVerificationLib {
    using SignatureUtils for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Method identifier for withdrawal requests
    bytes32 public constant REQUEST_WITHDRAWAL_METHOD = keccak256("requestWithdrawal");

    /// @notice Method identifier for withdrawal cancellation
    bytes32 public constant CANCEL_WITHDRAWAL_METHOD = keccak256("cancelWithdrawal");

    /// @notice Method identifier for spending limit updates
    bytes32 public constant UPDATE_SPENDING_LIMIT_METHOD = keccak256("updateSpendingLimit");

    /// @notice Method identifier for mode changes
    bytes32 public constant SET_MODE_METHOD = keccak256("setMode");

    /// @notice Method identifier for cashback split changes for a safe
    bytes32 public constant SET_CASHBACK_SPLIT_TO_SAFE_PERCENTAGE = keccak256("setCashbackSplitToSafePercentage");

    /// @notice Error for Invalid Owner quorum signatures
    error InvalidSignatures();

    /**
     * @notice Verifies the signature for a method
     * @param safe Address of the safe
     * @param signer Address of the signer to verify against
     * @param methodHash Method hash for the method called
     * @param nonce Transaction nonce for replay protection
     * @param encodedData Encoded data for the operation
     * @param signature ECDSA signature bytes
     * @custom:throws SignatureUtils.InvalidSignature if the signature is invalid
     */
    function verifySignature(address safe, address signer, bytes32 methodHash, uint256 nonce, bytes memory encodedData, bytes calldata signature) internal view {
        bytes32 digestHash = keccak256(abi.encodePacked(methodHash, block.chainid, safe, nonce, encodedData)).toEthSignedMessageHash();
        digestHash.checkSignature(signer, signature);
    }

    /**
     * @notice Verifies a signature for changing the cash mode
     * @dev Creates and validates an EIP-191 signed message hash
     * @param safe Address of the safe
     * @param signer Address of the signer to verify against
     * @param nonce Transaction nonce for replay protection
     * @param mode New cash mode (Credit or Debit)
     * @param signature ECDSA signature bytes
     * @custom:throws SignatureUtils.InvalidSignature if the signature is invalid
     */
    function verifySetModeSig(address safe, address signer, uint256 nonce, Mode mode, bytes calldata signature) internal view {
        verifySignature(safe, signer, SET_MODE_METHOD, nonce, abi.encode(mode), signature);
    }

    /**
     * @notice Verifies a signature for updating spending limits
     * @dev Creates and validates an EIP-191 signed message hash
     * @param safe Address of the safe
     * @param signer Address of the signer to verify against
     * @param nonce Transaction nonce for replay protection
     * @param dailyLimitInUsd New daily spending limit in USD
     * @param monthlyLimitInUsd New monthly spending limit in USD
     * @param signature ECDSA signature bytes
     * @custom:throws SignatureUtils.InvalidSignature if the signature is invalid
     */
    function verifyUpdateSpendingLimitSig(address safe, address signer, uint256 nonce, uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, bytes calldata signature) internal view {
        verifySignature(safe, signer, UPDATE_SPENDING_LIMIT_METHOD, nonce, abi.encode(dailyLimitInUsd, monthlyLimitInUsd), signature);
    }

    /**
     * @notice Verifies a signature for requesting a withdrawal
     * @dev Creates and validates an EIP-191 signed message hash
     * @param safe Address of the safe
     * @param nonce Transaction nonce for replay protection
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of token amounts to withdraw
     * @param recipient Address to receive the withdrawn tokens
     * @param signers Address of the signers
     * @param signatures ECDSA signatures by signers
     * @custom:throws InvalidSignatures if the signature is invalid
     */
    function verifyRequestWithdrawalSig(address safe, uint256 nonce, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) internal view {
        bytes32 digestHash = keccak256(abi.encodePacked(REQUEST_WITHDRAWAL_METHOD, block.chainid, safe, nonce, abi.encode(tokens, amounts, recipient))).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @notice Verifies a signature for cancelling a withdrawal
     * @dev Creates and validates an EIP-191 signed message hash
     * @param safe Address of the safe
     * @param nonce Transaction nonce for replay protection
     * @param signers Address of the signers
     * @param signatures ECDSA signatures by signers
     * @custom:throws InvalidSignatures if the signature is invalid
     */
    function verifyCancelWithdrawalSig(address safe, uint256 nonce, address[] calldata signers, bytes[] calldata signatures) internal view {
        bytes32 digestHash = keccak256(abi.encodePacked(CANCEL_WITHDRAWAL_METHOD, block.chainid, safe, nonce)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @notice Verifies a signature for updating cashback split to safe percentage
     * @dev Creates and validates an EIP-191 signed message hash
     * @param safe Address of the safe
     * @param signer Address of the signer to verify against
     * @param nonce Transaction nonce for replay protection
     * @param split Cashback split to safe in bps
     * @param signature ECDSA signature bytes
     * @custom:throws SignatureUtils.InvalidSignature if the signature is invalid
     */
    function verifySetCashbackSplitToSafePercentage(address safe, address signer, uint256 nonce, uint256 split, bytes calldata signature) internal view {
        verifySignature(safe, signer, SET_CASHBACK_SPLIT_TO_SAFE_PERCENTAGE, nonce, abi.encode(split), signature);
    }
}
