// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ILayerZeroTeller } from "../interfaces/ILayerZeroTeller.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "../interfaces/IOFT.sol";
import { IL2GatewayRouter } from "../interfaces/IScrollERC20Bridge.sol";
import { ICashModule, Mode, SafeTiers, SafeData } from "../interfaces/ICashModule.sol";
import { CashLens } from "../modules/cash/CashLens.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IHopV2 } from "../interfaces/IHopV2.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { TopUpDestWithMigration } from "../top-up/TopUpDestWithMigration.sol";

/**
 * @title MigrationBridgeModule
 * @author ether.fi
 * @notice Bridges all of a user's collateral from their Scroll safe to Ethereum
 *         mainnet (or HyperEVM for HYPE tokens) in a single etherFiWallet call.
 * @dev UUPS upgradeable via UpgradeableProxy. Must be registered as a default module
 *      on EtherFiDataProvider so it can call execTransactionFromModule on any safe.
 *      The EtherFiHook must be updated to skip ensureHealth for this module,
 *      allowing users with outstanding debt to bridge collateral out during migration.
 *
 *      Supports five bridge types, configured per token via configureTokens():
 *      - TELLER:     Boring Vault teller bridge (LiquidETH, LiquidBTC, LiquidUSD, EUSD, EBTC, sETHFI)
 *      - OFT:        LayerZero OFT bridge (weETH, ETHFI, wHYPE, beHype, EURC)
 *      - CANONICAL:  Scroll native L2→L1 bridge (USDC, USDT, WETH)
 *      - HOP:        Frax Hop V2 bridge via Fraxtal hub (frxUSD)
 *      - SKIP:       Token is not bridged (SCR, LiquidReserve)
 *
 *      All bridge calls are executed FROM the safe via execTransactionFromModule.
 *      ETH for LZ fees is sent to the safe before bridge calls. Remaining ETH is
 *      refunded to the caller after all safes are processed.
 *
 *      Emits BridgeAllExecuted per safe with the user's CashModule config (mode, tier,
 *      spending limits) so the backend can reconstruct state on Optimism.
 */
