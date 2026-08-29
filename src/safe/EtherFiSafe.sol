// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IWETH } from "../interfaces/IWETH.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";
import { EtherFiSafeCore } from "./EtherFiSafeCore.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { SafeErc1271Lib } from "../libraries/SafeErc1271Lib.sol";

/**
 * @title EtherFiSafe
 * @author ether.fi
 * @notice Concrete EtherFiSafe. Ownership and recovery are managed locally on this chain;
 *         there is no cross-chain owner synchronization.
 */
contract EtherFiSafe is EtherFiSafeCore {
    /// @notice WETH on Optimism, the only chain with a live Cash stack
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev Cold-path cost of `receive`'s checks plus the WETH deposit and event — ~64k measured on an
    ///      Optimism fork — with margin. A sender forwarding less gets the ETH passed through native
    ///      rather than an out-of-gas revert; `wrapEth` sweeps it later.
    uint256 internal constant WRAP_GAS_FLOOR = 90_000;

    bytes4 internal constant ERC1271_INVALID = 0xffffffff;

    /// @dev keccak256("EtherFiSafeMessage(bytes32 message)")
    bytes32 public constant SAFE_MESSAGE_TYPEHASH = 0x495d7dd69491a2fa17065d54c9718fb3a33740030f8b939b73026ffbb07640ba;

    /**
     * @notice Emitted every time native ETH is turned into WETH, by `receive` on arrival or by `wrapEth`
     * @param caller `receive`'s sender, or `wrapEth`'s caller
     * @param amount Amount wrapped, in wei
     * @dev One event for both paths rather than one each: EtherFiSafe sits 46 bytes under the EIP-170
     *      limit before this change, so a second event's emit sites do not fit. Nothing is logged when
     *      ETH passes through as native — no state changed, and the `wrapEth` that later sweeps it logs
     *      the amount then.
     */
    event EthWrapped(address indexed caller, uint256 amount);

    /// @dev Fails the deploy on any chain where WETH is not at that address, rather than shipping a safe
    ///      that reverts on every incoming ETH transfer
    constructor(address _dataProvider) payable EtherFiSafeCore(_dataProvider) {
        if (WETH.code.length == 0) revert InvalidInput();
    }

    /// @notice Wraps the safe's native ETH into WETH, the only form CashModule withdrawals can move
    /// @dev Permissionless. No-ops mid-batch for the same reason `receive` passes those through.
    /// @custom:throws EthWrapPaused If the data provider is paused
    function wrapEth() external {
        if (inModuleBatch()) return;
        // Explicit rather than a silent no-op: a pause is an operator action, and a caller asking for
        // a sweep should learn it did not happen. The mid-batch case above stays silent because a
        // batch may legitimately route through here.
        if (dataProvider.paused()) revert EthWrapPaused();

        uint256 balance = address(this).balance;
        if (balance == 0) return;

        IWETH(WETH).deposit{ value: balance }();
        emit EthWrapped(msg.sender, balance);
    }

    /// @notice ERC-1271 validation; `signature` is abi.encode(bytes message, address[] signers, bytes[] sigs)
    /// @dev Consumers staticcall ERC-1271 without a try/catch and propagate whatever comes back, so this
    ///      must answer rather than revert. Solidity cannot try/catch a library call, so the self-call
    ///      below is what supplies the boundary — it catches the blob decode too, which is the one case
    ///      the library's own try/catch cannot reach.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        try this.validateErc1271Signature(hash, signature) returns (bytes4 magicValue) {
            return magicValue;
        } catch {
            return ERC1271_INVALID;
        }
    }

    /**
     * @notice The reverting half of `isValidSignature`, external only so that it can be try/caught
     * @param hash The hash the consumer is asking about; must be the EIP-191 hash of the signed message
     * @param signature abi.encode(bytes message, address[] signers, bytes[] sigs)
     * @return bytes4 ERC1271_MAGIC_VALUE if the signers meet this safe's threshold, else ERC1271_INVALID
     * @dev The body lives in `SafeErc1271Lib`, a deployed library reached by DELEGATECALL, because the
     *      blob decode and the EIP-191 length prefix do not fit in this contract's runtime-size budget.
     *      Under DELEGATECALL `address(this)` is still this safe, so the owner and threshold checks there
     *      apply to this safe. See that library for the invariant the hash binding preserves.
     *
     *      Reverts on an undecodable blob; callers wanting an answer should use `isValidSignature`.
     */
    function validateErc1271Signature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return SafeErc1271Lib.validate(hash, signature, _domainSeparatorV4(), SAFE_MESSAGE_TYPEHASH);
    }

    /// @dev Passes ETH through untouched for the senders that need it to stay native: WETH (unwrap would
    ///      recurse), any sender forwarding less than WRAP_GAS_FLOOR (a contract's `transfer`/`send`
    ///      gives 2300 gas — reverting would refuse their payment outright, where pre-wrap safes took
    ///      it), anything mid-batch (a module may be measuring native balance across the call —
    ///      OpenOcean, ModuleCheckBalance), an enabled module (pre-funds the safe then spends it as
    ///      call value — Enso, BeHYPE), and everything while the data provider is paused. `wrapEth`
    ///      sweeps what this lets by. Zero-value calls return before any of it: nothing to wrap, so
    ///      no deposit and no event.
    ///
    ///      A pause passes ETH through rather than rejecting it: that restores the exact pre-upgrade
    ///      behaviour, where a paused wrapper cannot strand an inbound transfer. Cheapest checks first —
    ///      the value and WETH compares have to fit a 2300-gas stipend, `gasleft` is 2 gas, and
    ///      `inModuleBatch` is a 100-gas tload, so neither the module lookup nor the pause read is
    ///      reached on the hot paths.
    receive() external payable override {
        if (msg.value == 0 || msg.sender == WETH) return;

        if (gasleft() < WRAP_GAS_FLOOR || inModuleBatch() || isModuleEnabled(msg.sender) || dataProvider.paused()) return;

        IWETH(WETH).deposit{ value: msg.value }();
        emit EthWrapped(msg.sender, msg.value);
    }
}
