// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev The two safe functions this library reaches back into. Declared locally so the library does not
///      pull the safe's whole interface (and its inheritance) into scope.
interface ISafeSignatureCheck {
    function checkSignatures(bytes32 digestHash, address[] calldata signers, bytes[] calldata signatures) external view returns (bool);
}

/**
 * @title SafeErc1271Lib
 * @author ether.fi
 * @notice The body of `EtherFiSafe.isValidSignature`, held outside the safe's own bytecode.
 * @dev DEPLOYED, NOT INLINED. `validate` is `external`, so solc emits a DELEGATECALL to a separately
 *      deployed library rather than copying this code into every safe. That is the entire point: the
 *      blob decode and the EIP-191 length-prefix construction are what make ERC-1271 expensive, and
 *      EtherFiSafe does not have the runtime-size budget to hold them.
 *
 *      Because it is a DELEGATECALL, `address(this)` is the calling safe, so reaching back for
 *      `checkSignatures` validates against that safe's live owners and threshold.
 */
library SafeErc1271Lib {
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant ERC1271_INVALID = 0xffffffff;

    /**
     * @notice Validates an ERC-1271 signature blob against the calling safe's owners
     * @param hash The hash the consumer is asking about; must be the EIP-191 hash of `message`
     * @param signature abi.encode(bytes message, address[] signers, bytes[] signatures)
     * @param domainSeparator The calling safe's EIP-712 domain separator, passed in rather than rebuilt
     * @param typehash The safe's SAFE_MESSAGE_TYPEHASH
     * @return bytes4 ERC1271_MAGIC_VALUE if the signers meet the safe's threshold, else ERC1271_INVALID
     * @dev Answers rather than reverts. `checkSignatures` reverts on an empty, short, mismatched or
     *      duplicated signer set and `ECDSA.recover` reverts on malformed or high-`s` signatures; all of
     *      those mean "not a valid signature", not "error", and an ERC-1271 consumer staticcalls without
     *      a try/catch and propagates whatever comes back. The decode is inside the same boundary here,
     *      so an undecodable blob is answered too rather than being the one case that still reverts.
     */
    function validate(bytes32 hash, bytes calldata signature, bytes32 domainSeparator, bytes32 typehash) external view returns (bytes4) {
        (bytes memory message, address[] memory signers, bytes[] memory signatures) = abi.decode(signature, (bytes, address[], bytes[]));

        // Load-bearing, not a formality: EIP-712 digests begin 0x1901 and the EIP-191 prefix fixes byte 1
        // to 'E', so no message can hash to one. That is what keeps Permit2, Seaport and the Aave Spoke's
        // setUserPositionManagersWithSig unsatisfiable here, owner keys included. Relaxing it re-arms them.
        if (hash != MessageHashUtils.toEthSignedMessageHash(message)) return ERC1271_INVALID;

        bytes32 digestHash = keccak256(abi.encodePacked(hex"1901", domainSeparator, keccak256(abi.encode(typehash, hash))));

        // address(this) is the calling safe: this is a DELEGATECALL.
        try ISafeSignatureCheck(address(this)).checkSignatures(digestHash, signers, signatures) returns (bool valid) {
            return valid ? ERC1271_MAGIC_VALUE : ERC1271_INVALID;
        } catch {
            return ERC1271_INVALID;
        }
    }
}
