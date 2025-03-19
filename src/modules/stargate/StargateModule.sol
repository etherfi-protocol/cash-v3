// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ModuleBase } from "../ModuleBase.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { IOFT, MessagingFee, MessagingReceipt, OFTFeeDetail, OFTLimit, OFTReceipt, SendParam, SendParam } from "../../interfaces/IOFT.sol";
import { IStargate, Ticket } from "../../interfaces/IStargate.sol";

contract StargateModule is ModuleBase {
    using MessageHashUtils for bytes32;
    using Math for uint256;

    /**
     * @dev Configuration parameters for supported assets and their bridge settings
     * @param pool Stargate pool address for non-OFTs, OFT address for OFTs
     */
    struct AssetConfig {
        bool isOFT;
        address pool;
    }

    /**
     * @dev Storage structure for StargateModule using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.StargateModule
     */
    struct StargateModuleStorage {
        /// @notice Asset config for supported tokens
        mapping(address token => AssetConfig assetConfig) assetConfig;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StargateModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StargateModuleStorageLocation = 0xeafa2356b7fab3fae77872025a25cb67884d7667f22b14ae60e3f63732a39c00;

    /// @notice The ADMIN role for the Stargate module
    bytes32 public constant STARGATE_MODULE_ADMIN_ROLE = keccak256("STARGATE_MODULE_ADMIN_ROLE");

    /// @notice TypeHash for bridge function signature used in EIP-712 signatures
    bytes32 public constant BRIDGE_SIG = keccak256("bridge");

    /// @notice 100% in bps
    uint256 public constant HUNDRES_PERCENT_IN_BPS = 10_000;
    
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
    error Unauthorized();

    event AssetConfigSet(address[] assets, AssetConfig[] assetConfigs);

    constructor(address[] memory _assets, AssetConfig[] memory _assetConfigs, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
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

    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _getStargateModuleStorage().assetConfig[asset];
    }

    function setAssetConfig(address[] memory assets, AssetConfig[] memory assetConfigs) external {
        IRoleRegistry roleRegistry = IRoleRegistry(etherFiDataProvider.roleRegistry());
        if (!roleRegistry.hasRole(STARGATE_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();

        _setAssetConfigs(assets, assetConfigs);
    }

    function bridge(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps, address[] calldata signers, bytes[] calldata signatures) external payable onlyEtherFiSafe(safe) {
        _checkSignature(safe, destEid, asset, amount, destRecipient, maxSlippageInBps, signers, signatures);
        _bridge(safe, destEid, asset, amount, destRecipient, maxSlippageInBps);
    }

    function _checkSignature(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, abi.encode(destEid, asset, amount, destRecipient, maxSlippageInBps))).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    function _bridge(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps) internal {
        if (destRecipient == address(0) || asset == address(0) || amount == 0) revert InvalidInput();
        _checkBalance(safe, asset, amount);
    
        uint256 minAmount = _deductSlippage(amount, maxSlippageInBps);

        if (_getStargateModuleStorage().assetConfig[asset].isOFT) _bridgeOft(safe, destEid, asset, amount, destRecipient, minAmount);
        else _bridgeNonOft(safe, destEid, asset, amount, destRecipient, minAmount);
    }

    function _bridgeNonOft(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 minReturnAmount) internal {
        (IStargate stargate, uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee, address poolToken) = prepareRideBus(destEid, asset, amount, destRecipient, minReturnAmount);
        if (address(this).balance < messagingFee.nativeFee) revert InsufficientNativeFee();

        (bool success, ) = safe.call{value: messagingFee.nativeFee}("");
        if (!success) revert NativeTransferFailed();

        address[] memory to;
        uint256[] memory value;
        bytes[] memory data;
        
        if (asset != ETH) {
            if (poolToken != asset) revert InvalidStargatePool();

            to = new address[](2);
            value = new uint256[](2);
            data = new bytes[](2);
            
            to[0] = asset;
            value[0] = 0;
            data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(stargate), amount);

            to[1] = address(stargate);
            value[1] = valueToSend;
            data[1] = abi.encodeWithSelector(IStargate.sendToken.selector, sendParam, messagingFee, payable(address(this)));
        } else {
            if (poolToken != address(0)) revert InvalidStargatePool();

            to = new address[](1);
            value = new uint256[](1);
            data = new bytes[](1);

            to[0] = address(stargate);
            value[0] = valueToSend;
            data[0] = abi.encodeWithSelector(IStargate.sendToken.selector, sendParam, messagingFee, payable(address(this)));
        }
        
        IEtherFiSafe(safe).execTransactionFromModule(to, value, data);

    }

    function _bridgeOft(address safe, uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 minReturnAmount) internal {
        IOFT oft = IOFT(_getStargateModuleStorage().assetConfig[asset].pool);
        SendParam memory sendParam = SendParam({ dstEid: destEid, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: minReturnAmount, extraOptions: hex"0003", composeMsg: new bytes(0), oftCmd: new bytes(0) });

        ( , , OFTReceipt memory oftReceipt) = oft.quoteOFT(sendParam);
        sendParam.minAmountLD = oftReceipt.amountReceivedLD;
        if (minReturnAmount > oftReceipt.amountReceivedLD) revert InsufficientMinAmount();

        MessagingFee memory messagingFee = oft.quoteSend(sendParam, false);
        if (address(this).balance < messagingFee.nativeFee) revert InsufficientNativeFee();

        (bool success, ) = safe.call{value: messagingFee.nativeFee}("");
        if (!success) revert NativeTransferFailed();

        address[] memory to;
        uint256[] memory value;
        bytes[] memory data;
        if (oft.approvalRequired()) {
            to = new address[](2);
            value = new uint256[](2);
            data = new bytes[](2);

            to[0] = asset;
            data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(oft), amount);

            to[1] = address(oft);
            value[1] = messagingFee.nativeFee;
            data[1] = abi.encodeWithSelector(IOFT.send.selector, sendParam, messagingFee, payable(address(this)));
        } else {
            to = new address[](1);
            value = new uint256[](1);
            data = new bytes[](1);
            
            to[0] = address(oft);
            value[0] = messagingFee.nativeFee;
            data[0] = abi.encodeWithSelector(IOFT.send.selector, sendParam, messagingFee, payable(address(this)));
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, value, data);
    }

    /**
     * @notice Calculates the fee required for bridging through Stargate
     * @dev Returns the native token fee required for the bridge operation
     * @param asset Unused in this implementation
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @return ETH address and the required native token fee amount
     */
    function getBridgeFee(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippage) external view returns (address, uint256) {
        if (_getStargateModuleStorage().assetConfig[asset].isOFT) return _getOftBridgeFee(destEid, asset, amount, destRecipient, maxSlippage);
        else return _getNonOftBridgeFee(destEid, asset, amount, destRecipient, maxSlippage);
    }

    function _getOftBridgeFee(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippage) internal view returns (address, uint256) {
        IOFT oft = IOFT(_getStargateModuleStorage().assetConfig[asset].pool);
        uint256 minAmount = _deductSlippage(amount, maxSlippage);

        SendParam memory sendParam = SendParam({ dstEid: destEid, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: minAmount, extraOptions: hex"0003", composeMsg: new bytes(0), oftCmd: new bytes(0) });
        MessagingFee memory messagingFee = oft.quoteSend(sendParam, false);
        return (ETH, messagingFee.nativeFee);
    }

    function _getNonOftBridgeFee(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippage) internal view returns (address, uint256) {
        uint256 minAmount = _deductSlippage(amount, maxSlippage);
        (, , , MessagingFee memory messagingFee,) = prepareRideBus(destEid, asset, amount, destRecipient, minAmount);

        return (ETH, messagingFee.nativeFee);
    }

    // from https://stargateprotocol.gitbook.io/stargate/v/v2-developer-docs/integrate-with-stargate/how-to-swap#ride-the-bus
    /**
     * @notice Prepares parameters for Stargate bridging
     * @dev Implements the "Ride the Bus" pattern from Stargate documentation
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
        return amount.mulDiv(HUNDRES_PERCENT_IN_BPS - slippage, HUNDRES_PERCENT_IN_BPS);
    }

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

    function _checkBalance(address safe, address asset, uint256 amount) internal view {
        if (asset == ETH) {
            if (safe.balance < amount) revert InsufficientAmount();    
        } else {
            if (IERC20(asset).balanceOf(safe) < amount) revert InsufficientAmount();
        }
    }

    receive() external payable {}
}