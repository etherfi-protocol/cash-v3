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
import { WithdrawalRequest, SafeData } from "../../interfaces/ICashModule.sol";
import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
import { INttManager } from "../../interfaces/INTTManager.sol";

contract WormholeModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /**
     * @dev Configuration parameters for supported assets and their bridge settings
     * @param nttManager Address of the NTT manager
     * @param dustDecimals Number of decimals to remove from the amount
     */
    struct AssetConfig {
        address nttManager;
        uint8 dustDecimals;
    }

    /**
     * @dev Cross-chain withdrawal request details
     * @param destEid Destination chain ID
     * @param asset Address of the asset being bridged
     * @param amount Amount of the asset being bridged
     * @param destRecipient Recipient address on the destination chain
     */
    struct CrossChainWithdrawal {
        uint16 destEid;
        address asset;
        uint256 amount;
        address destRecipient;
    }

    /**
     * @dev Storage structure for WormholeModule using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.WormholeModule
     */
    struct WormholeModuleStorage {
        /// @notice Asset config for supported tokens
        mapping(address token => AssetConfig assetConfig) assetConfig;
        /// @notice Mapping of withdrawal requested by safes
        mapping(address safe => CrossChainWithdrawal withdrawal) withdrawals;
    }


    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.WormholeModule")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Storage location for the module's storage
    bytes32 private constant WormholeModuleStorageLocation =
        0x0a93d51b2793ea18ce510da8b8cb57b59048d8c53342680b2f2da35f6fe69600;

    /// @notice The ADMIN role for the Wormhole module
    bytes32 public constant WORMHOLE_MODULE_ADMIN_ROLE =
        keccak256("WORMHOLE_MODULE_ADMIN_ROLE");

    /// @notice TypeHash for request bridge function signature
    bytes32 public constant REQUEST_BRIDGE_SIG = keccak256("requestBridge");

    /// @notice Typehash for cancel bridge function signature
    bytes32 public constant CANCEL_BRIDGE_SIG = keccak256("cancelBridge");

    /// @notice Error for Insufficient amount of asset in the safe
    error InsufficientAmount();
    
    /// @notice Error for Unauthorized access
    error Unauthorized();
    
    /// @notice Error for Invalid signatures
    error InvalidSignatures();
    
    /// @notice Error for no withdrawal queued for Wormhole
    error NoWithdrawalQueuedForWormhole();
    
    /// @notice Error for Cannot find matching withdrawal for safe
    error CannotFindMatchingWithdrawalForSafe();
    
    /// @notice Error for Insufficient native fee
    error InsufficientNativeFee();

    /// @notice Error for Invalid amount
    error InvalidAmount();

    /**
     * @notice Emitted when asset configurations are set 
     * @param assets Array of asset addresses that were configured
     * @param assetConfigs Array of corresponding asset configurations
     */
    event AssetConfigSet(address[] assets, AssetConfig[] assetConfigs);

    /**
     * @notice Emitted when a bridge with Wormhole is requested
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in Wormhole format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     */
    event RequestBridgeWithWormhole(address indexed safe, uint16 indexed destEid, address indexed asset, uint256 amount, address destRecipient);
    
    /**
     * @notice Emitted when a bridge with Wormhole is executed
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in Wormhole format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     */
    event BridgeWithWormhole(address indexed safe, uint16 indexed destEid, address indexed asset, uint256 amount, address destRecipient);

    /**
     * @notice Emitted when a bridge request is cancelled
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in Wormhole format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     */
    event BridgeCancelled(address indexed safe, uint16 indexed destEid, address indexed asset, uint256 amount, address destRecipient );

    /**
     * @notice Emitted when a bridge with Wormhole is executed
     * @param token Address of the token being bridged
     * @param amount Amount of the token being bridged
     * @param msgId Message ID of the bridge request
     */
    event BridgeViaNTT(address indexed token, uint256 amount, uint64 msgId);


    /**
     * @notice Constructor for WormholeModule
     * @param _assets Array of asset addresses to configure
     * @param _assetConfigs Array of corresponding asset configurations
     * @param _etherFiDataProvider Address of the EtherFi data provider
     */
    constructor(address[] memory _assets, AssetConfig[] memory _assetConfigs, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _setAssetConfigs(_assets, _assetConfigs);
    }

    /**
     * @notice Gets the asset configuration for a given asset
     * @param asset Address of the asset to get the configuration for
     * @return AssetConfig memory The asset configuration
     */
    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _getWormholeModuleStorage().assetConfig[asset];
    }

    /**
     * @notice Sets the asset configuration for a given asset
     * @param assets Array of asset addresses to configure
     * @param assetConfigs Array of corresponding asset configurations
     * @custom:throws Unauthorized If the caller is not the ADMIN role
     */
    function setAssetConfig(address[] memory assets, AssetConfig[] memory assetConfigs) external {
        IRoleRegistry roleRegistry = IRoleRegistry(etherFiDataProvider.roleRegistry());
        if (!roleRegistry.hasRole(WORMHOLE_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();

        _setAssetConfigs(assets, assetConfigs);
    }

    /**
     * @notice Gets the pending bridge request for a safe
     * @param safe Address of the EtherFiSafe
     * @return CrossChainWithdrawal memory The pending bridge request
     */
    function getPendingBridge(address safe) external view returns (CrossChainWithdrawal memory) {
        return _getWormholeModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Requests a bridge with Wormhole
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in Wormhole format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param signers Array of signers
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidInput If the asset is invalid
     * @custom:throws InvalidSignatures If the signatures are invalid
     */
    function requestBridge(address safe, uint16 destEid, address asset, uint256 amount, address destRecipient, address[] calldata signers, bytes[] calldata signatures) external payable nonReentrant onlyEtherFiSafe(safe) {
        if (destRecipient == address(0) || asset == address(0)) revert InvalidInput();

        _checkSignature(safe, destEid, asset, amount, destRecipient, signers, signatures);

        AssetConfig memory assetConfig = _getWormholeModuleStorage().assetConfig[asset];

        if (assetConfig.nttManager == address(0)) revert InvalidInput();

        uint256 amountWithoutDust = (amount / 10 ** assetConfig.dustDecimals) * 10 ** assetConfig.dustDecimals;
        if (amountWithoutDust == 0) revert InvalidAmount();

        cashModule.requestWithdrawalByModule(safe, asset, amountWithoutDust);

        emit RequestBridgeWithWormhole(safe, destEid, asset, amountWithoutDust, destRecipient);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        if (withdrawalDelay == 0) {
            _bridge(destEid, asset, amountWithoutDust, destRecipient);
            emit BridgeWithWormhole(safe, destEid, asset, amountWithoutDust, destRecipient);
        } else {
            _getWormholeModuleStorage().withdrawals[safe] = CrossChainWithdrawal({
                destEid: destEid,
                asset: asset,
                amount: amountWithoutDust,
                destRecipient: destRecipient
            });
        }
    }

    /**
     * @notice Executes a bridge with Wormhole
     * @param safe Address of the EtherFiSafe
     * @custom:throws NoWithdrawalQueuedForWormhole If no withdrawal is queued for Wormhole
     * @custom:throws CannotFindMatchingWithdrawalForSafe If the withdrawal details don't match
     */
    function executeBridge(address safe) public payable nonReentrant onlyEtherFiSafe(safe) {
        CrossChainWithdrawal memory withdrawal = _getWormholeModuleStorage().withdrawals[safe];

        if (withdrawal.destRecipient == address(0)) revert NoWithdrawalQueuedForWormhole();

        WithdrawalRequest memory withdrawalRequest = cashModule.getData(safe).pendingWithdrawalRequest;

        if (withdrawalRequest.recipient != address(this) || withdrawalRequest.tokens.length != 1 || withdrawalRequest.tokens[0] != withdrawal.asset || withdrawalRequest.amounts[0] != withdrawal.amount) revert CannotFindMatchingWithdrawalForSafe();

        cashModule.processWithdrawal(safe);

        _bridge(withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient);
        emit BridgeWithWormhole(safe, withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient);

        delete _getWormholeModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Cancels a bridge with Wormhole
     * @param safe Address of the EtherFiSafe
     * @param signers Array of signers
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidSignatures If the signatures are invalid
     */
    function cancelBridge(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        bytes32 digestHash = keccak256(abi.encodePacked(CANCEL_BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();

        CrossChainWithdrawal storage withdrawal = _getWormholeModuleStorage().withdrawals[safe];
        if (withdrawal.destRecipient == address(0)) revert NoWithdrawalQueuedForWormhole();

        SafeData memory data = cashModule.getData(safe);

        if (data.pendingWithdrawalRequest.recipient == address(this)) cashModule.cancelWithdrawalByModule(safe);

        if (withdrawal.asset != address(0)) {
            emit BridgeCancelled(safe, withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient);
            delete _getWormholeModuleStorage().withdrawals[safe];
        }
    }

    /**
     * @notice Checks the signature for a bridge request
     * @param safe Address of the EtherFiSafe
     * @param destEid Destination chain ID in Wormhole format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @param signers Array of signers
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidSignatures If the signatures are invalid
     */
    function _checkSignature(address safe, uint16 destEid, address asset, uint256 amount, address destRecipient, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(REQUEST_BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, abi.encode(destEid, asset, amount, destRecipient))).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @notice Sets the asset configurations
     * @param assets Array of asset addresses to configure
     * @param assetConfigs Array of corresponding asset configurations
     * @custom:throws ArrayLengthMismatch If the array lengths do not match
     * @custom:throws InvalidInput If the asset is invalid
     */
    function _setAssetConfigs(address[] memory assets,AssetConfig[] memory assetConfigs) internal {
        uint256 len = assets.length;
        if (len != assetConfigs.length) revert ArrayLengthMismatch();

        WormholeModuleStorage storage $ = _getWormholeModuleStorage();

        for (uint256 i = 0; i < len; ) {
            if (assets[i] == address(0) || assetConfigs[i].nttManager == address(0)) revert InvalidInput();

            $.assetConfig[assets[i]] = assetConfigs[i];
            unchecked {
                ++i;
            }
        }

        emit AssetConfigSet(assets, assetConfigs);
    }

    /**
     * @notice Gets the bridge fee for a given asset
     * @param recipientChain Destination chain ID in Wormhole format
     * @param asset Address of the asset to get the fee for
     * @return address The address of the ETH
     * @return uint256 The bridge fee in Ethereum
     * @custom:throws InvalidInput If the asset is invalid
     */
    function getBridgeFee(uint16 recipientChain, address asset) public view returns (address, uint256) {
        WormholeModuleStorage storage $ = _getWormholeModuleStorage();
        address nttManager = $.assetConfig[asset].nttManager;

        if (nttManager == address(0)) revert InvalidInput();
        ( , uint256 price) = INttManager(nttManager).quoteDeliveryPrice(recipientChain, new bytes(1));
        return (ETH, price);
    }

    /**
     * @notice Gets the storage for the Wormhole module
     */
    function _getWormholeModuleStorage() internal pure returns (WormholeModuleStorage storage $) {
        assembly {
            $.slot := WormholeModuleStorageLocation
        }
    }

    /**
     * @notice Checks the balance of a given asset
     * @param asset Address of the asset to check the balance of
     * @param amount Amount of the asset to check the balance of
     * @custom:throws InsufficientAmount If the balance is insufficient
     */
    function _checkBalance(address asset, uint256 amount) internal view {
        if (asset == ETH) {
            if (address(this).balance < amount) revert InsufficientAmount();
        } else {
            if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientAmount();
        }
    }

    /**
     * @notice Bridges a given asset through Wormhole
     * @param destEid Destination chain ID in Wormhole format
     * @param asset Address of the asset to bridge
     * @param amount Amount of the asset to bridge
     * @param destRecipient Recipient address on the destination chain
     * @custom:throws InsufficientAmount If the balance is insufficient
     * @custom:throws InvalidInput If the asset is invalid
     * @custom:throws InsufficientNativeFee If the native fee is insufficient
     */
    function _bridge(uint16 destEid, address asset, uint256 amount, address destRecipient) internal {
        _checkBalance(asset, amount);

        AssetConfig memory assetConfig = _getWormholeModuleStorage().assetConfig[asset];

        if (assetConfig.nttManager == address(0)) revert InvalidInput();

        ( , uint256 price) = INttManager(assetConfig.nttManager).quoteDeliveryPrice(destEid, new bytes(1));
        if (address(this).balance < price) revert InsufficientNativeFee();

        IERC20(asset).forceApprove(assetConfig.nttManager, amount);

        uint64 msgId = INttManager(assetConfig.nttManager).transfer{value: price}(amount, destEid, bytes32(uint256(uint160(destRecipient))));
        emit BridgeViaNTT(asset, amount, msgId);
    }
    
    /**
     * @notice Cancels a bridge with Wormhole
     * @param safe Address of the EtherFiSafe
     * @custom:throws Unauthorized If the caller is not the cash module
     */
    function cancelBridgeByCashModule(address safe) external override {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        CrossChainWithdrawal storage withdrawal = _getWormholeModuleStorage().withdrawals[safe];
        // Return if no withdrawal found for Wormhole
        if (withdrawal.destRecipient == address(0)) return; 

        emit BridgeCancelled(safe, withdrawal.destEid, withdrawal.asset, withdrawal.amount, withdrawal.destRecipient);
        delete _getWormholeModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Allows the contract to receive ETH
     * @dev Required to handle native token operations
     */
    receive() external payable {}
}

