// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { IOFT, MessagingFee, MessagingReceipt, OFTFeeDetail, OFTLimit, OFTReceipt, SendParam, SendParam } from "../../interfaces/IOFT.sol";
import { IStargate, Ticket } from "../../interfaces/IStargate.sol";
import { WithdrawalRequest, SafeData } from "../../interfaces/ICashModule.sol";
import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";

/**
 * @title StargateModule
 * @author EtherFi
 * @notice Module for interacting with Stargate Protocol to bridge assets across chains
 * @dev Extends ModuleBase to inherit common functionality
 * @custom:security-contact security@etherfi.io
 */
contract StargateModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
    using MessageHashUtils for bytes32;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /**
     * @dev Configuration parameters for supported assets and their bridge settings
     * @param isOFT Whether the asset is an OFT (Omnichain Fungible Token)
     * @param pool Stargate pool address for non-OFTs, OFT address for OFTs
     */
    struct AssetConfig {
        bool isOFT;
        address pool;
    }

    struct CrossChainWithdrawal {
        uint32 destEid;
        address asset;
        uint256 amount;
        address destRecipient;
        uint256 maxSlippageInBps;
    }

    /**
     * @dev Storage structure for StargateModule using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.StargateModule
     */
    struct StargateModuleStorage {
        /// @notice Asset config for supported tokens
        mapping(address token => AssetConfig assetConfig) assetConfig;
        /// @notice Mapping of withdrawal requested by safes
        mapping(address safe => CrossChainWithdrawal withdrawal) withdrawals;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StargateModule")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Storage location for the module's storage
    bytes32 private constant StargateModuleStorageLocation = 0xeafa2356b7fab3fae77872025a25cb67884d7667f22b14ae60e3f63732a39c00;

    /// @notice The ADMIN role for the Stargate module
    bytes32 public constant STARGATE_MODULE_ADMIN_ROLE = keccak256("STARGATE_MODULE_ADMIN_ROLE");

    /// @notice TypeHash for request bridge function signature 
    bytes32 public constant REQUEST_BRIDGE_SIG = keccak256("requestBridge");
    /// @notice Typehash for cancel bridge function signature
    bytes32 public constant CANCEL_BRIDGE_SIG = keccak256("cancelBridge");

    /// @notice 100% in basis points (10,000)
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;
    
    /// @notice Error for Invalid Owner quorum signatures
    error InvalidSignatures();

    /// @notice Error for Insufficient amount of asset in the safe
    error InsufficientAmount();
    
    /// @notice Error when the min amount is insufficient based on the max slippage
    error InsufficientMinAmount();

    /// @notice Error when native fee is insufficient
    error InsufficientNativeFee();

    /// @notice Error thrown when the provided Stargate pool doesn't match the token
    error InvalidStargatePool();

    /// @notice Error when native transfer fails
    error NativeTransferFailed();

    /// @notice Error thrown when caller is not authorized
    error Unauthorized();

    /// @notice Error thrown when no withdrawal is queued for Stargate
    error NoWithdrawalQueuedForStargate();

    /// @notice Error thrown when no matching withdrawal is found for the safe
    error CannotFindMatchingWithdrawalForSafe();

    /**
     * @notice Emitted when asset configurations are set
     * @param assets Array of asset addresses that were configured
     * @param assetConfigs Array of corresponding asset configurations
     */
    event AssetConfigSet(address[] assets, AssetConfig[] assetConfigs);

    /**
     * @notice Emitted when a bridge with Stargate is executed
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in LayerZero format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param maxSlippageInBps Maximum slippage allowed in basis points
     */
    event BridgeWithStargate(address indexed safe, uint32 indexed destEid, address indexed asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps);

    /**
     * @notice Emitted when a request to bridge assets is made
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in LayerZero format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param maxSlippageInBps Maximum slippage allowed in basis points
     */
    event RequestBridgeWithStargate(address indexed safe, uint32 indexed destEid, address indexed asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps);

    /**
     * @notice Emitted when a bridge request is cancelled
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in LayerZero format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     */
    event BridgeCancelled(address indexed safe, uint32 indexed destEid, address indexed asset, uint256 amount, address destRecipient);

    /**
     * @notice Constructor for StargateModule
     * @param _assets Array of asset addresses to configure
     * @param _assetConfigs Array of corresponding asset configurations
     * @param _etherFiDataProvider Address of the EtherFi data provider
     */
    constructor(address[] memory _assets, AssetConfig[] memory _assetConfigs, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _setAssetConfigs(_assets, _assetConfigs);
    }

    /**
     * @dev Returns the storage struct for StargateModule
     * @return $ Reference to the StargateModuleStorage struct
     */
    function _getStargateModuleStorage() internal pure returns (StargateModuleStorage storage $) {
        assembly {
            $.slot := StargateModuleStorageLocation
        }
    }

    /**
     * @notice Gets the configuration for a specific asset
     * @param asset Address of the asset
     * @return AssetConfig configuration for the asset
     */
    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _getStargateModuleStorage().assetConfig[asset];
    }

    /**
     * @notice Sets configuration for multiple assets
     * @dev Only callable by addresses with STARGATE_MODULE_ADMIN_ROLE
     * @param assets Array of asset addresses to configure
     * @param assetConfigs Array of corresponding asset configurations
     * @custom:throws Unauthorized if caller doesn't have admin role
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws InvalidInput if any asset address is zero
     * @custom:throws InvalidStargatePool if pool doesn't match the token
     */
    function setAssetConfig(address[] memory assets, AssetConfig[] memory assetConfigs) external {
        IRoleRegistry roleRegistry = IRoleRegistry(etherFiDataProvider.roleRegistry());
        if (!roleRegistry.hasRole(STARGATE_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();

        _setAssetConfigs(assets, assetConfigs);
    }

    /**
     * @notice Gets the pending bridge request for a safe
     * @param safe Address of the EtherFiSafe
     * @return CrossChainWithdrawal containing the pending bridge request details
     */
    function getPendingBridge(address safe) external view returns (CrossChainWithdrawal memory) {
        return _getStargateModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Requests a bridge operation for a safe
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in LayerZero format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param maxSlippageInBps Maximum slippage allowed in basis points (10,000 = 100%)
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of signatures from the signers
     * @custom:throws InvalidSignatures if the signatures are invalid
     * @custom:throws InvalidInput if destination, asset, amount or slippage is invalid
     */
    function requestBridge(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps, address[] calldata signers, bytes[] calldata signatures) external payable nonReentrant onlyEtherFiSafe(safe) {
        if (destRecipient == address(0) || asset == address(0) || amount == 0 || maxSlippageInBps > 10_000) revert InvalidInput();

        _checkSignature(safe, destEid, asset, amount, destRecipient, maxSlippageInBps, signers, signatures);
        
        cashModule.requestWithdrawalByModule(safe, asset, amount);

        emit RequestBridgeWithStargate(safe, destEid, asset, amount, destRecipient, maxSlippageInBps);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        if (withdrawalDelay == 0) {
            _bridge(destEid, asset, amount, destRecipient, maxSlippageInBps);
            emit BridgeWithStargate(safe, destEid, asset, amount, destRecipient, maxSlippageInBps);
        } else {
            _getStargateModuleStorage().withdrawals[safe] = CrossChainWithdrawal({
                destEid: destEid,
                asset: asset,
                amount: amount,
                destRecipient: destRecipient,
                maxSlippageInBps: maxSlippageInBps
            });
        }
    }

    /**
     * @notice Executes the bridge operation for a safe
     * @param safe Address of the EtherFiSafe
     */
    function executeBridge(address safe) public payable nonReentrant onlyEtherFiSafe(safe) {
        CrossChainWithdrawal memory withdrawal = _getStargateModuleStorage().withdrawals[safe];

        if (withdrawal.destRecipient == address(0)) revert NoWithdrawalQueuedForStargate();
        
        WithdrawalRequest memory withdrawalRequest = cashModule.getData(safe).pendingWithdrawalRequest;
        
        if (withdrawalRequest.recipient != address(this) || withdrawalRequest.tokens.length != 1 || withdrawalRequest.tokens[0] != withdrawal.asset || withdrawalRequest.amounts[0] != withdrawal.amount) revert CannotFindMatchingWithdrawalForSafe();

        cashModule.processWithdrawal(safe);

        _bridge(withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient, withdrawal.maxSlippageInBps);
        emit BridgeWithStargate(safe, withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient, withdrawal.maxSlippageInBps);

        delete _getStargateModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Cancels a bridge request for a safe
     * @param safe Address of the EtherFiSafe
     * @param signers Array of addresses of safe owners that signed the transaction
     * @param signatures Array of signatures from the signers
     */
    function cancelBridge(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        bytes32 digestHash = keccak256(abi.encodePacked(CANCEL_BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        CrossChainWithdrawal storage withdrawal = _getStargateModuleStorage().withdrawals[safe];
        if (withdrawal.destRecipient == address(0)) revert NoWithdrawalQueuedForStargate();

        SafeData memory data = cashModule.getData(safe);

        if (data.pendingWithdrawalRequest.recipient == address(this)) cashModule.cancelWithdrawalByModule(safe);

        if (withdrawal.asset != address(0)) {
            emit BridgeCancelled(safe, withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient);
            delete _getStargateModuleStorage().withdrawals[safe];
        }
    }

    /**
     * @notice Cancels a bridge request by the cash module
     * @dev This function is intended to be called by the cash module to cancel a bridge
     * @param safe Address of the EtherFiSafe
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        CrossChainWithdrawal storage withdrawal = _getStargateModuleStorage().withdrawals[safe];
        // Return if no withdrawal found for Stargate
        if (withdrawal.destRecipient == address(0)) return; 

        emit BridgeCancelled(safe, withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient);
        delete _getStargateModuleStorage().withdrawals[safe];
    }

    /**
     * @dev Verifies that the transaction has been properly signed by the required signers
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param maxSlippageInBps Maximum slippage allowed in basis points
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of signatures from the signers
     * @custom:throws InvalidSignatures if the signatures are invalid
     */
    function _checkSignature(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(REQUEST_BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, abi.encode(destEid, asset, amount, destRecipient, maxSlippageInBps))).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @dev Handles the bridging of assets, dispatching to the appropriate bridging method
     * @custom:throws InvalidInput if destination, asset, or amount is invalid
     * @custom:throws InsufficientAmount if the safe doesn't have enough assets
     */
    function _bridge(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps) internal {
        _checkBalance(asset, amount);

        uint256 minAmount = _deductSlippage(amount, maxSlippageInBps);

        if (_getStargateModuleStorage().assetConfig[asset].isOFT) _bridgeOft(destEid, asset, amount, destRecipient, minAmount);
        else _bridgeNonOft(destEid, asset, amount, destRecipient, minAmount);
    }

    /**
     * @dev Bridges non-OFT tokens through Stargate Protocol
     * @param destEid Destination chain ID
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param minReturnAmount Minimum amount to receive after slippage
     * @custom:throws InsufficientNativeFee if not enough native tokens for fees
     * @custom:throws NativeTransferFailed if native token transfer fails
     * @custom:throws InvalidStargatePool if pool configuration is invalid
     */
    function _bridgeNonOft(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 minReturnAmount) internal {
        (IStargate stargate, uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee, address poolToken) = prepareRideBus(destEid, asset, amount, destRecipient, minReturnAmount);
        if (address(this).balance < messagingFee.nativeFee) revert InsufficientNativeFee();

        if (asset != ETH) {
            if (poolToken != asset) revert InvalidStargatePool();

            IERC20(asset).forceApprove(address(stargate), amount);
            IStargate(stargate).sendToken{value: valueToSend}(sendParam, messagingFee, payable(address(this)));
        } else {
            if (poolToken != address(0)) revert InvalidStargatePool();
            IStargate(address(stargate)).sendToken{value: valueToSend}(sendParam, messagingFee, payable(address(this)));
        }
    }

    /**
     * @dev Bridges OFT tokens through the OFT contract
     * @param destEid Destination chain ID
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param minReturnAmount Minimum amount to receive after slippage
     * @custom:throws InsufficientMinAmount if expected received amount is below minimum
     * @custom:throws InsufficientNativeFee if not enough native tokens for fees
     * @custom:throws NativeTransferFailed if native token transfer fails
     */
    function _bridgeOft(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 minReturnAmount) internal {
        IOFT oft = IOFT(_getStargateModuleStorage().assetConfig[asset].pool);
        SendParam memory sendParam = SendParam({ dstEid: destEid, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: minReturnAmount, extraOptions: hex"0003", composeMsg: new bytes(0), oftCmd: new bytes(0) });

        ( , , OFTReceipt memory oftReceipt) = oft.quoteOFT(sendParam);
        sendParam.minAmountLD = oftReceipt.amountReceivedLD;
        if (minReturnAmount > oftReceipt.amountReceivedLD) revert InsufficientMinAmount();

        MessagingFee memory messagingFee = oft.quoteSend(sendParam, false);
        if (address(this).balance < messagingFee.nativeFee) revert InsufficientNativeFee();

        if (oft.approvalRequired()) IERC20(address(asset)).forceApprove(address(oft), amount);

        oft.send{value: messagingFee.nativeFee}(sendParam, messagingFee, payable(address(this)));
    }

    /**
     * @notice Calculates the fee required for bridging through Stargate
     * @dev Returns the native token fee required for the bridge operation
     * @param destEid Destination chain ID in LayerZero format
     * @param asset Address of the asset to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @return Address of the fee token (always ETH) and the required native token fee amount
     */
    function getBridgeFee(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippage) public view returns (address, uint256) {
        if (_getStargateModuleStorage().assetConfig[asset].isOFT) return _getOftBridgeFee(destEid, asset, amount, destRecipient, maxSlippage);
        else return _getNonOftBridgeFee(destEid, asset, amount, destRecipient, maxSlippage);
    }

    /**
     * @notice Gets the bridge fee for a safe
     * @dev This function retrieves the bridge fee for the withdrawal queued for the safe
     * @param safe Address of the EtherFiSafe
     * @return The address of the fee token (always ETH)
     * @return The required native token fee amount
     */    
    function getBridgeFeeForSafe(address safe) external view returns(address, uint256) {
        CrossChainWithdrawal memory withdrawal = _getStargateModuleStorage().withdrawals[safe];
        if (withdrawal.destRecipient == address(0)) revert NoWithdrawalQueuedForStargate();

        return getBridgeFee(withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient, withdrawal.maxSlippageInBps);
    }

    /**
     * @dev Gets the bridge fee for OFT tokens
     * @param destEid Destination chain ID
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param maxSlippage Maximum slippage allowed in basis points
     * @return Address of the fee token (ETH) and the fee amount
     */
    function _getOftBridgeFee(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippage) internal view returns (address, uint256) {
        IOFT oft = IOFT(_getStargateModuleStorage().assetConfig[asset].pool);
        uint256 minAmount = _deductSlippage(amount, maxSlippage);

        SendParam memory sendParam = SendParam({ dstEid: destEid, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: minAmount, extraOptions: hex"0003", composeMsg: new bytes(0), oftCmd: new bytes(0) });
        MessagingFee memory messagingFee = oft.quoteSend(sendParam, false);
        return (ETH, messagingFee.nativeFee);
    }

    /**
     * @dev Gets the bridge fee for non-OFT tokens
     * @param destEid Destination chain ID
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param maxSlippage Maximum slippage allowed in basis points
     * @return Address of the fee token (ETH) and the fee amount
     */
    function _getNonOftBridgeFee(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippage) internal view returns (address, uint256) {
        uint256 minAmount = _deductSlippage(amount, maxSlippage);
        (, , , MessagingFee memory messagingFee,) = prepareRideBus(destEid, asset, amount, destRecipient, minAmount);

        return (ETH, messagingFee.nativeFee);
    }

    /**
     * @notice Prepares parameters for Stargate bridging
     * @dev Implements the "Ride the Bus" pattern from Stargate documentation
     * @param destEid Destination chain ID
     * @param asset Address of the asset to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param minAmount Minimum amount to receive after slippage
     * @return stargate The instance of the stargate pool
     * @return valueToSend Total native token value needed for the transaction
     * @return sendParam Stargate bridging parameters
     * @return messagingFee LayerZero messaging fee details
     * @return poolToken Address of the token accepted by the Stargate pool
     * @custom:throws InsufficientMinAmount if expected received amount is below minimum
     */
    function prepareRideBus(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 minAmount) public view returns (IStargate stargate, uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee, address poolToken) {
        stargate = IStargate(_getStargateModuleStorage().assetConfig[asset].pool);
        sendParam = SendParam({ dstEid: destEid, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: amount, extraOptions: new bytes(0), composeMsg: new bytes(0), oftCmd: new bytes(1) });

        ( , , OFTReceipt memory receipt) = stargate.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;
        if (minAmount > receipt.amountReceivedLD) revert InsufficientMinAmount();

        messagingFee = stargate.quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;
        poolToken = stargate.token();
        if (poolToken == address(0)) {
            valueToSend += sendParam.amountLD;
        }
    }

    /**
     * @notice Calculates the minimum amount after applying slippage
     * @dev Uses basis points for slippage calculation (100% = 10000 bps)
     * @param amount The original amount
     * @param slippage The maximum allowed slippage in basis points
     * @return The minimum amount after slippage deduction
     */
    function _deductSlippage(uint256 amount, uint256 slippage) internal pure returns (uint256) {
        return amount.mulDiv(HUNDRED_PERCENT_IN_BPS - slippage, HUNDRED_PERCENT_IN_BPS);
    }

    /**
     * @dev Sets configurations for multiple assets
     * @param assets Array of asset addresses to configure
     * @param assetConfigs Array of corresponding asset configurations
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws InvalidInput if any asset address is zero
     * @custom:throws InvalidStargatePool if pool doesn't match the token
     */
    function _setAssetConfigs(address[] memory assets, AssetConfig[] memory assetConfigs) internal {
        uint256 len = assets.length;
        if (len != assetConfigs.length) revert ArrayLengthMismatch();

        StargateModuleStorage storage $ = _getStargateModuleStorage();
        address poolToken;

        for (uint256 i = 0; i < len; ) {
            if (assets[i] == address(0)) revert InvalidInput();

            poolToken = IStargate(assetConfigs[i].pool).token();
            if (
                (assets[i] != ETH && poolToken != assets[i]) || 
                (assets[i] == ETH && poolToken != address(0))
            ) revert InvalidStargatePool();

            $.assetConfig[assets[i]] = assetConfigs[i];
            unchecked {
                ++i;
            }
        }

        emit AssetConfigSet(assets, assetConfigs);
    }

    /**
     * @dev Checks if we have sufficient balance of the asset
     * @param asset Address of the asset to check
     * @param amount Required amount of the asset
     * @custom:throws InsufficientAmount if the module doesn't have enough assets
     */
    function _checkBalance(address asset, uint256 amount) internal view {
        if (asset == ETH) {
            if (address(this).balance < amount) revert InsufficientAmount();    
        } else {
            if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientAmount();
        }
    }

    /**
     * @notice Allows the contract to receive ETH
     * @dev Required to handle native token operations
     */
    receive() external payable {}
}