// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { ILayerZeroTeller } from "../interfaces/ILayerZeroTeller.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { ITradingSafeLiquidDepositModule } from "../interfaces/ITradingSafeLiquidDepositModule.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";

/**
 * @title TradingSafeLiquidDepositModule
 * @author ether.fi
 * @notice Safe module on Ethereum mainnet that lets a TradingSafe's owners authorize an atomic
 *         conversion of the safe's WBTC into Liquid BTC, with the freshly minted Liquid BTC
 *         forwarded in the same transaction to the safe's factory-bound TopUp address. From there
 *         the existing, live Liquid BTC TopUp rail bridges the balance to the user's account on
 *         Optimism — this module does not touch the TopUp factory, bridge adapters, or any
 *         Optimism contract.
 * @dev The recipient is never caller-chosen: it is resolved from the TradingSafeFactory as
 *      `getTopUpAddress(safe)` and bound into the owner-quorum digest, so a relayer cannot divert
 *      funds. WBTC is deposited into the Liquid BTC Veda teller and the exact minted delta is
 *      transferred to the TopUp, leaving any pre-existing Liquid BTC in the safe untouched.
 * @dev Moves tokens through the safe itself via `execTransactionFromModule`, so the module must be
 *      **enabled on the safe** (registered as a default module on the mainnet data provider, or
 *      added per-safe). The relayer is untrusted — the owner signatures authorize — so submission
 *      is permissionless. Replay protection is the safe nonce; a signed `deadline` stops a stashed
 *      signature from being replayed later.
 */
