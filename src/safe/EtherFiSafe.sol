// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IWETH } from "../interfaces/IWETH.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";
import { EtherFiSafeCore } from "./EtherFiSafeCore.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";

/**
 * @title EtherFiSafe
 * @author ether.fi
 * @notice Concrete EtherFiSafe. Ownership and recovery are managed locally on this chain;
 *         there is no cross-chain owner synchronization.
 */
contract EtherFiSafe is EtherFiSafeCore {
    /// @notice WETH on Optimism, the only chain with a live Cash stack
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant ERC1271_INVALID = 0xffffffff;

    /// @dev keccak256("EtherFiSafeMessage(bytes32 message)")
    bytes32 public constant SAFE_MESSAGE_TYPEHASH = 0x495d7dd69491a2fa17065d54c9718fb3a33740030f8b939b73026ffbb07640ba;

    /// @dev Fails the deploy on any chain where WETH is not at that address, rather than shipping a safe
    ///      that reverts on every incoming ETH transfer
    constructor(address _dataProvider) payable EtherFiSafeCore(_dataProvider) {
        if (WETH.code.length == 0) revert InvalidInput();
    }

    /// @notice Wraps the safe's native ETH into WETH, the only form CashModule withdrawals can move
    /// @dev Permissionless. No-ops mid-batch for the same reason `receive` passes those through.
    function wrapEth() external {
        if (inModuleBatch()) return;

        uint256 balance = address(this).balance;
        if (balance != 0) IWETH(WETH).deposit{ value: balance }();
    }

    /// @notice ERC-1271 validation; `signature` is abi.encode(bytes message, address[] signers, bytes[] sigs)
    /// @dev Requiring `hash` to be the EIP-191 hash of `message` is load-bearing, not a formality: EIP-712
    ///      digests begin 0x1901 and the EIP-191 prefix fixes byte 1 to 'E', so no message can hash to one.
    ///      That is what keeps Permit2, Seaport and the Aave Spoke's setUserPositionManagersWithSig
    ///      unsatisfiable here, owner keys included. Relaxing it re-arms them.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes memory message, address[] memory signers, bytes[] memory signatures) = abi.decode(signature, (bytes, address[], bytes[]));

        if (hash != MessageHashUtils.toEthSignedMessageHash(message)) return ERC1271_INVALID;

        bytes32 digestHash = _hashTypedDataV4(keccak256(abi.encode(SAFE_MESSAGE_TYPEHASH, hash)));
        return this.checkSignatures(digestHash, signers, signatures) ? ERC1271_MAGIC_VALUE : ERC1271_INVALID;
    }

    /// @dev Passes ETH through untouched for three senders that need it to stay native: WETH (unwrap would
    ///      recurse, and only carries a 2300-gas stipend), an enabled module (pre-funds the safe then spends
    ///      it as call value — Enso, BeHYPE), and anything mid-batch (a module may be measuring native
    ///      balance across the call — OpenOcean, ModuleCheckBalance). `wrapEth` sweeps what this lets by.
    receive() external payable override {
        if (msg.sender == WETH || isModuleEnabled(msg.sender) || inModuleBatch()) return;
        IWETH(WETH).deposit{ value: msg.value }();
    }
}