contract MigrationBridgeModule is UpgradeableProxy {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Bridge method for a token
    enum BridgeType { SKIP, TELLER, OFT, CANONICAL, HOP }

    /**
     * @notice Configuration for how a specific token should be bridged
     * @param bridgeType The bridge method to use
     * @param bridgeContract Address of the bridge contract (teller for TELLER, OFT/adapter for OFT,
     *        hop contract for HOP, unused for CANONICAL/SKIP)
     * @param destEid LayerZero endpoint ID of the destination chain (e.g. 30101 for Ethereum mainnet)
     */
    struct TokenBridgeConfig {
        BridgeType bridgeType;
        address bridgeContract;
        uint32 destEid;
    }

    /// @custom:storage-location erc7201:etherfi.storage.MigrationBridgeModule
    struct MigrationBridgeModuleStorage {
        /// @notice Ordered list of token addresses to bridge
        address[] tokens;
        /// @notice Bridge configuration per token
        mapping(address token => TokenBridgeConfig config) tokenConfig;
    }

    /// @notice Storage location for MigrationBridgeModuleStorage (ERC-7201 compliant)
    /// @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.MigrationBridgeModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MigrationBridgeModuleStorageLocation =
        0x916bd4163fccada594d6ae11556a2d506592c511e7f1597ab561b62d16464900;

    /// @notice Scroll L2 ERC20 gateway router for canonical bridge withdrawals
    address public constant GATEWAY_ROUTER = 0x4C0926FF5252A435FD19e10ED15e5a249Ba19d79;

    /// @notice Sentinel address representing native ETH (used as feeToken for teller)
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Gas limit passed to Scroll canonical bridge for L1 execution
    uint64 public constant CANONICAL_GAS_LIMIT = 200_000;

    /// @notice Interface for accessing protocol data (safes, modules, cash module)
    IEtherFiDataProvider public immutable dataProvider;

    /// @notice TopUpDest contract to mark safes as migrated (blocks future top-ups)
    TopUpDestWithMigration public immutable topUpDest;

    /// @notice Role required to call bridgeAll (same as CashModule's wallet role)
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    /// @notice Role required to call configureTokens
    bytes32 public constant MIGRATION_BRIDGE_ADMIN_ROLE = keccak256("MIGRATION_BRIDGE_ADMIN_ROLE");

    /**
     * @notice Emitted when all tokens are bridged for a safe
     * @param safe Address of the user's safe
     * @param tokenCount Number of tokens bridged (excludes SKIP and zero-balance tokens)
     * @param mode User's current CashModule operating mode (Credit or Debit)
     * @param tier User's safe tier (Pepe, Wojak, Chad, Whale, Business)
     * @param creditMaxSpendInUsd Max spendable in credit mode in USD (6 decimals)
     * @param debitMaxSpendInUsd Max spendable in debit mode in USD (6 decimals)
     */
    event BridgeAllExecuted(
        address indexed safe,
        uint256 tokenCount,
        Mode mode,
        SafeTiers tier,
        uint256 creditMaxSpendInUsd,
        uint256 debitMaxSpendInUsd
    );

    /**
     * @notice Emitted when an individual token is bridged from a safe
     * @param safe Address of the user's safe
     * @param token Address of the token that was bridged
     * @param bridgeType The bridge method used
     * @param amount Amount of tokens bridged
     */
    event TokenBridged(address indexed safe, address indexed token, BridgeType bridgeType, uint256 amount);

    /**
     * @notice Emitted when the token bridge configuration is updated
     * @param count Number of tokens configured
     */
    event TokensConfigured(uint256 count);

    /// @notice Thrown when caller does not have ETHER_FI_WALLET_ROLE
    error OnlyEtherFiWallet();
    /// @notice Thrown when caller does not have MIGRATION_BRIDGE_ADMIN_ROLE
    error OnlyAdmin();
    /// @notice Thrown when the provided address is not a registered EtherFi Safe
    error NotEtherFiSafe();
    /// @notice Thrown when input arrays have different lengths
    error ArrayLengthMismatch();
    /// @notice Thrown when an ETH transfer (fee payment or refund) fails
    error NativeTransferFailed();

    /**
     * @dev Constructor sets the immutable data provider and disables initializers
     *      on the implementation contract to prevent direct initialization.
     * @param _dataProvider Address of the EtherFiDataProvider contract
     */
    constructor(address _dataProvider, address _topUpDest) {
        dataProvider = IEtherFiDataProvider(_dataProvider);
        topUpDest = TopUpDestWithMigration(payable(_topUpDest));
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with a role registry for access control
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @dev Returns the namespaced storage struct
     * @return $ Reference to MigrationBridgeModuleStorage
     */
    function _getMigrationBridgeModuleStorage() internal pure returns (MigrationBridgeModuleStorage storage $) {
        assembly { $.slot := MigrationBridgeModuleStorageLocation }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ADMIN
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Configures the list of tokens and their bridge routes
     * @dev Replaces any existing configuration. Each token is mapped to a BridgeType,
     *      bridge contract address, and destination LZ endpoint ID.
     *      Only callable by accounts with MIGRATION_BRIDGE_ADMIN_ROLE.
     * @param _tokens Ordered array of token addresses to configure
     * @param _configs Bridge configuration for each token (must match _tokens length)
     */
    function configureTokens(address[] calldata _tokens, TokenBridgeConfig[] calldata _configs) external {
        if (!dataProvider.roleRegistry().hasRole(MIGRATION_BRIDGE_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        if (_tokens.length != _configs.length) revert ArrayLengthMismatch();

        MigrationBridgeModuleStorage storage $ = _getMigrationBridgeModuleStorage();

        for (uint256 i = 0; i < $.tokens.length;) {
            delete $.tokenConfig[$.tokens[i]];
            unchecked { ++i; }
        }
        delete $.tokens;

        for (uint256 i = 0; i < _tokens.length;) {
            $.tokens.push(_tokens[i]);
            $.tokenConfig[_tokens[i]] = _configs[i];
            unchecked { ++i; }
        }

        emit TokensConfigured(_tokens.length);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       BRIDGE ALL
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Bridges all configured tokens from multiple safes in one transaction
     * @dev Iterates through each safe and bridges all non-zero-balance tokens according to
     *      their configured bridge type. ETH for LZ fees is forwarded to each safe as needed.
     *      Any remaining ETH after all bridges is refunded to msg.sender.
     *      Emits BridgeAllExecuted per safe with the user's CashModule config.
     *      Only callable by accounts with ETHER_FI_WALLET_ROLE.
     * @param safes Array of EtherFi Safe addresses to process
     */
    function bridgeAll(address[] calldata safes) external payable {
        if (!dataProvider.roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();

        for (uint256 s = 0; s < safes.length;) {
            _bridgeAllForSafe(safes[s]);
            unchecked { ++s; }
        }

        // Mark safes as migrated on TopUpDest to block future top-ups
        topUpDest.setMigrated(safes);

        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool ok,) = msg.sender.call{ value: remaining }("");
            if (!ok) revert NativeTransferFailed();
        }
    }

    /**
     * @notice Quotes the total ETH fee needed to bridge all tokens for multiple safes
     * @dev Sums up LZ messaging fees for all TELLER, OFT, and HOP bridges.
     *      CANONICAL and SKIP tokens do not incur LZ fees.
     * @param safes Array of EtherFi Safe addresses to quote
     * @return totalFee Total ETH required to cover all LayerZero messaging fees
     */
    function quoteBridgeAll(address[] calldata safes) external view returns (uint256 totalFee) {
        for (uint256 s = 0; s < safes.length;) {
            totalFee += _quoteBridgeAllForSafe(safes[s]);
            unchecked { ++s; }
        }
    }

    /**
     * @dev Bridges all configured tokens for a single safe
     * @param safe Address of the EtherFi Safe
     * @return ethUsed Total ETH spent on LZ fees for this safe
     */
    function _bridgeAllForSafe(address safe) internal returns (uint256 ethUsed) {
        if (!dataProvider.isEtherFiSafe(safe)) revert NotEtherFiSafe();

        (SafeData memory safeData, SafeTiers tier, uint256 creditMax, uint256 debitMax) = _getSafeInfo(safe);

        MigrationBridgeModuleStorage storage $ = _getMigrationBridgeModuleStorage();
        uint256 bridgedCount;
        uint256 len = $.tokens.length;

        for (uint256 i = 0; i < len;) {
            address token = $.tokens[i];
            uint256 balance = IERC20(token).balanceOf(safe);

            if (balance > 0) {
                TokenBridgeConfig memory cfg = $.tokenConfig[token];

                if (cfg.bridgeType == BridgeType.TELLER) {
                    // Teller uses LZ under the hood — amount is cast to uint96 (no dust issue)
                    ethUsed += _bridgeViaTeller(safe, token, balance, cfg);
                    bridgedCount++;
                } else if (cfg.bridgeType == BridgeType.OFT) {
                    // Remove LZ OFT dust — bottom decimals truncated by shared decimals
                    uint256 bridgeAmount = _removeDust(cfg.bridgeContract, balance);
                    if (bridgeAmount > 0) {
                        ethUsed += _bridgeViaOft(safe, token, bridgeAmount, cfg);
                        bridgedCount++;
                    }
                } else if (cfg.bridgeType == BridgeType.CANONICAL) {
                    _bridgeViaCanonical(safe, token, balance);
                    bridgedCount++;
                } else if (cfg.bridgeType == BridgeType.HOP) {
                    // Hop uses OFT under the hood — remove dust
                    uint256 bridgeAmount = _removeDust(token, balance);
                    if (bridgeAmount > 0) {
                        ethUsed += _bridgeViaHop(safe, token, bridgeAmount, cfg);
                        bridgedCount++;
                    }
                }
            }
            unchecked { ++i; }
        }

        emit BridgeAllExecuted(
            safe,
            bridgedCount,
            safeData.mode,
            tier,
            creditMax,
            debitMax
        );
    }

    /**
     * @dev Reads safe info from CashModule and CashLens to reduce stack depth in _bridgeAllForSafe
     */
    function _getSafeInfo(address safe) internal view returns (SafeData memory safeData, SafeTiers tier, uint256 creditMax, uint256 debitMax) {
        ICashModule cashModule = ICashModule(dataProvider.getCashModule());
        safeData = cashModule.getData(safe);
        tier = cashModule.getSafeTier(safe);

        CashLens cashLens = CashLens(dataProvider.getCashLens());
        creditMax = cashLens.getMaxSpendCredit(safe);
        IDebtManager debtManager = cashModule.getDebtManager();
        debitMax = cashLens.getMaxSpendDebit(safe, debtManager.getBorrowTokens()).totalSpendableInUsd;
    }

    /**
     * @dev Quotes total LZ fees for bridging all tokens from a single safe
     * @param safe Address of the EtherFi Safe
     * @return totalFee Total ETH required for LZ fees
     */
    function _quoteBridgeAllForSafe(address safe) internal view returns (uint256 totalFee) {
        MigrationBridgeModuleStorage storage $ = _getMigrationBridgeModuleStorage();
        uint256 len = $.tokens.length;
        for (uint256 i = 0; i < len;) {
            address token = $.tokens[i];
            uint256 balance = IERC20(token).balanceOf(safe);

            if (balance > 0) {
                TokenBridgeConfig memory cfg = $.tokenConfig[token];
                if (cfg.bridgeType == BridgeType.TELLER) {
                    totalFee += _quoteTeller(safe, balance, cfg);
                } else if (cfg.bridgeType == BridgeType.OFT) {
                    uint256 amt = _removeDust(cfg.bridgeContract, balance);
                    if (amt > 0) totalFee += _quoteOft(safe, amt, cfg);
                } else if (cfg.bridgeType == BridgeType.HOP) {
                    uint256 amt = _removeDust(token, balance);
                    if (amt > 0) totalFee += _quoteHop(token, safe, amt, cfg);
                }
            }
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TELLER (Liquid tokens)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Bridges tokens via a Boring Vault LayerZero teller.
     *      The safe approves the teller, then calls teller.bridge() directly.
     *      ETH is sent to the safe beforehand to cover the LZ messaging fee.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the liquid vault token (e.g. LiquidETH)
     * @param amount Amount of vault shares to bridge
     * @param cfg Bridge configuration containing teller address and destination EID
     * @return fee ETH spent on the LZ messaging fee
     */
    function _bridgeViaTeller(address safe, address token, uint256 amount, TokenBridgeConfig memory cfg) internal returns (uint256 fee) {
        ILayerZeroTeller teller = ILayerZeroTeller(cfg.bridgeContract);
        bytes memory bridgeWildCard = abi.encode(cfg.destEid);

        fee = teller.previewFee(amount.toUint96(), safe, bridgeWildCard, ERC20(ETH));

        (bool ok,) = safe.call{ value: fee }("");
        if (!ok) revert NativeTransferFailed();

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = token;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, cfg.bridgeContract, amount);

        to[1] = cfg.bridgeContract;
        data[1] = abi.encodeWithSelector(
            ILayerZeroTeller.bridge.selector,
            amount.toUint96(), safe, bridgeWildCard, ERC20(ETH), fee
        );
        values[1] = fee;

        to[2] = token;
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, cfg.bridgeContract, 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit TokenBridged(safe, token, BridgeType.TELLER, amount);
    }

    /**
     * @dev Quotes the LZ fee for a teller bridge
     * @param safe Address of the recipient on the destination chain
     * @param amount Amount of vault shares to bridge
     * @param cfg Bridge configuration
     * @return LZ messaging fee in ETH
     */
    function _quoteTeller(address safe, uint256 amount, TokenBridgeConfig memory cfg) internal view returns (uint256) {
        bytes memory bridgeWildCard = abi.encode(cfg.destEid);
        return ILayerZeroTeller(cfg.bridgeContract).previewFee(amount.toUint96(), safe, bridgeWildCard, ERC20(ETH));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    OFT (weETH, ETHFI, HYPE, EURC)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Bridges tokens via LayerZero OFT send.
     *      The safe approves the OFT contract, calls OFT.send() which burns/locks
     *      tokens from the safe, then resets the approval.
     *      ETH is sent to the safe beforehand to cover the LZ messaging fee.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the ERC20 token (may differ from OFT contract for adapters)
     * @param amount Amount of tokens to bridge
     * @param cfg Bridge configuration containing OFT/adapter address and destination EID
     * @return fee ETH spent on the LZ messaging fee
     */
    function _bridgeViaOft(address safe, address token, uint256 amount, TokenBridgeConfig memory cfg) internal returns (uint256 fee) {
        IOFT oft = IOFT(cfg.bridgeContract);

        SendParam memory sendParam = SendParam({
            dstEid: cfg.destEid,
            to: bytes32(uint256(uint160(safe))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: hex"0003",
            composeMsg: new bytes(0),
            oftCmd: new bytes(0)
        });

        (,, OFTReceipt memory receipt) = oft.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory msgFee = oft.quoteSend(sendParam, false);
        fee = msgFee.nativeFee;

        (bool ok,) = safe.call{ value: fee }("");
        if (!ok) revert NativeTransferFailed();

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = token;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, cfg.bridgeContract, amount);

        to[1] = cfg.bridgeContract;
        data[1] = abi.encodeWithSelector(IOFT.send.selector, sendParam, msgFee, safe);
        values[1] = fee;

        to[2] = token;
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, cfg.bridgeContract, 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit TokenBridged(safe, token, BridgeType.OFT, amount);
    }

    /**
     * @dev Quotes the LZ fee for an OFT bridge
     * @param safe Address of the recipient on the destination chain
     * @param amount Amount of tokens to bridge
     * @param cfg Bridge configuration
     * @return LZ messaging fee in ETH
     */
    function _quoteOft(address safe, uint256 amount, TokenBridgeConfig memory cfg) internal view returns (uint256) {
        SendParam memory sendParam = SendParam({
            dstEid: cfg.destEid,
            to: bytes32(uint256(uint160(safe))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: hex"0003",
            composeMsg: new bytes(0),
            oftCmd: new bytes(0)
        });
        return IOFT(cfg.bridgeContract).quoteSend(sendParam, false).nativeFee;
    }

    // ═══════════════════════════════════════════════════════════════
    //                 CANONICAL (USDC, USDT, WETH)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Bridges tokens via the Scroll native L2→L1 canonical bridge.
     *      The safe approves the token-specific gateway, calls withdrawERC20 on the
     *      L2GatewayRouter, then resets the approval. No LZ fee required.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the ERC20 token to bridge
     * @param amount Amount of tokens to bridge
     */
    function _bridgeViaCanonical(address safe, address token, uint256 amount) internal {
        address gateway = IL2GatewayRouter(GATEWAY_ROUTER).getERC20Gateway(token);

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = token;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, gateway, amount);

        to[1] = GATEWAY_ROUTER;
        data[1] = abi.encodeWithSelector(IL2GatewayRouter.withdrawERC20.selector, token, safe, amount, CANONICAL_GAS_LIMIT);

        to[2] = token;
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, gateway, 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit TokenBridged(safe, token, BridgeType.CANONICAL, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    HOP (frxUSD via Frax Hop V2)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Bridges tokens via the Frax Hop V2 hub-and-spoke bridge.
     *      The token routes through Fraxtal before arriving at the destination chain.
     *      The safe approves the underlying token to the hop contract, calls sendOFT(),
     *      then resets the approval.
     *      ETH is sent to the safe beforehand to cover the LZ messaging fee.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the OFT token (e.g. frxUSD)
     * @param amount Amount of tokens to bridge
     * @param cfg Bridge configuration containing hop contract address and destination EID
     * @return fee ETH spent on the LZ messaging fee
     */
    function _bridgeViaHop(address safe, address token, uint256 amount, TokenBridgeConfig memory cfg) internal returns (uint256 fee) {
        IHopV2 hop = IHopV2(cfg.bridgeContract);
        bytes32 recipient = bytes32(uint256(uint160(safe)));

        fee = hop.quote(token, cfg.destEid, recipient, amount, 0, "");

        address underlying = IOFT(token).token();

        (bool ok,) = safe.call{ value: fee }("");
        if (!ok) revert NativeTransferFailed();

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = underlying;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, cfg.bridgeContract, amount);

        to[1] = cfg.bridgeContract;
        data[1] = abi.encodeWithSelector(IHopV2.sendOFT.selector, token, cfg.destEid, recipient, amount);
        values[1] = fee;

        to[2] = underlying;
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, cfg.bridgeContract, 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit TokenBridged(safe, token, BridgeType.HOP, amount);
    }

    /**
     * @dev Quotes the LZ fee for a Frax Hop V2 bridge
     * @param token Address of the OFT token
     * @param safe Address of the recipient on the destination chain
     * @param amount Amount of tokens to bridge
     * @param cfg Bridge configuration
     * @return LZ messaging fee in ETH
     */
    function _quoteHop(address token, address safe, uint256 amount, TokenBridgeConfig memory cfg) internal view returns (uint256) {
        bytes32 recipient = bytes32(uint256(uint160(safe)));
        return IHopV2(cfg.bridgeContract).quote(token, cfg.destEid, recipient, amount, 0, "");
    }

    // ═══════════════════════════════════════════════════════════════
    //                        HELPERS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Removes LZ OFT dust from an amount. OFT tokens use sharedDecimals (typically 6)
     *      while the local token may have 18 decimals. The bottom (localDecimals - sharedDecimals)
     *      digits are truncated by LZ and cannot be bridged. This function rounds down to the
     *      nearest bridgeable amount. The dust stays in the safe (negligible value).
     * @param oft Address of the OFT contract (or adapter)
     * @param amount Raw token balance
     * @return Dust-free amount that LZ can bridge
     */
    function _removeDust(address oft, uint256 amount) internal view returns (uint256) {
        try IOFT(oft).sharedDecimals() returns (uint8 shared) {
            try IOFT(oft).token() returns (address underlying) {
                uint8 local = underlying == address(0)
                    ? 18
                    : ERC20(underlying).decimals();
                if (local > shared) {
                    uint256 conversionRate = 10 ** (local - shared);
                    return (amount / conversionRate) * conversionRate;
                }
            } catch {
                // token() not available, try decimals on the OFT itself
                uint8 local = ERC20(oft).decimals();
                if (local > shared) {
                    uint256 conversionRate = 10 ** (local - shared);
                    return (amount / conversionRate) * conversionRate;
                }
            }
        } catch {}
        return amount; // no shared decimals = no dust issue
    }

    /**
     * @dev Executes a single call from the safe via execTransactionFromModule
     * @param safe Address of the EtherFi Safe
     * @param to Target address for the call
     * @param data Calldata to execute
     */
    function _safeExec(address safe, address to, bytes memory data) internal {
        address[] memory tos = new address[](1);
        bytes[] memory datas = new bytes[](1);
        uint256[] memory vals = new uint256[](1);
        tos[0] = to;
        datas[0] = data;
        IEtherFiSafe(safe).execTransactionFromModule(tos, vals, datas);
    }

    /**
     * @notice Returns the list of configured token addresses
     * @return Array of token addresses in bridge order
     */
    function getTokens() external view returns (address[] memory) { return _getMigrationBridgeModuleStorage().tokens; }

    /// @notice Allows the contract to receive ETH (for LZ fee refunds from bridges)
    receive() external payable {}
}
