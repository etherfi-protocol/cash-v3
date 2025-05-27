// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IBoringOnChainQueue } from "../../interfaces/IBoringOnChainQueue.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IWETH } from "../../interfaces/IWETH.sol";
import { ILayerZeroTeller } from "../../interfaces/ILayerZeroTeller.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title EtherFiLiquidModule
 * @author ether.fi
 * @notice Module for interacting with ether.fi Liquid vaults
 * @dev Extends ModuleBase to provide ether.fi Liquid integration for Safes
 */
contract EtherFiLiquidModule is ModuleBase {
    using MessageHashUtils for bytes32;
    using SafeCast for uint256;

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

    /// @notice Address of the wrapped ETH contract
    address public immutable weth;
    
    /// @notice Mapping from liquid asset address to its corresponding teller contract
    mapping(address asset => ILayerZeroTeller teller) public liquidAssetToTeller;

    /// @notice Mapping of liquid token address to its withdraw config
    mapping (address liquidToken => LiquidWithdrawConfig) liquidWithdrawConfig;

    /// @notice TypeHash for deposit function signature 
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");
    
    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    /// @notice TypeHash for bridge function signature 
    bytes32 public constant BRIDGE_SIG = keccak256("bridge");

    /// @notice Role identifier for admins of the Liquid Module
    bytes32 public constant ETHERFI_LIQUID_MODULE_ADMIN = keccak256("ETHERFI_LIQUID_MODULE_ADMIN");

    /// @notice Emitted when new liquid assets and their tellers are added to the module
    event LiquidAssetsAdded(address[] liquidAssets, address[] tellers);
    
    /// @notice Emitted when liquid assets are removed from the module
    event LiquidAssetsRemoved(address[] liquidAssets);

    /// @notice Emitted when safe deposits into Liquid
    event LiquidDeposit(address indexed safe, address indexed inputToken, address indexed outputToken, uint256 inputAmount, uint256 outputAmount);

    /// @notice Emitted when safe withdraws from Liquid
    event LiquidWithdrawal(address indexed safe, address indexed liquidAsset, uint256 amountToWithdraw, uint256 amountOut);
    
    /// @notice Emitted when safe bridge Liquid assets to other chains
    event LiquidBridged(address indexed safe, address indexed liquidAsset, address indexed destRecipient, uint32 destEid, uint256 amount, uint256 bridgeFee);

    /**
     * @notice Emitted when liquid asset withdraw config is set
     * @param token Address of the liquid asset
     * @param boringQueue Address of the boring queue
     * @param discount Discount percentage with 5 decimals precision
     * @param secondsToDeadline The time in seconds the request is valid for
     */
    event LiquidWithdrawConfigSet(address indexed token,  address boringQueue, uint16 discount, uint24 secondsToDeadline);
    
    /// @notice Thrown when the Safe doesn't have sufficient token balance for an operation
    error InsufficientBalanceOnSafe();
    
    /// @notice Thrown when attempting to deposit to a liquid asset not supported by the module
    error UnsupportedLiquidAsset();
    
    /// @notice Thrown when the asset is not configured to accept deposits in the teller
    error AssetNotSupportedForDeposit();
    
    /// @notice Thrown when a caller lacks the proper authorization for an operation
    error Unauthorized();
    
    /// @notice Thrown when the teller configuration does not match the expected liquid asset
    error InvalidConfiguration();

    /// @notice Error for Invalid Owner quorum signatures
    error InvalidSignatures();

    /// @notice Error when native fee is insufficient
    error InsufficientNativeFee();

    /// @notice Error when native transfer fails
    error NativeTransferFailed();

    /// @notice Error when the return amount is less than min return
    error InsufficientReturnAmount();

    /// @notice Thrown when liquid withdraw config is not set for the liquid token
    error LiquidWithdrawConfigNotSet();

    /// @notice Thrown when the boring queue has a different boring vault than expected
    error InvalidBoringQueue();

    /// @notice Thrown when an address value is address(0)
    error InvalidValue();

    /**
     * @notice Contract constructor
     * @param _assets Addresses of the supported liquid assets
     * @param _tellers Addresses of the Teller contracts for the liquid assets
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _weth Address of the wrapped ETH contract
     * @dev Initializes the contract with supported liquid assets and their corresponding tellers
     * @custom:throws ArrayLengthMismatch If the lengths of arrays mismatch
     * @custom:throws InvalidInput If any provided address is zero
     */
    constructor(address[] memory _assets, address[] memory _tellers, address _etherFiDataProvider, address _weth) ModuleBase(_etherFiDataProvider) {
        uint256 len = _assets.length;
        if (len != _tellers.length) revert ArrayLengthMismatch();
        if (_etherFiDataProvider == address(0) || _weth == address(0)) revert InvalidInput();

        weth = _weth;
        for (uint256 i = 0; i < len; ) {
            if (_assets[i] == address(0) || _tellers[i] == address(0)) revert InvalidInput();
            if (address(ILayerZeroTeller(_tellers[i]).vault()) != _assets[i]) revert InvalidConfiguration();
            liquidAssetToTeller[_assets[i]] = ILayerZeroTeller(_tellers[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Deposits tokens to a Liquid vault using signature verification
     * @param safe The Safe address which holds the tokens
     * @param assetToDeposit The address of the asset to deposit (or ETH address for ETH)
     * @param liquidAsset The address of the liquid token to receive
     * @param amountToDeposit The amount of tokens to deposit
     * @param minReturn The minimum amount of liquid tokens to receive
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     * @custom:throws UnsupportedLiquidAsset If the liquid asset is not supported
     * @custom:throws AssetNotSupportedForDeposit If the asset cannot be deposited to the teller
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws InsufficientReturnAmount If the return amount is less than min return
     */
    function deposit(address safe, address assetToDeposit, address liquidAsset, uint256 amountToDeposit, uint256 minReturn, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, assetToDeposit, liquidAsset, amountToDeposit, minReturn);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, assetToDeposit, liquidAsset, amountToDeposit, minReturn);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address which holds the tokens
     * @param assetToDeposit The address of the asset to deposit
     * @param liquidAsset The address of the liquid token
     * @param amountToDeposit The amount to deposit
     * @param minReturn The minimum amount of liquid tokens to receive
     * @return The digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, address assetToDeposit, address liquidAsset, uint256 amountToDeposit, uint256 minReturn) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(assetToDeposit, liquidAsset, amountToDeposit, minReturn))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function to deposit assets to a Liquid vault
     * @param safe The Safe address which holds the tokens
     * @param assetToDeposit The address of the asset to deposit (or ETH address for ETH)
     * @param liquidAsset The address of the liquid token to receive
     * @param amountToDeposit The amount of tokens to deposit
     * @param minReturn The minimum amount of liquid tokens to receive
     * @custom:throws UnsupportedLiquidAsset If the liquid asset is not supported
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     * @custom:throws AssetNotSupportedForDeposit If the asset cannot be deposited to the teller
     * @custom:throws InsufficientReturnAmount If the return amount is less than min return
     */
    function _deposit(address safe, address assetToDeposit, address liquidAsset, uint256 amountToDeposit, uint256 minReturn) internal {
        ILayerZeroTeller teller = liquidAssetToTeller[liquidAsset];
        if (address(teller) == address(0)) revert UnsupportedLiquidAsset();
        
        if (amountToDeposit == 0 || minReturn == 0) revert InvalidInput();
        
        uint256 bal;
        if (assetToDeposit == ETH) bal = safe.balance;        
        else bal = ERC20(assetToDeposit).balanceOf(safe);
        
        if (bal < amountToDeposit) revert InsufficientBalanceOnSafe();

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        if (assetToDeposit == ETH) {
            if (!teller.assetData(ERC20(weth)).allowDeposits) revert AssetNotSupportedForDeposit();

            to = new address[](3);
            data = new bytes[](3);
            values = new uint256[](3);

            to[0] = weth;
            data[0] = abi.encodeWithSelector(IWETH.deposit.selector);
            values[0] = amountToDeposit;

            to[1] = weth;
            data[1] = abi.encodeWithSelector(ERC20.approve.selector, address(liquidAsset), amountToDeposit);
            
            to[2] = address(teller);
            data[2] = abi.encodeWithSelector(ILayerZeroTeller.deposit.selector, ERC20(weth), amountToDeposit, minReturn);
        } else {
            if (!teller.assetData(ERC20(assetToDeposit)).allowDeposits) revert AssetNotSupportedForDeposit();

            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);

            to[0] = assetToDeposit;
            data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(liquidAsset), amountToDeposit);
            
            to[1] = address(teller);
            data[1] = abi.encodeWithSelector(ILayerZeroTeller.deposit.selector, ERC20(assetToDeposit), amountToDeposit, minReturn);
        }

        uint256 liquidTokenBalBefore = ERC20(liquidAsset).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        
        uint256 liquidTokenReceived = ERC20(liquidAsset).balanceOf(safe) - liquidTokenBalBefore;
        if (liquidTokenReceived < minReturn) revert InsufficientReturnAmount();

        emit LiquidDeposit(safe, assetToDeposit, liquidAsset, amountToDeposit, liquidTokenReceived);
    }

    /**
     * @notice Withdraws from Liquid tokens from the safe
     * @param safe The Safe address which holds the tokens 
     * @param liquidAsset The address of the liquid token to withdraw 
     * @param assetOut The address of the underlying token to receive 
     * @param amountToWithdraw The amount of tokens to withdraw
     * @param minReturn Acceptable min return amount of asset out
     * @param signer The address that signed the transaction 
     * @param signature The signature authorizing the transaction 
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws LiquidWithdrawConfigNotSet If the liquid withdraw config is not set for the liquid token
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough liquid asset balance
     * @custom:throws InvalidInput If the Safe doesn't have enough liquid asset balance
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function withdraw(address safe, address liquidAsset, address assetOut, uint128 amountToWithdraw, uint128 minReturn, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getWithdrawDigestHash(safe, liquidAsset, amountToWithdraw, minReturn);
        _verifyAdminSig(digestHash, signer, signature);
        _withdraw(safe, liquidAsset, assetOut, amountToWithdraw, minReturn);
    }

    /**
     * @dev Creates a digest hash for the withdraw operation
     * @param safe The Safe address which holds the tokens
     * @param liquidAsset The address of the liquid token
     * @param amountToWithdraw The amount to withdraw
     * @param minReturn Acceptable min return amount of asset out
     * @return The digest hash for signature verification
     */
    function _getWithdrawDigestHash(address safe, address liquidAsset, uint128 amountToWithdraw, uint128 minReturn) internal returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(liquidAsset, amountToWithdraw, minReturn))).toEthSignedMessageHash();
    }

    /**
     * @notice Internal function which facilitates liquid withdrawals from the safe
     * @param safe The Safe address which holds the tokens 
     * @param liquidAsset The address of the liquid token to withdraw
     * @param assetOut The address of the underlying token to receive 
     * @param amountToWithdraw The amount of tokens to withdraw
     * @param minReturn Acceptable min return amount of asset out
     * @custom:throws LiquidWithdrawConfigNotSet If the liquid withdraw config is not set for the liquid token
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough liquid asset balance
     * @custom:throws InvalidInput If the Safe doesn't have enough liquid asset balance
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function _withdraw(address safe, address liquidAsset, address assetOut, uint128 amountToWithdraw, uint128 minReturn) internal {
        IBoringOnChainQueue boringQueue = IBoringOnChainQueue(liquidWithdrawConfig[liquidAsset].boringQueue);
        uint16 discount = liquidWithdrawConfig[liquidAsset].discount;
        if (address(boringQueue) == address(0)) revert LiquidWithdrawConfigNotSet();
        if (amountToWithdraw == 0) revert InvalidInput();
        if (ERC20(liquidAsset).balanceOf(safe) < amountToWithdraw) revert InsufficientBalanceOnSafe();

        uint128 amountOutFromQueue = boringQueue.previewAssetsOut(assetOut, amountToWithdraw, discount);
        if (amountOutFromQueue < minReturn) revert InsufficientReturnAmount();

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = liquidAsset;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, boringQueue, amountToWithdraw);
        
        to[1] = address(boringQueue);
        data[1] = abi.encodeWithSelector(IBoringOnChainQueue.requestOnChainWithdraw.selector, assetOut, amountToWithdraw, discount, liquidWithdrawConfig[liquidAsset].secondsToDeadline);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        
        emit LiquidWithdrawal(safe, liquidAsset, amountToWithdraw, amountOutFromQueue);
    }

    /**
     * @notice Bridges liquid assets from one chain to another
     * @param safe The Safe address which holds the tokens
     * @param liquidAsset The address of the liquid asset to bridge
     * @param destEid The destination chain ID in LayerZero format
     * @param destRecipient The recipient address on the destination chain
     * @param amount The amount of liquid asset to bridge
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of signatures from the signers
     * @dev Verifies signatures then executes the bridge operation through the Safe's module execution
     * @custom:throws InvalidSignatures If the signatures are invalid
     * @custom:throws UnsupportedLiquidAsset If the liquid asset is not supported
     * @custom:throws InsufficientNativeFee If the provided native fee is insufficient
     * @custom:throws NativeTransferFailed If the native token transfer to the safe fails
     */
    function bridge(address safe, address liquidAsset, uint32 destEid, address destRecipient, uint256 amount, address[] calldata signers, bytes[] calldata signatures) external payable onlyEtherFiSafe(safe) {
        _checkBridgeSignature(safe, liquidAsset, destEid, destRecipient, amount, signers, signatures);
        _bridge(safe, liquidAsset, destEid, destRecipient, amount);
    }

    /**
     * @notice Returns the bridge fee for bridging liquid asset
     * @param liquidAsset Address of the liquid asset
     * @param destEid The destination chain ID in LayerZero format
     * @param destRecipient The recipient address on the destination chain
     * @param amount The amount of liquid assets to bridge
     */
    function getBridgeFee(address liquidAsset, uint32 destEid, address destRecipient, uint256 amount) external view returns(uint256) {
        ILayerZeroTeller teller = liquidAssetToTeller[liquidAsset];
        if (address(teller) == address(0)) revert UnsupportedLiquidAsset();

        bytes memory bridgeWildCard = abi.encode(destEid);
        return teller.previewFee(amount.toUint96(), destRecipient, bridgeWildCard, ERC20(ETH));
    }

    /**
     * @dev Verifies that the transaction has been properly signed by the required signers
     * @param safe Address of the EtherFiSafe
     * @param liquidAsset Address of the liquid asset to bridge
     * @param destEid Destination chain ID
     * @param destRecipient Recipient address on the destination chain
     * @param amount Amount of the asset to bridge
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of signatures from the signers
     * @custom:throws InvalidSignatures if the signatures are invalid
     */
    function _checkBridgeSignature(address safe, address liquidAsset, uint32 destEid, address destRecipient, uint256 amount, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, abi.encode(liquidAsset, destEid, destRecipient, amount))).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @dev Internal function to execute the bridge operation
     * @param safe The Safe address which holds the tokens
     * @param liquidAsset The address of the liquid asset to bridge
     * @param destEid The destination chain ID in LayerZero format
     * @param destRecipient The recipient address on the destination chain
     * @param amount The amount of liquid asset to bridge
     * @custom:throws UnsupportedLiquidAsset If the liquid asset is not supported
     * @custom:throws InsufficientNativeFee If the provided native fee is insufficient
     * @custom:throws NativeTransferFailed If the native token transfer to the safe fails
     */
    function _bridge(address safe, address liquidAsset, uint32 destEid, address destRecipient, uint256 amount) internal {
        ILayerZeroTeller teller = liquidAssetToTeller[liquidAsset];
        if (address(teller) == address(0)) revert UnsupportedLiquidAsset();

        bytes memory bridgeWildCard = abi.encode(destEid);
        uint256 fee = teller.previewFee(amount.toUint96(), destRecipient, bridgeWildCard, ERC20(ETH));

        if (address(this).balance < fee) revert InsufficientNativeFee();
        (bool success, ) = safe.call{value: fee}("");
        if (!success) revert NativeTransferFailed();

        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        to[0] = address(teller); 
        values[0] = fee;
        data[0] = abi.encodeWithSelector(ILayerZeroTeller.bridge.selector, amount, destRecipient, bridgeWildCard, ERC20(ETH), fee);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit LiquidBridged(safe, liquidAsset, destRecipient, destEid, amount, fee);
    }

    /**
     * @notice Adds new liquid assets and their corresponding tellers to the module
     * @param liquidAssets Array of liquid asset addresses to add
     * @param tellers Array of teller addresses corresponding to the liquid assets
     * @dev Only callable by accounts with the ETHERFI_LIQUID_MODULE_ADMIN role
     * @custom:throws Unauthorized If caller doesn't have the admin role
     * @custom:throws ArrayLengthMismatch If the lengths of arrays mismatch
     * @custom:throws InvalidInput If any provided address is zero or the array is empty
     * @custom:throws InvalidConfiguration If a teller's vault doesn't match the expected liquid asset
     */
    function addLiquidAssets(address[] calldata liquidAssets, address[] calldata tellers) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(ETHERFI_LIQUID_MODULE_ADMIN, msg.sender)) revert Unauthorized();

        uint256 len = liquidAssets.length;
        if (len != tellers.length) revert ArrayLengthMismatch();
        if (len == 0) revert InvalidInput();

        for (uint256 i = 0; i < len; ) {
            if (liquidAssets[i] == address(0) || tellers[i] == address(0)) revert InvalidInput();
            if (address(ILayerZeroTeller(tellers[i]).vault()) != liquidAssets[i]) revert InvalidConfiguration();

            liquidAssetToTeller[liquidAssets[i]] = ILayerZeroTeller(tellers[i]);

            unchecked {
                ++i;
            }
        }

        emit LiquidAssetsAdded(liquidAssets, tellers);
    }

    /**
     * @notice Removes liquid assets from the module
     * @param liquidAssets Array of liquid asset addresses to remove
     * @dev Only callable by accounts with the ETHERFI_LIQUID_MODULE_ADMIN role
     * @custom:throws Unauthorized If caller doesn't have the admin role
     * @custom:throws InvalidInput If the array is empty
     */
    function removeLiquidAsset(address[] calldata liquidAssets) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(ETHERFI_LIQUID_MODULE_ADMIN, msg.sender)) revert Unauthorized();

        uint256 len = liquidAssets.length;
        if (len == 0) revert InvalidInput();

        for (uint256 i = 0; i < len; ) {
            delete liquidAssetToTeller[liquidAssets[i]];
            unchecked {
                ++i;
            }
        }

        emit LiquidAssetsRemoved(liquidAssets);
    }

    /**
     * @notice Function to set the liquid asset withdraw config 
     * @dev Only callable by the role registry owner
     * @param asset Address of the liquid asset
     * @param boringQueue Address of the boring queue
     * @param discount Discount in bps
     * @param secondsToDeadline Seconds to deadline after which the withdraw request would expire
     * @custom:throws InvalidValue If any address parameter is zero
     * @custom:throws BoringQueueDoesNotAllowAssetOut If the boring queue does not allow the asset out 
     * @custom:throws InvalidDiscount If the discount is out of min and max bounds
     * @custom:throws SecondsToDeadlingLowerThanMin If the seconds to deadline is lesser than the min seconds to deadline 
     */
    function setLiquidAssetWithdrawConfig(address asset, address boringQueue, uint16 discount, uint24 secondsToDeadline) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(ETHERFI_LIQUID_MODULE_ADMIN, msg.sender)) revert Unauthorized();
        
        if (asset == address(0) ||  boringQueue == address(0)) revert InvalidValue();
        if (asset != address(IBoringOnChainQueue(boringQueue).boringVault())) revert InvalidBoringQueue();

        liquidWithdrawConfig[asset] = LiquidWithdrawConfig({
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
        return liquidWithdrawConfig[asset];
    } 
}
