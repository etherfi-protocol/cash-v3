// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {console2} from "forge-std/console2.sol";


contract ContractCodeChecker {
    event ByteMismatchSegment(
        uint256 startIndex,
        uint256 endIndex,
        bytes aSegment,
        bytes bSegment
    );

    function compareBytes(bytes memory a, bytes memory b) internal returns (bool) {
        if (a.length != b.length) {
            // Length mismatch, emit one big segment for the difference if that’s desirable
            // or just return false. For clarity, we can just return false here.
            return false;
        }

        uint256 len = a.length;
        uint256 start = 0;
        bool inMismatch = false;
        bool anyMismatch = false;

        for (uint256 i = 0; i < len; i++) {
            bool mismatch = (a[i] != b[i]);
            if (mismatch && !inMismatch) {
                // Starting a new mismatch segment
                start = i;
                inMismatch = true;
            } else if (!mismatch && inMismatch) {
                // Ending the current mismatch segment at i-1
                emitMismatchSegment(a, b, start, i - 1);
                inMismatch = false;
                anyMismatch = true;
            }
        }

        // If we ended with a mismatch still open, close it out
        if (inMismatch) {
            emitMismatchSegment(a, b, start, len - 1);
            anyMismatch = true;
        }

        // If no mismatch segments were found, everything matched
        return !anyMismatch;
    }

    function emitMismatchSegment(
        bytes memory a,
        bytes memory b,
        uint256 start,
        uint256 end
    ) internal {
        // endIndex is inclusive
        uint256 segmentLength = end - start + 1;

        bytes memory aSegment = new bytes(segmentLength);
        bytes memory bSegment = new bytes(segmentLength);

        for (uint256 i = 0; i < segmentLength; i++) {
            aSegment[i] = a[start + i];
            bSegment[i] = b[start + i];
        }

        string memory aHex = bytesToHexString(aSegment);
        string memory bHex = bytesToHexString(bSegment);

        console2.log("- Mismatch segment at index [%s, %s]", start, end);
        console2.logString(string.concat(" - ", aHex));
        console2.logString(string.concat(" - ", bHex));

        emit ByteMismatchSegment(start, end, aSegment, bSegment);
    }

    function bytesToHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";

        // Every byte corresponds to two hex characters
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    // Compare the full bytecode of two deployed contracts, ensuring a perfect match.
    function verifyFullMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying full bytecode match...");
        bytes memory localBytecode = address(localDeployed).code;
        bytes memory onchainRuntimeBytecode = address(deployedImpl).code;

        if (compareBytes(localBytecode, onchainRuntimeBytecode)) {
            console2.log("-> Full Bytecode Match: Success\n");
        } else {
            console2.log("-> Full Bytecode Match: Fail\n");
        }
    }

    function verifyPartialMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying partial bytecode match...");

        // Fetch runtime bytecode from on-chain addresses
        bytes memory localBytecode = localDeployed.code;
        bytes memory onchainRuntimeBytecode = deployedImpl.code;
        
        // Optionally check length first (not strictly necessary if doing a partial match)
        if (localBytecode.length == 0 || onchainRuntimeBytecode.length == 0) {
            revert("One of the bytecode arrays is empty, cannot verify.");
        }

        // Attempt to trim metadata from both local and on-chain bytecode
        bytes memory trimmedLocal = trimMetadata(localBytecode);
        bytes memory trimmedOnchain = trimMetadata(onchainRuntimeBytecode);

        // If trimmed lengths differ significantly, it suggests structural differences in code
        if (trimmedLocal.length != trimmedOnchain.length) {
            revert("Post-trim length mismatch: potential code differences.");
        }

        // Compare trimmed arrays byte-by-byte
        if (compareBytes(trimmedLocal, trimmedOnchain)) {
            console2.log("-> Partial Bytecode Match: Success\n");
        } else {
            console2.log("-> Partial Bytecode Match: Fail\n");
        }
    }

    function verifyLengthMatch(address deployedImpl, address localDeployed) public view {
        console2.log("Verifying length match...");
        bytes memory localBytecode = localDeployed.code;
        bytes memory onchainRuntimeBytecode = deployedImpl.code;

        if (localBytecode.length == onchainRuntimeBytecode.length) {
            console2.log("-> Length Match: Success\n");
        } else {
            console2.log("-> Length Match: Fail\n");
        }
    }

    function verifyContractByteCodeMatch(address deployedImpl, address localDeployed) public {
        verifyLengthMatch(deployedImpl, localDeployed);
        verifyPartialMatch(deployedImpl, localDeployed);
        verifyFullMatch(deployedImpl, localDeployed);
    }

    // ─────────────────────── strict (reverting) comparisons ───────────────────────
    //
    // The three functions above only console.log Success/Fail, which is right for an
    // exploratory run but useless as a gate: a verification script must revert so its exit
    // code can be trusted. These two do that. Both take a label so a red run names the
    // contract that failed.

    /// @dev local address => on-chain address bindings found in the contract being compared.
    ///      Shared scratch space, reset at the start of every top-level comparison.
    address[] private bindingLocal;
    address[] private bindingOnchain;

    /**
     * @notice Byte-for-byte runtime code equality, metadata included, or revert.
     * @dev Use for contracts that embed no addresses in their code: constructor-arg immutables
     *      bake identically into a local redeploy, so exact equality is the right bar. For a UUPS
     *      implementation or a contract calling linked libraries, use
     *      `requireCodeMatchAllowingAddressEmbeds` instead — this one will reject a CORRECT
     *      deployment.
     * @param label Name used in log lines and revert messages.
     * @param onchain The deployed address being verified.
     * @param local A fresh local deploy from current source with the same constructor args.
     */
    function requireExactCodeMatch(string memory label, address onchain, address local) internal {
        require(onchain.code.length != 0, string.concat(label, ": not deployed on-chain"));
        require(local.code.length != 0, string.concat(label, ": local reference has no code"));
        console2.log(string.concat("-------------- ", label, " ----------------"));
        verifyContractByteCodeMatch(onchain, local);
        require(keccak256(onchain.code) == keccak256(local.code), string.concat(label, ": bytecode mismatch - source drift since broadcast"));
        console2.log(string.concat("  [OK] ", label, " exact match"));
    }

    /**
     * @notice Runtime code equality except for embedded ADDRESSES, or revert.
     * @dev Required for any OZ `UUPSUpgradeable` implementation: it embeds its own deploy address
     *      (`__self`, for the delegatecall guard), so a correct deployment can never byte-match a
     *      local redeploy. Same for contracts linked against libraries, whose addresses differ
     *      between the broadcast and the local simulation.
     *
     *      The rule: equality everywhere except 20-byte windows forming a CONSISTENT
     *      (localAddr => onchainAddr) binding where localAddr holds code in the simulation. The
     *      code-bearing requirement is what pins window alignment — sliding the window off a real
     *      PUSH20 operand yields a garbage address with no code, so the mismatch stays
     *      unexplained and reverts. The contract's own binding must map local=>onchain exactly;
     *      every other binding is a linked library and is verified recursively under the same
     *      rules. A contract with no embeds finds no bindings and degenerates to exact equality,
     *      so this is always the safe choice when unsure.
     * @param label Name used in log lines and revert messages.
     * @param onchain The deployed address being verified.
     * @param local A fresh local deploy from current source with the same constructor args.
     */
    function requireCodeMatchAllowingAddressEmbeds(string memory label, address onchain, address local) internal {
        delete bindingLocal;
        delete bindingOnchain;
        _requireCodeMatch(label, onchain, local);
        console2.log(string.concat("  [OK] ", label, " matches (address embeds reconciled)"));
    }

    function _requireCodeMatch(string memory label, address onchain, address local) private {
        bytes memory oc = onchain.code;
        bytes memory lc = local.code;
        require(oc.length != 0, string.concat(label, ": not deployed on-chain"));
        require(lc.length != 0, string.concat(label, ": local reference has no code"));
        require(oc.length == lc.length, string.concat(label, ": bytecode length mismatch - source drift since broadcast"));

        uint256 i;
        while (i < lc.length) {
            if (lc[i] == oc[i]) {
                ++i;
                continue;
            }
            i = _consumeBindingWindow(label, lc, oc, i);
        }

        // Snapshot before recursion — the recursive call reuses the shared binding arrays.
        address[] memory locals = bindingLocal;
        address[] memory onchains = bindingOnchain;
        for (uint256 j = 0; j < locals.length; ++j) {
            if (locals[j] == local) {
                require(onchains[j] == onchain, string.concat(label, ": self-address binding mismatch"));
            } else {
                _requireCodeMatch(string.concat(label, ".lib"), onchains[j], locals[j]);
            }
        }
    }

    /// @dev Interprets the mismatch at index `i` as part of a 20-byte embedded address. Scans the
    ///      candidate window starts (the address must begin at or up to 19 bytes before `i`, since
    ///      every byte before `i` matched) and accepts the first alignment whose local 20 bytes are
    ///      a code-bearing address with a consistent binding. Returns the index after the window.
    function _consumeBindingWindow(string memory label, bytes memory lc, bytes memory oc, uint256 i) private returns (uint256) {
        uint256 sMin = i >= 19 ? i - 19 : 0;
        for (uint256 s = i + 1; s > sMin;) {
            --s;
            if (s + 20 > lc.length) continue;
            address la = _addrAt(lc, s);
            if (la == address(0) || la.code.length == 0) continue;
            address oa = _addrAt(oc, s);
            (bool known, address expected) = _binding(la);
            if (known && expected != oa) continue;
            if (!known) {
                bindingLocal.push(la);
                bindingOnchain.push(oa);
            }
            return s + 20;
        }
        revert(string.concat(label, ": unexplained bytecode mismatch - source drift since broadcast"));
    }

    function _binding(address localAddr) private view returns (bool, address) {
        for (uint256 j = 0; j < bindingLocal.length; ++j) {
            if (bindingLocal[j] == localAddr) return (true, bindingOnchain[j]);
        }
        return (false, address(0));
    }

    function _addrAt(bytes memory code, uint256 offset) private pure returns (address) {
        uint256 value;
        for (uint256 k = 0; k < 20; ++k) {
            value = (value << 8) | uint8(code[offset + k]);
        }
        return address(uint160(value));
    }

    // A helper function to remove metadata (CBOR encoded) from the end of the bytecode.
    // This is a heuristic based on known patterns in the metadata.
    function trimMetadata(bytes memory code) internal pure returns (bytes memory) {
        // Metadata usually starts with 0xa2 or a similar tag near the end.
        // We can scan backward for a known marker. 
        // In Solidity 0.8.x, metadata often starts near the end with 0xa2 0x64 ... pattern.
        // This is a simplified approach and may need refinement.
        
        // For a more robust approach, you'd analyze the last bytes. 
        // Typically, the CBOR metadata is at the very end of the bytecode.
        uint256 length = code.length;
        if (length < 4) {
            // Bytecode too short to have metadata
            return code;
        }

        // Scan backward for a CBOR header (0xa2).
        // We'll just look for 0xa2 from the end and truncate there.
        for (uint256 i = length - 1; i > 0; i--) {
            if (code[i] == 0xa2) {
                console2.log("Found metadata start at index: ", i);
                // print 8 bytes from this point
                bytes memory tmp = new bytes(8);
                for (uint256 j = 0; j < 8; j++) {
                    tmp[j] = code[i + j];
                }

                // Found a possible metadata start. We'll cut just before 0xa2.
                bytes memory trimmed = new bytes(i);
                for (uint256 j = 0; j < i; j++) {
                    trimmed[j] = code[j];
                }
                return trimmed;
            }
        }

        // If no metadata marker found, return as is.
        return code;
    }
    
}
