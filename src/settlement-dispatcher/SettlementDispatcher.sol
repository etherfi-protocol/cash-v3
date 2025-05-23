// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IStargate, Ticket } from "../interfaces/IStargate.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IBoringOnChainQueue } from "../interfaces/IBoringOnChainQueue.sol";
import { BinSponsor } from "../interfaces/ICashModule.sol";
import { MessagingFee, OFTReceipt, SendParam } from "../interfaces/IOFT.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title SettlementDispatcher
 * @author shivam@ether.fi
 * @notice This contract receives payments from user safes and bridges it to another chain to pay the fiat provider
 */
contract SettlementDispatcher is UpgradeableProxy {
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
    }

    /**
     * @notice Struct containing liquid withdrawal configuration
     * @dev Stores all data needed to withdraw liquid tokens
     */
    struct LiquidWithdrawConfig {
        /// @notice boringQueue Address of the boring queue
        address boringQueue;
        /// @notice discount The discount to apply to the withdraw in bps
        uint16 discount;
        /// @notice secondsToDeadline The time in seconds the request is valid for
        uint24 secondsToDeadline;
    }

    /**
     * @notice Role identifier for accounts permitted to bridge tokens
     */
    bytes32 public constant SETTLEMENT_DISPATCHER_BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");

    /**
     * @notice Bin Sponsor for the settlement dispatcher
     */
    BinSponsor public immutable binSponsor;

    /**
     * @notice Instance of the EtherFiDataProvider 
     */
    IEtherFiDataProvider public immutable dataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.SettlementDispatcher
    /**
     * @dev Storage struct for SettlementDispatcher (follows ERC-7201 naming convention)
     */
    struct SettlementDispatcherStorage {
        /// @notice Mapping of token addresses to their destination chain information
        mapping(address token => DestinationData) destinationData;
        /// @notice Mapping of liquid token address to its withdraw config
        mapping (address liquidToken => LiquidWithdrawConfig) liquidWithdrawConfig;
    }

    /**
     * @notice Storage location for SettlementDispatcher (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.SettlementDispatcher")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant SettlementDispatcherStorageLocation = 0x78555946a409defb00fb08ff23c8988ad687a02e1525a4fc9b7fd83443409e00;

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
     * @param discount Discount percentage with 5 decimals precision
     * @param secondsToDeadline The time in seconds the request is valid for
     */
    event LiquidWithdrawConfigSet(address indexed token, address boringQueue, uint16 discount, uint24 secondsToDeadline);
    
    /**
     * @notice Emitted when liquid asset withdrawal is requested
     * @param liquidToken Address of the liquid asset
     * @param assetOut Address of the asset out
     * @param amount Amount of liquid assets withdrawn
     */
    event LiquidWithdrawalRequested(address indexed liquidToken, address indexed assetOut, uint128 amount);

    /**
     * @notice Emitted when funds are transferred to the refund wallet
     * @param asset Address of the asset transferred
     * @param refundWallet Address of the refund wallet
     * @param amount Amount of the asset transferred
     */
    event TransferToRefundWallet(address asset, address refundWallet, uint256 amount);

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
     * @return $ Storage pointer to the SettlementDispatcherStorage struct
     */
    function _getSettlementDispatcherStorage() internal pure returns (SettlementDispatcherStorage storage $) {
        assembly {
            $.slot := SettlementDispatcherStorageLocation
        }
    }

    /**
     * @notice Function to fetch the destination data for a token
     * @param token Address of the token
     * @return Destination data struct for the specified token
     */
    function destinationData(address token) public view returns (DestinationData memory) {
        return _getSettlementDispatcherStorage().destinationData[token];
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
    function setDestinationData(address[] calldata tokens, DestinationData[] calldata destDatas) external onlyRoleRegistryOwner {
        _setDestinationData(tokens, destDatas);
    }

    /**
     * @notice Function to set the liquid asset withdraw config 
     * @dev Only callable by the role registry owner
     * @param asset Address of the liquid asset
     * @param boringQueue Address of the boring queue
     * @param discount Discount with 5 decimals (1% = 100000)
     * @param secondsToDeadline Seconds to deadline after which the withdraw request would expire
     * @custom:throws InvalidValue If any address parameter is zero
     * @custom:throws BoringQueueDoesNotAllowAssetOut If the boring queue does not allow the asset out 
     * @custom:throws InvalidDiscount If the discount is out of min and max bounds
     * @custom:throws SecondsToDeadlingLowerThanMin If the seconds to deadline is lesser than the min seconds to deadline 
     */
    function setLiquidAssetWithdrawConfig(address asset, address boringQueue, uint16 discount, uint24 secondsToDeadline) external onlyRoleRegistryOwner {
        if (asset == address(0) || boringQueue == address(0)) revert InvalidValue();
        if (asset != address(IBoringOnChainQueue(boringQueue).boringVault())) revert InvalidBoringQueue();

        SettlementDispatcherStorage storage $ = _getSettlementDispatcherStorage();

        $.liquidWithdrawConfig[asset] = LiquidWithdrawConfig({
            boringQueue: boringQueue,
            discount: discount,
            secondsToDeadline: secondsToDeadline
        });

        emit LiquidWithdrawConfigSet(asset, boringQueue, discount, secondsToDeadline);
    }

    /**
     * @notice Returns the liquid asset withdraw config
     * @param asset Address of the liquid asset
     * @return LiquidWithdrawConfig struct (assetOut, boringQueue, discount, secondsToDeadline)
     */
    function getLiquidAssetWithdrawConfig(address asset) external view returns (LiquidWithdrawConfig memory) {
        return _getSettlementDispatcherStorage().liquidWithdrawConfig[asset];
    } 

    /**
     * @notice Returns the refund wallet address set in the data provider contract
     * @return Refund wallet address
     */
    function getRefundWallet() public view returns (address) {
        return dataProvider.getRefundWallet();
    }

    /**
     * @notice Function to withdraw liquid tokens inside the Settlement Dispatcher
     * @dev Only callable by addresses with SETTLEMENT_DISPATCHER_BRIDGER_ROLE
     * @param liquidToken Address of the liquid token
     * @param assetOut Address of the underlying token to receive
     * @param amount Amount of liquid tokens to withdraw
     */
    function withdrawLiquidAsset(address liquidToken, address assetOut, uint128 amount) external onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {
        LiquidWithdrawConfig storage $ = _getSettlementDispatcherStorage().liquidWithdrawConfig[liquidToken];

        if ($.boringQueue == address(0)) revert LiquidWithdrawConfigNotSet();

        IERC20(liquidToken).forceApprove($.boringQueue, amount);
        IBoringOnChainQueue($.boringQueue).requestOnChainWithdraw(assetOut, amount, $.discount, $.secondsToDeadline);

        emit LiquidWithdrawalRequested(liquidToken, assetOut, amount);
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
    function bridge(address token, uint256 amount, uint256 minReturnLD) external payable whenNotPaused onlyRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE) {        
        (address stargate, uint256 valueToSend, uint256 minReturnFromStargate, SendParam memory sendParam, MessagingFee memory messagingFee) = 
            prepareRideBus(token, amount);

        if (minReturnLD > minReturnFromStargate) revert InsufficientMinReturn();
        if (address(this).balance < valueToSend) revert InsufficientFeeToCoverCost();

        IERC20(token).forceApprove(stargate, amount);
        (, , Ticket memory ticket) = IStargate(stargate).sendToken{ value: valueToSend }(sendParam, messagingFee, payable(address(this)));
        emit FundsBridgedWithStargate(token, amount, ticket);
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
    ) public view returns (address stargate, uint256 valueToSend, uint256 minReturnFromStargate, SendParam memory sendParam, MessagingFee memory messagingFee) {
        if (token == address(0) || amount == 0) revert InvalidValue();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();

        DestinationData memory destData = _getSettlementDispatcherStorage().destinationData[token];
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
     * @notice Internal function to handle withdrawal of tokens or ETH
     * @dev Used by both withdrawFunds and transferFundsToRefundWallet
     * @param token Address of the token to withdraw (address(0) for ETH)
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount to withdraw (0 to withdraw all available balance)
     * @custom:throws CannotWithdrawZeroAmount If attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed If ETH transfer fails
     */    
    function _withdrawFunds(address token, address recipient, uint256 amount) internal returns (uint256) {
        if (token == address(0)) {
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

        SettlementDispatcherStorage storage $ = _getSettlementDispatcherStorage();

        for (uint256 i = 0; i < len; ) {
            if (tokens[i] == address(0) || destDatas[i].destRecipient == address(0) || destDatas[i].stargate == address(0)) revert InvalidValue(); 
            if (IStargate(destDatas[i].stargate).token() != tokens[i]) revert StargateValueInvalid();

            $.destinationData[tokens[i]] = destDatas[i];
            unchecked {
                ++i;
            }
        }

        emit DestinationDataSet(tokens, destDatas);
    }

    /**
     * @notice Fallback function to receive ETH
     * @dev Required to receive fee refunds from Stargate
     */
    receive() external payable {}
}