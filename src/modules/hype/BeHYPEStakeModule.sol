// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { IL2BeHYPEOAppStaker } from "../../interfaces/IL2BeHYPEOAppStaker.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";

/**
 * @title BeHYPEStakeModule
 * @author ether.fi
 * @notice Module for staking WHYPE tokens to receive beHYPE through cross-chain messaging
 * @dev Extends ModuleBase to provide async staking functionality for Safes
 *      beHYPE tokens are delivered asynchronously via LayerZero to the safe
 */
contract BeHYPEStakeModule is ModuleBase, ModuleCheckBalance {
    using MessageHashUtils for bytes32;

    /// @notice Reference to the L2BeHYPEOAppStaker contract for staking operations
    IL2BeHYPEOAppStaker public immutable staker;

    /// @notice Address of the WHYPE token contract
    address public immutable whype;

    /// @notice Address of the beHYPE token contract (for event tracking)
    address public immutable beHYPE;

    /// @notice TypeHash for stake function signature 
    bytes32 public constant STAKE_SIG = keccak256("stake");

    /// @custom:storage-location erc7201:etherfi.storage.BeHYPEStakeModule
    struct BeHYPEStakeModuleStorage {
        /// @notice Gas limit to use when refunding excess fees back to the admin
        uint32 refundGasLimit;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.BeHYPEStakeModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BeHYPEStakeModuleStorageLocation =
        0x7360fa4520b143a14b5f377b55b454493ca513d405fba1b8dcff3eff4e862c00;

    event StakeDeposit(address indexed safe, address indexed inputAsset, address indexed outputAsset, uint256 inputAmount);
    event RefundGasLimitUpdated(uint32 refundGasLimit);

    /// @notice Thrown when the provided fee is insufficient for the cross-chain transaction
    error InsufficientFee();
    /// @notice Thrown when refunding excess fee back to the caller fails
    error RefundFailed();
    /// @notice Thrown when caller lacks the required module admin role
    error Unauthorized();

    /// @notice Role identifier for BeHYPE stake module administrators
    bytes32 public constant BEHYPE_STAKE_MODULE_ADMIN_ROLE = keccak256("BEHYPE_STAKE_MODULE_ADMIN_ROLE");

    /**
     * @notice Contract constructor
     * @param _dataProvider Address of the EtherFiDataProvider contract
     * @param _staker Address of the L2BeHYPEOAppStaker contract
     * @param _whype Address of the WHYPE token contract
     * @param _beHYPE Address of the beHYPE token contract
     * @dev Initializes the contract with required contract references
     */
    constructor(address _dataProvider, address _staker, address _whype, address _beHYPE, uint32 _refundGasLimit) ModuleBase(_dataProvider) ModuleCheckBalance(_dataProvider) {
        if (_staker == address(0) || _whype == address(0) || _beHYPE == address(0)) revert InvalidInput();
        staker = IL2BeHYPEOAppStaker(_staker);
        whype = _whype;
        beHYPE = _beHYPE;
        _getBeHYPEStakeModuleStorage().refundGasLimit = _refundGasLimit;
    }

    /**
     * @notice Stakes WHYPE tokens using signature verification
     * @param safe The Safe address which holds the tokens
     * @param amountToStake The amount of WHYPE tokens to stake
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes the staking operation through the Safe's module execution
     *      The admin provides the cross-chain fee via msg.value which is validated against the quoted fee
     *      beHYPE tokens will be delivered asynchronously to the safe via LayerZero messaging
     * @custom:throws InvalidInput If amountToStake is zero
     * @custom:throws InsufficientFee If msg.value is less than the quoted cross-chain fee
     * @custom:throws OnlyEtherFiSafe If the calling safe is not a valid EtherFiSafe
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function stake(address safe, uint256 amountToStake, address signer, bytes calldata signature) external payable onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getStakeDigestHash(safe, amountToStake);
        _verifyAdminSig(digestHash, signer, signature);
        _stake(safe, amountToStake);
    }

    /**
     * @notice Sets the gas limit used when refunding excess fees
     * @dev Setting the gas limit to zero resets it back to the default value
     * @param refundGasLimit The gas limit to use when refunding excess fees
     * @custom:throws Unauthorized If the caller lacks the module admin role
     */
    function setRefundGasLimit(uint32 refundGasLimit) external {
        IRoleRegistry roleRegistry = IRoleRegistry(etherFiDataProvider.roleRegistry());
        if (!roleRegistry.hasRole(BEHYPE_STAKE_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();

        _getBeHYPEStakeModuleStorage().refundGasLimit = refundGasLimit;
        emit RefundGasLimitUpdated(refundGasLimit);
    }

    /**
     * @notice Returns the gas limit used when refunding excess fees
     * @return Gas limit configured for the module, falling back to the default when unset
     */
    function getRefundGasLimit() public view returns (uint32) {
        return _getBeHYPEStakeModuleStorage().refundGasLimit;
    }

    /**
     * @dev Creates a digest hash for the stake operation
     * @param safe The Safe address which holds the tokens
     * @param amountToStake The amount to stake
     * @return The digest hash for signature verification
     */
    function _getStakeDigestHash(address safe, uint256 amountToStake) internal returns (bytes32) {
        return keccak256(abi.encodePacked(STAKE_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(amountToStake))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function to stake WHYPE tokens
     * @param safe The Safe address which holds the tokens
     * @param amountToStake The amount of WHYPE tokens to stake
     * @custom:throws InvalidInput If amountToStake is zero
     * @custom:throws InsufficientFee If msg.value is less than the quoted cross-chain fee
     */
    function _stake(address safe, uint256 amountToStake) internal {
        if (amountToStake == 0) revert InvalidInput();
        _checkAmountAvailable(safe, whype, amountToStake);

        uint256 quotedFee = staker.quoteStake(amountToStake, safe);
        if (msg.value < quotedFee) revert InsufficientFee();

        Address.sendValue(payable(safe), quotedFee);

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = whype;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(staker), amountToStake);

        to[1] = address(staker);
        values[1] = quotedFee;
        data[1] = abi.encodeWithSelector(IL2BeHYPEOAppStaker.stake.selector, amountToStake, safe);

        to[2] = whype;
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, address(staker), 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 excessFee = msg.value - quotedFee;
        if (excessFee > 0) {
            _refundExcessFee(msg.sender, excessFee);
        }

        emit StakeDeposit(safe, whype, beHYPE, amountToStake);
    }

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the BeHYPEStakeModuleStorage struct
     */
    function _getBeHYPEStakeModuleStorage() internal pure returns (BeHYPEStakeModuleStorage storage $) {
        assembly {
            $.slot := BeHYPEStakeModuleStorageLocation
        }
    }

    /**
     * @dev Refunds excess fees to the caller using a limited amount of gas
     * @param refundRecipient The address receiving the refund
     * @param amount The amount of ETH to refund
     */
    function _refundExcessFee(address refundRecipient, uint256 amount) internal {
        (bool success, ) = payable(refundRecipient).call{ value: amount, gas: getRefundGasLimit() }("");
        if (!success) revert RefundFailed();
    }
}

