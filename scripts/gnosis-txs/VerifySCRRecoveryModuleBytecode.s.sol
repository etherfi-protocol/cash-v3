// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { Utils } from "../utils/Utils.sol";
import { SCRRecoveryModule } from "../../src/modules/scr/SCRRecoveryModule.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";

/// @title VerifySCRRecoveryModuleBytecode
/// @notice Re-deploys the SCRRecoveryModule implementation and the new EtherFiHook
///         implementation locally from source and diffs their runtime bytecode against
///         the on-chain CREATE3-deployed contracts on Scroll mainnet. Also confirms the
///         on-chain addresses match the deterministic CREATE3 addresses derived from the
///         same salts used by DeploySCRRecoveryModule.s.sol.
///
/// @dev    Both contracts inherit OpenZeppelin `UUPSUpgradeable`, which embeds an
///         `address private immutable __self = address(this)`. A freshly deployed local
///         copy therefore carries a different `__self`, producing benign 20-byte diffs in
///         the otherwise informational `verifyContractByteCodeMatch` output. To still
///         assert a genuine clean match, `_assertRuntimeMatch` normalizes each contract's
///         own-address immutable out of both runtime blobs before requiring exact equality
///         — so the script reverts on any *real* (non-immutable) bytecode difference.
///
/// Usage:
///   ENV=mainnet forge script scripts/gnosis-txs/VerifySCRRecoveryModuleBytecode.s.sol \
///     --rpc-url https://rpc.scroll.io -vvv
contract VerifySCRRecoveryModuleBytecode is Script, ContractCodeChecker, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Deterministic salts (prod) — must match DeploySCRRecoveryModule.s.sol.
    bytes32 constant SALT_SCR_MODULE_IMPL = keccak256("SCRRecoveryModule.Prod.Impl");
    bytes32 constant SALT_HOOK_IMPL = keccak256("SCRRecoveryModule.Prod.HookImpl");

    // Expected on-chain addresses (Scroll mainnet).
    address constant SCR_MODULE_IMPL = 0x3B6Fad5bba52cf3219F3A926606D859Dc91f256c;
    address constant NEW_HOOK_IMPL = 0x837416Fc8Af8E222344F0E230Cc2fE31ac52b212;

    function run() public {
        require(block.chainid == 534_352, "Must run on Scroll (534352)");

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");

        console2.log("=============================================");
        console2.log("  SCRRecoveryModule Bytecode Verification (Scroll)");
        console2.log("=============================================");
        console2.log("dataProvider:", dataProvider);
        console2.log("");

        // 1. SCRRecoveryModule implementation
        {
            address predicted = CREATE3.predictDeterministicAddress(SALT_SCR_MODULE_IMPL, NICKS_FACTORY);
            console2.log("1. SCRRecoveryModule impl");
            console2.log("   predicted (CREATE3):", predicted);
            console2.log("   expected on-chain:  ", SCR_MODULE_IMPL);
            require(predicted == SCR_MODULE_IMPL, "SCRRecoveryModule impl address mismatch");
            require(SCR_MODULE_IMPL.code.length > 0, "SCRRecoveryModule impl not deployed on-chain");
            address local = address(new SCRRecoveryModule(dataProvider));
            verifyContractByteCodeMatch(SCR_MODULE_IMPL, local);
            _assertRuntimeMatch(SCR_MODULE_IMPL, local);
        }

        // 2. EtherFiHook implementation (new)
        {
            address predicted = CREATE3.predictDeterministicAddress(SALT_HOOK_IMPL, NICKS_FACTORY);
            console2.log("2. EtherFiHook impl (new)");
            console2.log("   predicted (CREATE3):", predicted);
            console2.log("   expected on-chain:  ", NEW_HOOK_IMPL);
            require(predicted == NEW_HOOK_IMPL, "EtherFiHook impl address mismatch");
            require(NEW_HOOK_IMPL.code.length > 0, "EtherFiHook impl not deployed on-chain");
            address local = address(new EtherFiHook(dataProvider));
            verifyContractByteCodeMatch(NEW_HOOK_IMPL, local);
            _assertRuntimeMatch(NEW_HOOK_IMPL, local);
        }

        console2.log("=============================================");
        console2.log("  ALL CHECKS PASSED (clean match)");
        console2.log("=============================================");
    }

    /// @dev Requires the on-chain and local runtime bytecode to be identical after
    ///      normalizing out each contract's own-address `__self` immutable (UUPS).
    ///      Reverts on any non-immutable difference, guaranteeing a true clean match.
    function _assertRuntimeMatch(address onchain, address local) internal view {
        bytes memory a = _normalizeSelf(onchain.code, onchain);
        bytes memory b = _normalizeSelf(local.code, local);
        require(a.length == b.length, "runtime length mismatch");
        require(keccak256(a) == keccak256(b), "runtime bytecode mismatch (beyond __self immutable)");
    }

    /// @dev Returns a copy of `code` with every 20-byte occurrence of `self` zeroed out.
    ///      This neutralizes the OZ UUPS `__self = address(this)` immutable so two copies
    ///      deployed at different addresses can be compared exactly.
    function _normalizeSelf(bytes memory code, address self) internal pure returns (bytes memory out) {
        out = code;
        bytes20 target = bytes20(self);
        if (out.length < 20) return out;
        for (uint256 i = 0; i <= out.length - 20; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20; j++) {
                if (out[i + j] != target[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                for (uint256 j = 0; j < 20; j++) out[i + j] = 0;
            }
        }
    }
}
