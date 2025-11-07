// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { IL2BeHYPEOAppStaker } from "../../interfaces/IL2BeHYPEOAppStaker.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";

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

    event StakeDeposit(address indexed safe, address indexed inputAsset, address indexed outputAsset, uint256 inputAmount);

    /// @notice Thrown when the provided fee is insufficient for the cross-chain transaction
    error InsufficientFee();

    /**
     * @notice Contract constructor
     * @param _dataProvider Address of the EtherFiDataProvider contract
     * @param _staker Address of the L2BeHYPEOAppStaker contract
     * @param _whype Address of the WHYPE token contract
     * @param _beHYPE Address of the beHYPE token contract
     * @dev Initializes the contract with required contract references
     */
    constructor(address _dataProvider, address _staker, address _whype, address _beHYPE) ModuleBase(_dataProvider) ModuleCheckBalance(_dataProvider) {
        if (_staker == address(0) || _whype == address(0) || _beHYPE == address(0)) revert InvalidInput();
        staker = IL2BeHYPEOAppStaker(_staker);
        whype = _whype;
        beHYPE = _beHYPE;
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
            Address.sendValue(payable(msg.sender), excessFee);
        }

        emit StakeDeposit(safe, whype, beHYPE, amountToStake);
    }
}