contract TradingSafeLiquidDepositModule is ITradingSafeLiquidDepositModule, ModuleBase, Pausable {
    using MessageHashUtils for bytes32;

    /// @notice WBTC token deposited from the safe.
    address public immutable WBTC;
    /// @notice Liquid BTC share token minted by the teller (the teller's `vault()`).
    address public immutable LIQUID_BTC;
    /// @notice Veda LayerZero teller that mints Liquid BTC from WBTC.
    ILayerZeroTeller public immutable teller;

    /// @dev Domain-separator-style prefix for the digest the owners sign.
    bytes32 private constant DEPOSIT_SIG = keccak256("TradingSafeLiquidDepositModule.depositToTopUp");

    /**
     * @param _dataProvider EtherFi data provider (resolves the safe factory and role registry).
     * @param _wbtc WBTC token address.
     * @param _liquidBtc Liquid BTC share token address (must equal `teller.vault()`).
     * @param _liquidBtcTeller Veda teller that mints `_liquidBtc`.
     */
    constructor(address _dataProvider, address _wbtc, address _liquidBtc, address _liquidBtcTeller) ModuleBase(_dataProvider) {
        if (_wbtc == address(0) || _liquidBtc == address(0) || _liquidBtcTeller == address(0)) revert InvalidConfiguration();
        if (address(ILayerZeroTeller(_liquidBtcTeller).vault()) != _liquidBtc) revert InvalidConfiguration();

        WBTC = _wbtc;
        LIQUID_BTC = _liquidBtc;
        teller = ILayerZeroTeller(_liquidBtcTeller);
    }

    function setupModule(bytes calldata) external override { }

    /// @inheritdoc ITradingSafeLiquidDepositModule
    function depositToTopUp(address safe, uint256 wbtcAmount, uint256 minLiquidBtc, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused onlyEtherFiSafe(safe) {
        if (wbtcAmount == 0) revert InvalidAmount();
        if (minLiquidBtc == 0) revert InvalidMinReturn();
        if (block.timestamp > deadline) revert DepositExpired();

        address topUp = ITradingSafeFactory(etherFiDataProvider.getEtherFiSafeFactory()).getTopUpAddress(safe);
        if (topUp == address(0)) revert NoTopUpAddress();

        _verifySignatures(safe, topUp, wbtcAmount, minLiquidBtc, deadline, signers, signatures);
        _checkTellerReady();

        uint256 minted = _depositToLiquid(safe, wbtcAmount, minLiquidBtc);
        _forwardToTopUp(safe, topUp, minted);

        emit DepositedToTopUp(safe, topUp, wbtcAmount, minted);
    }

    /// @dev Rejects the deposit unless the teller currently accepts WBTC and applies no share lock.
    ///      A nonzero share lock would trap the freshly minted Liquid BTC in the safe and revert the
    ///      same-transaction forward, so failing early gives a precise error instead of an opaque one.
    function _checkTellerReady() private view {
        if (!teller.assetData(ERC20(WBTC)).allowDeposits) revert DepositAssetNotAllowed();
        if (teller.shareLockPeriod() != 0) revert SharesLocked();
    }

    /// @dev Deposits exactly `wbtcAmount` WBTC into the Liquid BTC teller through the safe and returns
    ///      the exact Liquid BTC minted. Approves the vault for the deposit and resets the allowance to
    ///      zero in the same batch so no dangling approval remains. Asserts the safe was debited
    ///      precisely `wbtcAmount` — `execTransactionFromModule` only checks call success, not ERC20
    ///      return values — and that the mint cleared the signed minimum.
    function _depositToLiquid(address safe, uint256 wbtcAmount, uint256 minLiquidBtc) private returns (uint256 minted) {
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(safe);
        if (wbtcBefore < wbtcAmount) revert InsufficientBalance();
        uint256 liquidBefore = IERC20(LIQUID_BTC).balanceOf(safe);

        address[] memory to = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory data = new bytes[](3);

        to[0] = WBTC;
        data[0] = abi.encodeCall(IERC20.approve, (LIQUID_BTC, wbtcAmount));
        to[1] = address(teller);
        data[1] = abi.encodeCall(ILayerZeroTeller.deposit, (ERC20(WBTC), wbtcAmount, minLiquidBtc));
        to[2] = WBTC;
        data[2] = abi.encodeCall(IERC20.approve, (LIQUID_BTC, 0));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        if (wbtcBefore - IERC20(WBTC).balanceOf(safe) != wbtcAmount) revert DepositTransferFailed();

        minted = IERC20(LIQUID_BTC).balanceOf(safe) - liquidBefore;
        if (minted < minLiquidBtc) revert InsufficientReturnAmount();
    }

    /// @dev Transfers exactly `minted` Liquid BTC from the safe to `topUp`, asserting the safe returns
    ///      to its pre-deposit Liquid BTC balance (no new shares linger) and the TopUp is credited the
    ///      full minted amount.
    function _forwardToTopUp(address safe, address topUp, uint256 minted) private {
        uint256 safeBefore = IERC20(LIQUID_BTC).balanceOf(safe);
        uint256 topUpBefore = IERC20(LIQUID_BTC).balanceOf(topUp);

        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        to[0] = LIQUID_BTC;
        data[0] = abi.encodeCall(IERC20.transfer, (topUp, minted));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        if (safeBefore - IERC20(LIQUID_BTC).balanceOf(safe) != minted) revert DepositTransferFailed();
        if (IERC20(LIQUID_BTC).balanceOf(topUp) - topUpBefore != minted) revert TopUpCreditFailed();
    }

    /// @dev Verifies the owner quorum, consuming a safe nonce so a signed request can't replay. Binding
    ///      chain id + module address + safe + resolved TopUp + amount + minimum + deadline means the
    ///      signature can't be reused cross-chain, on another module, for a different amount, or after
    ///      `deadline`, and the recipient is fixed to the factory-resolved TopUp.
    function _verifySignatures(address safe, address topUp, uint256 wbtcAmount, uint256 minLiquidBtc, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) private {
        bytes32 digest = keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, topUp, wbtcAmount, minLiquidBtc, deadline)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /// @notice Pause new deposits. PAUSER role only.
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /// @notice Unpause deposits. UNPAUSER role only.
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }
}
