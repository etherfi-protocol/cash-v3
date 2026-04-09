// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IStargate, Ticket } from "../interfaces/IStargate.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IBoringOnChainQueue } from "../interfaces/IBoringOnChainQueue.sol";
import { BinSponsor } from "../interfaces/ICashModule.sol";
import { IOFT, MessagingFee, MessagingReceipt, OFTReceipt, SendParam } from "../interfaces/IOFT.sol";
import { IL2StandardBridge } from "../interfaces/IL2StandardBridge.sol";
import { IFraxCustodian } from "../interfaces/IFraxCustodian.sol";
import { IFraxRemoteHop } from "../interfaces/IFraxRemoteHop.sol";
import { IMidasVault } from "../interfaces/IMidasVault.sol";
import { ICCTPTokenMessenger } from "../interfaces/ICCTPTokenMessenger.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { Constants } from "../utils/Constants.sol";

/**
 * @title SettlementDispatcherV2
 * @author shivam@ether.fi
 * @notice This contract receives payments from user safes and bridges it to another chain to pay the fiat provider
 * @dev V2 adds a configurable refund wallet that falls back to the data provider if not set
 */
contract SettlementDispatcherV2 is UpgradeableProxy, Constants {
    using SafeERC20 for IERC20;

    /**
     * @notice Struct containing destination chain information for token bridging
     * @dev Stores all data needed to bridge a token to its destination
     */
    struct DestinationData {
        /// @notice Endpoint ID of the destination chain
        uint32 destEid;
        /// @notice Recipient address on the destination chain
        address destRecipient;
        /// @notice Address of the Stargate router to use for this token
        address stargate;
        /// @notice Whether to use canonical bridge for the token
        bool useCanonicalBridge;
        /// @notice Minimum gas limit for the canonical bridge
        uint64 minGasLimit;
        /// @notice Whether the token is an OFT
        bool isOFT;
        /// @notice L1 token address used by bridgeERC20To on the OP canonical bridge
        address remoteToken;
        /// @notice Whether to use CCTP for bridging this token
        bool useCCTP;
    }

    /**
     * @notice Role identifier for accounts permitted to bridge tokens
     */
    bytes32 public constant SETTLEMENT_DISPATCHER_BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");

    /**
     * @notice Address of the OP Stack L2 Standard Bridge
     */
    address public constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;

    /**
     * @notice LayerZero Ethereum endpoint ID
     */
    uint32 public constant ETHEREUM_EID = 30_101;

    /**
     * @notice Dust threshold for LayerZero OFT decimal conversion (1e12)
     * @dev Amounts must be multiples of this value to avoid dust being locked
     */
    uint256 public constant DUST_THRESHOLD = 1e12;

    /**
     * @notice Bin Sponsor for the settlement dispatcher
     */
    BinSponsor public immutable binSponsor;

    /**
     * @notice Instance of the EtherFiDataProvider 
     */
    IEtherFiDataProvider public immutable dataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.SettlementDispatcherV2
    /**
     * @dev Storage struct for SettlementDispatcherV2 (follows ERC-7201 naming convention)
     */
    struct SettlementDispatcherV2Storage {
        /// @notice Mapping of token addresses to their destination chain information
        mapping(address token => DestinationData) destinationData;
        /// @notice Mapping of liquid token address to its withdraw queue
        mapping (address liquidToken => address boringQueue) liquidWithdrawQueue;
        /// @notice Configurable refund wallet address (falls back to data provider if not set)
        address refundWallet;
        /// @notice Frax USD token address for redeem-to-USDC
        address fraxUsd;
        /// @notice Frax USDC custodian address (used for sync redeem)
        address fraxCustodian;
        /// @notice Frax RemoteHop address (used for async redeem via LayerZero OFT)
        address fraxRemoteHop;
        /// @notice Recipient address on Ethereum for async Frax redemptions
        address fraxAsyncRedeemRecipient;
        /// @notice Mapping of Midas token to redemption vault (e.g. Liquid Reserve)
        mapping(address midasToken => address redemptionVault) midasRedemptionVault;
        /// @notice Per-token settlement recipient for same-chain transfers
        mapping(address token => address recipient) settlementRecipient;
        /// @notice CCTP TokenMessenger address
        address cctpTokenMessenger;
        /// @notice CCTP destination domain (e.g. 0 for Ethereum)
        uint32 cctpDestinationDomain;
        /// @notice CCTP max fee in burn token units (0 for standard transfer)
        uint256 cctpMaxFee;
        /// @notice CCTP minimum finality threshold
        uint32 cctpMinFinalityThreshold;
    }

    /**
     * @notice Storage location for SettlementDispatcherV2 (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.SettlementDispatcherV2")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant SettlementDispatcherV2StorageLocation = 0xf9bbc2c9d8f35ec9e02af943e054f7195eedb0f8bb965ae30b9402b4b7cf0100;

    /**
     * @notice Emitted when destination data is set for tokens
     * @param tokens Array of token addresses that were configured
     * @param destDatas Array of destination data corresponding to each token
     */
    event DestinationDataSet(address[] tokens, DestinationData[] destDatas);
    
    /**
     * @notice Emitted when funds are successfully bridged via Stargate
     * @param token Address of the token that was bridged
     * @param amount Amount of tokens that were bridged
     * @param ticket Stargate ticket containing details of the bridge transaction
     */
    event FundsBridgedWithStargate(address indexed token, uint256 amount, Ticket ticket);

    /**
     * @notice Emitted when funds are successfully bridged via OFT
     * @param token Address of the token that was bridged
     * @param amount Amount of tokens that were bridged
     */
    event FundsBridgedWithOFT(address indexed token, uint256 amount);
    
    /**
     * @notice Emitted when funds are withdrawn from the contract
     * @param token Address of the token that was withdrawn (address(0) for ETH)
     * @param amount Amount of tokens or ETH that was withdrawn
     * @param recipient Address that received the withdrawn funds
     */
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Emitted when liquid asset withdraw config is set
     * @param token Address of the liquid asset
     * @param boringQueue Address of the boring queue
     */
    event LiquidWithdrawQueueSet(address indexed token, address indexed boringQueue);
    
    /**
     * @notice Emitted when liquid asset withdrawal is requested
     * @param liquidToken Address of the liquid asset
     * @param assetOut Address of the asset out
     * @param amountToWithdraw Amount of liquid assets withdrawn
     * @param amountOut Amount of underlying tokens to receive
     */
    event LiquidWithdrawalRequested(address indexed liquidToken, address indexed assetOut, uint128 amountToWithdraw, uint128 amountOut);

    /**
     * @notice Emitted when funds are transferred to the refund wallet
     * @param asset Address of the asset transferred
     * @param refundWallet Address of the refund wallet
     * @param amount Amount of the asset transferred
     */
    event TransferToRefundWallet(address asset, address refundWallet, uint256 amount);

    /**
     * @notice Emitted when tokens are withdrawn to L1 via the canonical bridge
     * @param token Address of the token that was withdrawn
     * @param recipient Address of the recipient
     * @param amount Amount of the token that was withdrawn
     */
    event CanonicalBridgeWithdraw(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when the refund wallet is set
     * @param refundWallet Address of the refund wallet that was set
     */
    event RefundWalletSet(address indexed refundWallet);

    /**
     * @notice Emitted when Frax config is set
     * @param fraxUsd Frax USD token address
     * @param fraxCustodian Frax custodian address
     * @param fraxRemoteHop Frax RemoteHop address
     * @param fraxAsyncRedeemRecipient Recipient address on Ethereum for async redemptions
     */
    event FraxConfigSet(address indexed fraxUsd, address indexed fraxCustodian, address indexed fraxRemoteHop, address fraxAsyncRedeemRecipient);

    /**
     * @notice Emitted when Frax is redeemed to USDC (sync)
     * @param amount Amount of Frax USD redeemed
     * @param amountOut Amount of USDC received
     */
    event FraxRedeemed(uint256 amount, uint256 amountOut);

    /**
     * @notice Emitted when Frax USD is redeemed asynchronously via RemoteHop
     * @param amount Amount of Frax USD sent cross-chain
     * @param recipient Recipient address on Ethereum
     */
    event FraxAsyncRedeemed(uint256 amount, address indexed recipient);

    /**
     * @notice Emitted when Midas redemption vault is set for a token
     * @param midasToken Midas token address
     * @param redemptionVault Redemption vault address
     */
    event MidasRedemptionVaultSet(address indexed midasToken, address indexed redemptionVault);

    /**
     * @notice Emitted when Midas token is redeemed to asset
     * @param midasToken Midas token address
     * @param assetOut Asset received (e.g. USDC)
     * @param amount Amount of Midas token redeemed
     * @param minReceive Minimum amount of asset requested
     */
    event MidasRedeemed(address indexed midasToken, address indexed assetOut, uint256 amount, uint256 minReceive);

    /**
     * @notice Emitted when tokens are settled (transferred to the per-token recipient)
     */
    event FundsSettled(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a settlement recipient is configured for a token
     */
    event SettlementRecipientSet(address indexed token, address indexed recipient);

    /**
     * @notice Emitted when funds are bridged via CCTP
     */
    event FundsBridgedWithCCTP(address indexed token, uint256 amount, uint32 destinationDomain, address indexed recipient);

    /**
     * @notice Emitted when CCTP config is set
     */
    event CCTPConfigSet(address indexed tokenMessenger, uint32 destinationDomain, uint256 maxFee, uint32 minFinalityThreshold);

    /**
     * @notice Thrown when input arrays have different lengths
     */
    error ArrayLengthMismatch();
    
    /**
     * @notice Thrown when an invalid address or value is provided
     */
    error InvalidValue();
    
    /**
     * @notice Thrown when trying to bridge a token with no destination data set
     */
    error DestinationDataNotSet();
    
    /**
     * @notice Thrown when the provided Stargate router does not support the token
     */
    error StargateValueInvalid();
    
    /**
     * @notice Thrown when the contract has insufficient token balance for an operation
     */
    error InsufficientBalance();
    
    /**
     * @notice Thrown when a withdrawal of ETH fails
     */
    error WithdrawFundsFailed();
    
    /**
     * @notice Thrown when attempting to withdraw zero tokens or ETH
     */
    error CannotWithdrawZeroAmount();
    
    /**
     * @notice Thrown when the native fee for bridging is higher than the provided value
     */
    error InsufficientFeeToCoverCost();
    
    /**
     * @notice Thrown when the minimum return amount is not satisfied
     */
    error InsufficientMinReturn();

    /**
     * @notice Thrown when liquid withdraw config is not set for the liquid token
     */
    error LiquidWithdrawConfigNotSet();

    /**
     * @notice Thrown when the boring queue has a different boring vault than expected
     */
    error InvalidBoringQueue();

    /**
     * @notice Thrown when refund wallet is not set and trying to transfer to refund wallet
     */
    error RefundWalletNotSet();

    /**
     * @notice Thrown when the return amount is less than min return
     */
    error InsufficientReturnAmount();

    /**
     * @notice Thrown when Frax config (fraxUsd or fraxCustodian) is not set
     */
    error FraxConfigNotSet();

    /**
     * @notice Thrown when native fee is insufficient for LayerZero bridging
     */
    error InsufficientNativeFee();

    /**
     * @notice Thrown when amount contains dust (not a multiple of DUST_THRESHOLD)
     */
    error AmountContainsDust();

    /**
     * @notice Thrown when Midas redemption vault is not set for the token
     */
    error MidasRedemptionVaultNotSet();

    /**
     * @notice Thrown when no settlement recipient is configured for the token
     */
    error SettlementRecipientNotSet();

    /**
     * @notice Thrown when CCTP config is not set
     */
    error CCTPConfigNotSet();

    /**
     * @notice Constructor that disables initializers
     * @dev Cannot be called again after deployment (UUPS pattern)
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(BinSponsor _binSponsor, address _dataProvider) {
        _disableInitializers();
        binSponsor = _binSponsor;
        dataProvider = IEtherFiDataProvider(_dataProvider);
    }

    /**
     * @notice Initializes the contract with role registry and token destination data
     * @dev Can only be called once due to initializer modifier
     * @param _roleRegistry Address of the role registry contract
     * @param _tokens Array of token addresses to configure
     * @param _destDatas Array of destination data corresponding to each token
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidValue If any address parameter is zero
     * @custom:throws StargateValueInvalid If the Stargate router doesn't support the token
     */
    function initialize(address _roleRegistry, address[] calldata _tokens, DestinationData[] calldata _destDatas) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _setDestinationData(_tokens, _destDatas);
    }

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the SettlementDispatcherV2Storage struct
     */
    function _getSettlementDispatcherV2Storage() internal pure returns (SettlementDispatcherV2Storage storage $) {
        assembly {
            $.slot := SettlementDispatcherV2StorageLocation
        }
    }

    /**
     * @notice Function to fetch the destination data for a token
     * @param token Address of the token
     * @return Destination data struct for the specified token
     */
    function destinationData(address token) public view virtual returns (DestinationData memory) {
        return _getSettlementDispatcherV2Storage().destinationData[token];
    }

    /**
     * @notice Function to set the destination data for an array of tokens
     * @dev Only callable by the role registry owner
     * @param tokens Addresses of tokens to configure
     * @param destDatas Destination data structs for respective tokens
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidValue If any address parameter is zero
     * @custom:throws StargateValueInvalid If the Stargate router doesn't support the token
     */
    function setDestinationData(address[] calldata tokens, DestinationData[] calldata destDatas) external virtual onlyRoleRegistryOwner {
        _setDestinationData(tokens, destDatas);
    }

    /**
     * @notice Function to set the liquid asset withdraw queue 
     * @dev Only callable by the role registry owner
     * @param asset Address of the liquid asset
     * @param boringQueue Address of the boring queue
     * @custom:throws InvalidValue If any address parameter is zero
     * @custom:throws InvalidBoringQueue If the queue does not belong to the liquid asset
     */
    function setLiquidAssetWithdrawQueue(address asset, address boringQueue) external onlyRoleRegistryOwner {
        if (asset == address(0) || boringQueue == address(0)) revert InvalidValue();
        if (asset != address(IBoringOnChainQueue(boringQueue).boringVault())) revert InvalidBoringQueue();

        _getSettlementDispatcherV2Storage().liquidWithdrawQueue[asset] = boringQueue;

        emit LiquidWithdrawQueueSet(asset, boringQueue);
    }

    /**
     * @notice Returns the liquid asset withdraw queue
     * @param asset Address of the liquid asset
     * @return Boring Queue for liquid asset
     */
    function getLiquidAssetWithdrawQueue(address asset) external view returns (address) {
        return _getSettlementDispatcherV2Storage().liquidWithdrawQueue[asset];
    }

    /**
     * @notice Sets the configurable refund wallet address
     * @dev Only callable by the role registry owner
     * @param _refundWallet Address of the refund wallet to set (can be address(0) to clear and use data provider)
     */
    function setRefundWallet(address _refundWallet) external onlyRoleRegistryOwner {
        _getSettlementDispatcherV2Storage().refundWallet = _refundWallet;
        emit RefundWalletSet(_refundWallet);
    }

    /**
     * @notice Returns the refund wallet address
     * @dev Returns the configurable refund wallet if set, otherwise falls back to the data provider
     * @return Refund wallet address
     */
    function getRefundWallet() public view returns (address) {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        address configurableRefundWallet = $.refundWallet;
        if (configurableRefundWallet != address(0)) {
            return configurableRefundWallet;
        }
        return dataProvider.getRefundWallet();
    }

    /**
     * @notice Sets the Frax config for sync and async redeem
     * @dev Only callable by the role registry owner
     * @param _fraxUsd Address of the Frax USD token
     * @param _fraxCustodian Address of the Frax custodian (for sync redeem)
     * @param _fraxRemoteHop Address of the Frax RemoteHop contract (for async redeem via LayerZero OFT)
     * @param _fraxAsyncRedeemRecipient Recipient address on Ethereum for async Frax redemptions
     * @custom:throws InvalidValue If fraxUsd or fraxCustodian is zero
     */
    function setFraxConfig(address _fraxUsd, address _fraxCustodian, address _fraxRemoteHop, address _fraxAsyncRedeemRecipient) external onlyRoleRegistryOwner {
        if (_fraxUsd == address(0) || _fraxCustodian == address(0)) revert InvalidValue();
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        $.fraxUsd = _fraxUsd;
        $.fraxCustodian = _fraxCustodian;
        $.fraxRemoteHop = _fraxRemoteHop;
        $.fraxAsyncRedeemRecipient = _fraxAsyncRedeemRecipient;
        emit FraxConfigSet(_fraxUsd, _fraxCustodian, _fraxRemoteHop, _fraxAsyncRedeemRecipient);
    }

    /**
     * @notice Returns the Frax config (fraxUsd token, custodian, remoteHop, and async redeem recipient addresses)
     * @return fraxUsd_ Frax USD token address
     * @return fraxCustodian_ Frax custodian address
     * @return fraxRemoteHop_ Frax RemoteHop address
     * @return fraxAsyncRedeemRecipient_ Recipient address on Ethereum for async redemptions
     */
    function getFraxConfig() external view returns (address fraxUsd_, address fraxCustodian_, address fraxRemoteHop_, address fraxAsyncRedeemRecipient_) {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        return ($.fraxUsd, $.fraxCustodian, $.fraxRemoteHop, $.fraxAsyncRedeemRecipient);
    }

    /**
     * @notice Sets the Midas redemption vault for a Midas token (e.g. Liquid Reserve)
     * @dev Only callable by the role registry owner
     * @param midasToken Address of the Midas token
     * @param redemptionVault Address of the redemption vault
     * @custom:throws InvalidValue If any address is zero
     */
    function setMidasRedemptionVault(address midasToken, address redemptionVault) external onlyRoleRegistryOwner {
        if (midasToken == address(0) || redemptionVault == address(0)) revert InvalidValue();
        _getSettlementDispatcherV2Storage().midasRedemptionVault[midasToken] = redemptionVault;
        emit MidasRedemptionVaultSet(midasToken, redemptionVault);
    }

    /**
     * @notice Returns the Midas redemption vault for a token
     * @param midasToken Address of the Midas token
     * @return Redemption vault address
     */
    function getMidasRedemptionVault(address midasToken) external view returns (address) {
        return _getSettlementDispatcherV2Storage().midasRedemptionVault[midasToken];
    }

    /**
     * @notice Function to withdraw liquid tokens inside the Settlement Dispatcher
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE
     * @param liquidToken Address of the liquid token
     * @param assetOut Address of the underlying token to receive
     * @param amount Amount of liquid tokens to withdraw
     * @param minReturn Acceptable min return amount of asset out
     * @param discount Acceptable discount in bps
     * @param secondsToDeadline Expiry deadline in seconds from now
     */
    function withdrawLiquidAsset(address liquidToken, address assetOut, uint128 amount, uint128 minReturn, uint16 discount, uint24 secondsToDeadline) external onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        IBoringOnChainQueue boringQueue = IBoringOnChainQueue(_getSettlementDispatcherV2Storage().liquidWithdrawQueue[liquidToken]);
        if (address(boringQueue) == address(0)) revert LiquidWithdrawConfigNotSet();

        uint128 amountOutFromQueue = boringQueue.previewAssetsOut(assetOut, amount, discount);
        if (amountOutFromQueue < minReturn) revert InsufficientReturnAmount();

        IERC20(liquidToken).forceApprove(address(boringQueue), amount);
        boringQueue.requestOnChainWithdraw(assetOut, amount, discount, secondsToDeadline);

        emit LiquidWithdrawalRequested(liquidToken, assetOut, amount, amountOutFromQueue);
    }

    /**
     * @notice Redeems Frax USD held by the dispatcher into USDC via the Frax custodian
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE
     * @param amount Amount of Frax USD to redeem
     * @param minReceive Minimum amount of USDC to receive
     * @custom:throws FraxConfigNotSet If fraxUsd or fraxCustodian is not set
     * @custom:throws AmountContainsDust If amount is less than DUST_THRESHOLD
     * @custom:throws InsufficientBalance If dispatcher balance of Frax USD is less than amount
     * @custom:throws InsufficientReturnAmount If USDC received is less than minReceive
     */
    function redeemFraxToUsdc(uint256 amount, uint256 minReceive) external nonReentrant onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        address _fraxUsd = $.fraxUsd;
        address _fraxCustodian = $.fraxCustodian;
        if (_fraxUsd == address(0) || _fraxCustodian == address(0)) revert FraxConfigNotSet();
        if (amount < DUST_THRESHOLD) revert AmountContainsDust();
        if (IERC20(_fraxUsd).balanceOf(address(this)) < amount) revert InsufficientBalance();

        IERC20(_fraxUsd).forceApprove(_fraxCustodian, amount);
        uint256 amountOut = IFraxCustodian(_fraxCustodian).redeem(amount, address(this), address(this));
        if (amountOut < minReceive) revert InsufficientReturnAmount();

        emit FraxRedeemed(amount, amountOut);
    }

    /**
     * @notice Quotes the LayerZero bridging fee for an async Frax redemption
     * @param amount Amount of Frax USD to bridge
     * @return fee MessagingFee struct with native and lzToken fees
     * @custom:throws FraxConfigNotSet If fraxRemoteHop or fraxAsyncRedeemRecipient is not set
     */
    function quoteAsyncFraxRedeem(uint256 amount) external view returns (MessagingFee memory fee) {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        if ($.fraxRemoteHop == address(0) || $.fraxAsyncRedeemRecipient == address(0)) revert FraxConfigNotSet();
        bytes32 _to = bytes32(uint256(uint160($.fraxAsyncRedeemRecipient)));
        return IFraxRemoteHop($.fraxRemoteHop).quote($.fraxUsd, ETHEREUM_EID, _to, amount);
    }

    /**
     * @notice Redeems Frax USD asynchronously by bridging cross-chain to Ethereum via RemoteHop (LayerZero OFT)
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE. Requires ETH for LayerZero fees.
     * @param amount Amount of Frax USD to bridge (must be a multiple of DUST_THRESHOLD)
     * @custom:throws FraxConfigNotSet If fraxUsd, fraxRemoteHop, or fraxAsyncRedeemRecipient is not set
     * @custom:throws InvalidValue If amount is zero
     * @custom:throws AmountContainsDust If amount is not a multiple of DUST_THRESHOLD
     * @custom:throws InsufficientBalance If dispatcher balance of Frax USD is less than amount
     * @custom:throws InsufficientNativeFee If contract ETH balance is less than the LayerZero fee
     */
    function redeemFraxAsync(uint256 amount) external payable nonReentrant whenNotPaused onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        address _fraxUsd = $.fraxUsd;
        address _fraxRemoteHop = $.fraxRemoteHop;
        address _recipient = $.fraxAsyncRedeemRecipient;
        if (_fraxUsd == address(0) || _fraxRemoteHop == address(0) || _recipient == address(0)) revert FraxConfigNotSet();
        if (amount == 0) revert InvalidValue();
        if (amount % DUST_THRESHOLD != 0) revert AmountContainsDust();
        if (IERC20(_fraxUsd).balanceOf(address(this)) < amount) revert InsufficientBalance();

        bytes32 _to = bytes32(uint256(uint160(_recipient)));
        MessagingFee memory fee = IFraxRemoteHop(_fraxRemoteHop).quote(_fraxUsd, ETHEREUM_EID, _to, amount);
        if (address(this).balance < fee.nativeFee) revert InsufficientNativeFee();

        IERC20(_fraxUsd).forceApprove(_fraxRemoteHop, amount);
        IFraxRemoteHop(_fraxRemoteHop).sendOFT{ value: fee.nativeFee }(_fraxUsd, ETHEREUM_EID, _to, amount);

        emit FraxAsyncRedeemed(amount, _recipient);
    }

    /**
     * @notice Requests redemption of a Midas token (e.g. Liquid Reserve) held by the dispatcher into an asset (e.g. USDC) via the Midas redemption vault.
     * The vault will send the asset to this contract once the redemption is processed.
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE. Uses redeemRequest; funds are sent to this contract when the vault processes the request.
     * @param midasToken Address of the Midas token to redeem
     * @param assetOut Address of the asset to receive (e.g. USDC)
     * @param amount Amount of Midas token to redeem
     * @param minReceive Minimum amount of assetOut expected when the vault sends (for event/logging only; vault does not enforce at request time)
     * @custom:throws MidasRedemptionVaultNotSet If redemption vault is not set for midasToken
     * @custom:throws InvalidValue If amount is zero or any address is zero
     * @custom:throws InsufficientBalance If dispatcher balance of midasToken is less than amount
     */
    function redeemMidasToAsset(address midasToken, address assetOut, uint256 amount, uint256 minReceive) external nonReentrant onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        if (midasToken == address(0) || assetOut == address(0)) revert InvalidValue();

        address redemptionVault = _getSettlementDispatcherV2Storage().midasRedemptionVault[midasToken];
        if (redemptionVault == address(0)) revert MidasRedemptionVaultNotSet();
        if (IERC20(midasToken).balanceOf(address(this)) < amount) revert InsufficientBalance();

        IERC20(midasToken).forceApprove(redemptionVault, amount);
        IMidasVault(redemptionVault).redeemRequest(assetOut, amount, address(this));

        emit MidasRedeemed(midasToken, assetOut, amount, minReceive);
    }

    /**
     * @notice Transfers funds to the refund wallet
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE
     * @param asset Address of the token to transfer 
     * @param amount Amount of tokens to transfer
     * @custom:throws RefundWalletNotSet If the refund wallet address is not set
     * @custom:throws CannotWithdrawZeroAmount If attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed If ETH transfer fails
     */
    function transferFundsToRefundWallet(address asset, uint256 amount) external nonReentrant onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        address refundWallet = getRefundWallet();
        if (refundWallet == address(0)) revert RefundWalletNotSet();
        amount = _withdrawFunds(asset, refundWallet, amount);

        emit TransferToRefundWallet(asset, refundWallet, amount);
    }

    /**
     * @notice Function to bridge tokens to another chain
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE
     * @param token Address of the token to bridge
     * @param amount Amount of the token to bridge
     * @param minReturnLD Minimum amount to receive on the destination chain
     * @custom:throws InvalidValue If token is address(0) or amount is 0
     * @custom:throws InsufficientBalance If the contract doesn't have enough tokens
     * @custom:throws DestinationDataNotSet If destination data is not set for the token
     * @custom:throws InsufficientMinReturn If the expected return is less than minReturnLD
     * @custom:throws InsufficientFeeToCoverCost If not enough ETH is provided for fees
     */
    function bridge(address token, uint256 amount, uint256 minReturnLD) external payable virtual whenNotPaused onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        if (token == address(0) || amount == 0) revert InvalidValue();
        
        uint256 balance = 0;
        if (token == ETH) balance = address(this).balance;
        else balance = IERC20(token).balanceOf(address(this));
        
        if (balance < amount) revert InsufficientBalance();

        DestinationData memory destData = _getSettlementDispatcherV2Storage().destinationData[token];

        if (destData.destRecipient == address(0)) revert DestinationDataNotSet();
        
        if (destData.useCCTP) {
            _bridgeViaCCTP(token, destData.destRecipient, amount);
        } else if (destData.useCanonicalBridge) {
            _withdrawCanonicalBridge(token, destData.remoteToken, destData.destRecipient, amount, destData.minGasLimit);
        } else if (destData.isOFT) {
            (address oft, uint256 valueToSend, uint256 minReturnFromOft, SendParam memory sendParam, MessagingFee memory messagingFee) =
                prepareOftSend(token, amount);

            if (minReturnLD > minReturnFromOft) revert InsufficientMinReturn();
            if (address(this).balance < valueToSend) revert InsufficientFeeToCoverCost();

            if (IOFT(oft).approvalRequired()) IERC20(token).forceApprove(oft, amount);
            IOFT(oft).send{ value: valueToSend }(sendParam, messagingFee, payable(address(this)));
            emit FundsBridgedWithOFT(token, amount);
        } else {
            (address stargate, uint256 valueToSend, uint256 minReturnFromStargate, SendParam memory sendParam, MessagingFee memory messagingFee) =
                prepareRideBus(token, amount);

            if (minReturnLD > minReturnFromStargate) revert InsufficientMinReturn();
            if (address(this).balance < valueToSend) revert InsufficientFeeToCoverCost();

            if (token != ETH) IERC20(token).forceApprove(stargate, amount);
            (, , Ticket memory ticket) = IStargate(stargate).sendToken{ value: valueToSend }(sendParam, messagingFee, payable(address(this)));
            emit FundsBridgedWithStargate(token, amount, ticket);
        }
    }

    /**
     * @notice Prepares parameters for the Stargate bridge transaction
     * @dev Uses Stargate's "Ride the Bus" pattern for token bridging
     * @param token Address of the token to bridge
     * @param amount Amount of the token to bridge
     * @return stargate Address of the Stargate router to use
     * @return valueToSend Amount of ETH needed for the transaction
     * @return minReturnFromStargate Minimum amount expected to be received on destination
     * @return sendParam Stargate SendParam struct with bridging details
     * @return messagingFee Stargate MessagingFee struct with fee details
     * @custom:throws InvalidValue If token is address(0) or amount is 0
     * @custom:throws InsufficientBalance If the contract doesn't have enough tokens
     * @custom:throws DestinationDataNotSet If destination data is not set for the token
     */
    function prepareRideBus(
        address token,
        uint256 amount
    ) public view virtual returns (address stargate, uint256 valueToSend, uint256 minReturnFromStargate, SendParam memory sendParam, MessagingFee memory messagingFee) {

        DestinationData memory destData = _getSettlementDispatcherV2Storage().destinationData[token];
        if (destData.destRecipient == address(0)) revert DestinationDataNotSet();

        stargate = destData.stargate;
        sendParam = SendParam({
            dstEid: destData.destEid,
            to: bytes32(uint256(uint160(destData.destRecipient))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: new bytes(1)
        });

        (, , OFTReceipt memory receipt) = IStargate(stargate).quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;
        minReturnFromStargate = receipt.amountReceivedLD;

        messagingFee = IStargate(stargate).quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;

        if (IStargate(stargate).token() == address(0x0)) {
            valueToSend += sendParam.amountLD;
        }
    }

    /**
     * @notice Prepares parameters for bridging via OFT
     * @param token Address of the token to bridge
     * @param amount Amount of the token to bridge
     * @return oft Address of the OFT contract
     * @return valueToSend Amount of ETH needed for the transaction
     * @return minReturnFromOft Minimum amount expected to be received on destination
     * @return sendParam OFT SendParam struct with bridging details
     * @return messagingFee MessagingFee struct with fee details
     * @custom:throws DestinationDataNotSet If destination data is not set for the token
     * @custom:throws InsufficientMinReturn If the quoted return is less than expected
     */
    function prepareOftSend(
        address token,
        uint256 amount
    ) public view virtual returns (address oft, uint256 valueToSend, uint256 minReturnFromOft, SendParam memory sendParam, MessagingFee memory messagingFee) {
        DestinationData memory destData = _getSettlementDispatcherV2Storage().destinationData[token];
        if (destData.destRecipient == address(0)) revert DestinationDataNotSet();

        oft = destData.stargate;
        sendParam = SendParam({
            dstEid: destData.destEid,
            to: bytes32(uint256(uint160(destData.destRecipient))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: hex"0003",
            composeMsg: new bytes(0),
            oftCmd: new bytes(0)
        });

        (, , OFTReceipt memory receipt) = IOFT(oft).quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;
        minReturnFromOft = receipt.amountReceivedLD;

        messagingFee = IOFT(oft).quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;
    }

    /**
     * @notice Withdraws tokens or ETH from the contract
     * @dev Only callable by the role registry owner
     * @param token Address of the token to withdraw (address(0) for ETH)
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount to withdraw (0 to withdraw all)
     * @custom:throws InvalidValue If recipient is address(0)
     * @custom:throws CannotWithdrawZeroAmount If attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed If ETH transfer fails
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external nonReentrant onlyRoleRegistryOwner() {
        if (recipient == address(0)) revert InvalidValue();
        amount = _withdrawFunds(token, recipient, amount);
        emit FundsWithdrawn(token, amount, recipient);
    }

    /**
     * @notice Withdraw tokens to L1 via the OP Stack canonical bridge
     * @dev Uses bridgeERC20To for ERC20s and bridgeETHTo for ETH
     * @param token Address of the token to withdraw
     * @param remoteToken Address of the corresponding L1 token (ignored for ETH)
     * @param recipient Address to receive the funds on L1
     * @param amount Amount to withdraw
     * @param minGasLimit Minimum gas limit for the withdrawal
     */
    function _withdrawCanonicalBridge(address token, address remoteToken, address recipient, uint256 amount, uint64 minGasLimit) internal returns (uint256) {
        if (token == ETH) {
            IL2StandardBridge(L2_STANDARD_BRIDGE).bridgeETHTo{ value: amount }(recipient, uint32(minGasLimit), "");
        } else {
            IERC20(token).forceApprove(L2_STANDARD_BRIDGE, amount);
            IL2StandardBridge(L2_STANDARD_BRIDGE).bridgeERC20To(token, remoteToken, recipient, amount, uint32(minGasLimit), "");
            IERC20(token).forceApprove(L2_STANDARD_BRIDGE, 0);
        }

        emit CanonicalBridgeWithdraw(token, recipient, amount);
        return amount;
    }
    
    /**
     * @notice Internal function to handle withdrawal of tokens or ETH
     * @dev Used by both withdrawFunds and transferFundsToRefundWallet
     * @param token Address of the token to withdraw 
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount to withdraw (0 to withdraw all available balance)
     * @custom:throws CannotWithdrawZeroAmount If attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed If ETH transfer fails
     */    
    function _withdrawFunds(address token, address recipient, uint256 amount) internal returns (uint256) {
        if (token == ETH) {
            if (amount == 0) amount = address(this).balance;
            if (amount == 0) revert CannotWithdrawZeroAmount();
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert  WithdrawFundsFailed();
        } else {
            if (amount == 0) amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert CannotWithdrawZeroAmount();
            IERC20(token).safeTransfer(recipient, amount);
        }

        return amount;
    }

    /**
     * @notice Internal function to set destination data for tokens
     * @dev Validates and stores destination data for each token
     * @param tokens Array of token addresses to configure
     * @param destDatas Array of destination data corresponding to each token
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidValue If any address parameter is zero
     * @custom:throws StargateValueInvalid If the Stargate router doesn't support the token
     */
    function _setDestinationData(address[] calldata tokens, DestinationData[] calldata destDatas) internal {
        uint256 len = tokens.length;
        if (len != destDatas.length) revert ArrayLengthMismatch(); 

        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();

        for (uint256 i = 0; i < len; ) {
            if (tokens[i] == address(0) || destDatas[i].destRecipient == address(0)) revert InvalidValue();

            if (destDatas[i].useCCTP) {
                // CCTP: only needs token + recipient; stargate/canonical fields must be unset
                if (destDatas[i].stargate != address(0) || destDatas[i].useCanonicalBridge) revert InvalidValue();
            } else if (destDatas[i].useCanonicalBridge) {
                if (destDatas[i].stargate != address(0) || destDatas[i].destEid != 0) revert InvalidValue();
                // ERC20 canonical bridge requires a remoteToken (L1 address); ETH does not
                if (tokens[i] != ETH && destDatas[i].remoteToken == address(0)) revert InvalidValue();
            } else {
                if (destDatas[i].stargate == address(0)) revert InvalidValue();

                if (tokens[i] == ETH) {
                    if (IStargate(destDatas[i].stargate).token() != address(0)) revert StargateValueInvalid();
                }
                else if (IStargate(destDatas[i].stargate).token() != tokens[i]) revert StargateValueInvalid();
            }

            $.destinationData[tokens[i]] = destDatas[i];
            unchecked {
                ++i;
            }
        }

        emit DestinationDataSet(tokens, destDatas);
    }

    // ═══════════════════════════════════════════════════════════════
    //              CCTP BRIDGING
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Sets CCTP configuration for cross-chain USDC bridging
     * @dev Only callable by the role registry owner
     * @param _tokenMessenger Address of the CCTP TokenMessenger contract
     * @param _destinationDomain CCTP destination domain (e.g. 0 for Ethereum)
     * @param _maxFee Maximum fee in burn token units (0 for standard transfer)
     * @param _minFinalityThreshold Minimum finality threshold for attestation
     */
    function setCCTPConfig(address _tokenMessenger, uint32 _destinationDomain, uint256 _maxFee, uint32 _minFinalityThreshold) external onlyRoleRegistryOwner {
        if (_tokenMessenger == address(0)) revert InvalidValue();
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        $.cctpTokenMessenger = _tokenMessenger;
        $.cctpDestinationDomain = _destinationDomain;
        $.cctpMaxFee = _maxFee;
        $.cctpMinFinalityThreshold = _minFinalityThreshold;
        emit CCTPConfigSet(_tokenMessenger, _destinationDomain, _maxFee, _minFinalityThreshold);
    }

    /**
     * @notice Returns the CCTP configuration
     */
    function getCCTPConfig() external view returns (address tokenMessenger_, uint32 destinationDomain_, uint256 maxFee_, uint32 minFinalityThreshold_) {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        return ($.cctpTokenMessenger, $.cctpDestinationDomain, $.cctpMaxFee, $.cctpMinFinalityThreshold);
    }

    /**
     * @notice Bridges tokens via CCTP (Circle Cross-Chain Transfer Protocol)
     * @dev Called internally by bridge() when destData.useCCTP is true
     */
    function _bridgeViaCCTP(address token, address recipient, uint256 amount) internal {
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        address tokenMessenger = $.cctpTokenMessenger;
        if (tokenMessenger == address(0)) revert CCTPConfigNotSet();

        IERC20(token).forceApprove(tokenMessenger, amount);
        ICCTPTokenMessenger(tokenMessenger).depositForBurn(
            amount,
            $.cctpDestinationDomain,
            bytes32(uint256(uint160(recipient))),
            token,
            bytes32(0),
            $.cctpMaxFee,
            $.cctpMinFinalityThreshold
        );

        emit FundsBridgedWithCCTP(token, amount, $.cctpDestinationDomain, recipient);
    }

    // ═══════════════════════════════════════════════════════════════
    //              SAME-CHAIN SETTLEMENT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Sets settlement recipients for multiple tokens at once
     * @dev Only callable by the role registry owner. Each token can have a different recipient.
     * @param tokens Array of token addresses to configure
     * @param recipients Array of recipient addresses corresponding to each token
     */
    function setSettlementRecipients(address[] calldata tokens, address[] calldata recipients) external onlyRoleRegistryOwner {
        if (tokens.length != recipients.length) revert ArrayLengthMismatch();
        SettlementDispatcherV2Storage storage $ = _getSettlementDispatcherV2Storage();
        for (uint256 i = 0; i < tokens.length;) {
            if (tokens[i] == address(0) || recipients[i] == address(0)) revert InvalidValue();
            $.settlementRecipient[tokens[i]] = recipients[i];
            emit SettlementRecipientSet(tokens[i], recipients[i]);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Returns the settlement recipient configured for a specific token
     * @param token Address of the token to query
     * @return The recipient address for the specified token
     */
    function getSettlementRecipient(address token) external view returns (address) {
        return _getSettlementDispatcherV2Storage().settlementRecipient[token];
    }

    /**
     * @notice Settles funds by transferring tokens directly to the per-token settlement recipient
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE when not paused.
     *      Intended for same-chain settlement (e.g. USDC/USDT on Optimism).
     * @param token Address of the token to settle
     * @param amount Amount of tokens to transfer to the recipient
     */
    function settle(address token, uint256 amount) external nonReentrant whenNotPaused onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        if (token == address(0) || amount == 0) revert InvalidValue();

        address recipient = _getSettlementDispatcherV2Storage().settlementRecipient[token];
        if (recipient == address(0)) revert SettlementRecipientNotSet();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();

        IERC20(token).safeTransfer(recipient, amount);
        emit FundsSettled(token, recipient, amount);
    }

    /**
     * @notice Fallback function to receive ETH
     * @dev Required to receive fee refunds from Stargate
     */
    receive() external payable {}
}

