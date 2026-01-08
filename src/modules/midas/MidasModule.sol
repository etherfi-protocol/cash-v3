// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IMidasVault } from "../../interfaces/IMidasVault.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title MidasModule
 * @author ether.fi
 * @notice Module for interacting with Midas Vaults
 * @dev Extends ModuleBase to provide Midas Vault integration for Safes
 */
contract MidasModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient {
    using MessageHashUtils for bytes32;
    using SafeCast for uint256;

    /// @notice Vault configuration for a Midas token
    struct MidasVaultConfig {
        address depositVault;
        address redemptionVault;
    }

    /// @notice Mapping from Midas token to vault configuration
    mapping(address midasToken => MidasVaultConfig config) public vaults;

    /// @notice TypeHash for deposit function signature
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");

    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    /// @notice Role identifier for admins of the Midas Module
    bytes32 public constant MIDAS_MODULE_ADMIN = keccak256("MIDAS_MODULE_ADMIN");

    /// @notice Emitted when new Midas vaults are added to the module
    event MidasVaultsAdded(address[] midasTokens, address[] depositVaults, address[] redemptionVaults);

    /// @notice Emitted when Midas vaults are removed
    event MidasVaultsRemoved(address[] midasTokens);

    /// @notice Emitted when a Safe deposits assets into a Midas Vault
    event Deposit(address indexed safe, address indexed inputToken, uint256 inputAmount, address indexed outputToken, uint256 outputAmount);

    /// @notice Emitted when a Safe creates an async withdrawal request
    event Withdrawal(address indexed safe, uint256 amount, address asset, address midasToken);

    /// @notice Thrown when return amount is less than minimum required
    error InsufficientReturnAmount();

    /// @notice Thrown when Midas token is not supported by the module
    error UnsupportedMidasToken();

    /// @notice Thrown when caller lacks required authorization
    error Unauthorized();

    /// @notice Thrown when token decimals exceed the maximum allowed (18)
    error InvalidDecimals();

    /**
     * @notice Initializes the contract with Midas vaults and their supported assets
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _midasTokens Array of Midas token addresses to initialize
     * @param _depositVaults Array of deposit vault addresses corresponding to the Midas tokens
     * @param _redemptionVaults Array of redemption vault addresses corresponding to the Midas tokens
     * @custom:throws InvalidInput If any provided address is zero or arrays are empty
     * @custom:throws ArrayLengthMismatch If the lengths of arrays mismatch
     */
    constructor(address _etherFiDataProvider, address[] memory _midasTokens, address[] memory _depositVaults, address[] memory _redemptionVaults) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        uint256 len = _midasTokens.length;
        if (len == 0) revert InvalidInput();
        if (len != _depositVaults.length || len != _redemptionVaults.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            address midasToken = _midasTokens[i];
            address depositVault = _depositVaults[i];
            address redemptionVault = _redemptionVaults[i];

            if (midasToken == address(0) || depositVault == address(0) || redemptionVault == address(0)) revert InvalidInput();

            vaults[midasToken] = MidasVaultConfig({ depositVault: depositVault, redemptionVault: redemptionVault });

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Deposits assets and mints MidasToken using signature verification
     * @param safe The Safe address which holds the deposit tokens
     * @param asset The address of the asset to deposit
     * @param midasToken The address of the Midas token to receive
     * @param amount The amount of tokens to deposit
     * @param minReturnAmount The minimum amount of tokens to return (in midasToken decimals)
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @custom:throws InvalidInput If amount is zero or addresses are invalid
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws UnsupportedMidasToken If the Midas token is not supported
     * @custom:throws InsufficientReturnAmount If the MidasToken received is less than expected
     */
    function deposit(address safe, address asset, address midasToken, uint256 amount, uint256 minReturnAmount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, asset, midasToken, amount, minReturnAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, asset, midasToken, amount, minReturnAmount);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address
     * @param asset The asset to deposit
     * @param midasToken The Midas token to receive
     * @param amount The amount to deposit
     * @param minReturnAmount The minimum amount to return
     * @return The digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, address asset, address midasToken, uint256 amount, uint256 minReturnAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(asset, midasToken, amount, minReturnAmount))).toEthSignedMessageHash();
    }

    /**
     * @dev Scales an amount from source token decimals to target token decimals
     * @param amount The amount to scale
     * @param sourceToken The token address to get source decimals from
     * @param targetToken The token address to get target decimals from
     * @return The scaled amount
     * @custom:throws InvalidDecimals If either token has decimals greater than 18
     */
    function _scaleAmount(uint256 amount, address sourceToken, address targetToken) internal view returns (uint256) {
        uint8 sourceDecimals = ERC20(sourceToken).decimals();
        uint8 targetDecimals = ERC20(targetToken).decimals();

        if (sourceDecimals > 18 || targetDecimals > 18) revert InvalidDecimals();

        if (sourceDecimals == targetDecimals) return amount;
        if (sourceDecimals < targetDecimals) {
            return amount * 10 ** (targetDecimals - sourceDecimals);
        } else {
            return amount / 10 ** (sourceDecimals - targetDecimals);
        }
    }

    /**
     * @dev Internal function to deposit assets and mint MidasToken
     * @param safe The Safe address which holds the deposit tokens
     * @param asset The address of the asset to deposit
     * @param midasToken The address of the Midas token to receive
     * @param amount The amount of deposit tokens to deposit (in asset decimals)
     * @param minReturnAmount The minimum amount of tokens to return (in midasToken decimals)
     * @custom:throws InvalidInput If amount is zero or addresses are invalid
     * @custom:throws UnsupportedMidasToken If the Midas token is not supported
     * @custom:throws InsufficientReturnAmount If the MidasToken received is less than expected
     */
    function _deposit(address safe, address asset, address midasToken, uint256 amount, uint256 minReturnAmount) internal {
        if (amount == 0 || midasToken == address(0) || asset == address(0)) revert InvalidInput();

        address depositVault = vaults[midasToken].depositVault;
        if (depositVault == address(0)) revert UnsupportedMidasToken();

        uint256 scaledAmount = _scaleAmount(amount, asset, midasToken);
        _checkAmountAvailable(safe, asset, amount);

        uint256 midasTokenBefore = ERC20(midasToken).balanceOf(safe);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = asset;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, depositVault, amount);
        to[1] = depositVault;
        data[1] = abi.encodeWithSelector(IMidasVault.depositInstant.selector, asset, scaledAmount, minReturnAmount, bytes32(bytes20(address(0))));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 midasTokenReceived = ERC20(midasToken).balanceOf(safe) - midasTokenBefore;
        if (midasTokenReceived < minReturnAmount) revert InsufficientReturnAmount();

        emit Deposit(safe, asset, amount, midasToken, midasTokenReceived);
    }

    /**
     * @notice Creates a withdrawal request for a Midas token
     * @param safe The Safe address which holds the Midas tokens
     * @param midasToken The address of the Midas token to withdraw
     * @param amount The amount of Midas Token to withdraw (in midasToken decimals)
     * @param asset The asset to withdraw to
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @custom:throws InvalidInput If amount is zero or addresses are invalid
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws UnsupportedMidasToken If the Midas token is not supported
     * @dev Note: This creates an async withdrawal request via redeemRequest. The actual withdrawal completion is handled by the Midas vault.
     */
    function withdraw(address safe, address midasToken, uint128 amount, address asset, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getWithdrawDigestHash(safe, midasToken, amount, asset);
        _verifyAdminSig(digestHash, signer, signature);
        _withdraw(safe, midasToken, amount, asset);
    }

    /**
     * @dev Creates a digest hash for the withdraw operation
     * @param safe The Safe address
     * @param midasToken The Midas token to withdraw
     * @param amount The amount to withdraw (in midasToken decimals)
     * @param asset The asset to withdraw to
     * @return The digest hash for signature verification
     */
    function _getWithdrawDigestHash(address safe, address midasToken, uint128 amount, address asset) internal returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(midasToken, amount, asset))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function which facilitates withdrawals from the safe
     * @param safe The Safe address which holds the Midas tokens
     * @param midasToken The address of the Midas token to withdraw
     * @param amount The amount of Midas Token to withdraw (in midasToken decimals)
     * @param asset The asset to withdraw to
     * @custom:throws InvalidInput If amount is zero or addresses are invalid
     * @custom:throws UnsupportedMidasToken If the Midas token is not supported
     * @dev Note: This creates an async withdrawal request. The Midas vault will handle the actual redemption.
     */
    function _withdraw(address safe, address midasToken, uint128 amount, address asset) internal {
        if (amount == 0 || asset == address(0) || midasToken == address(0)) revert InvalidInput();

        MidasVaultConfig memory vaultConfig = vaults[midasToken];
        address redemptionVault = vaultConfig.redemptionVault;
        if (redemptionVault == address(0)) revert UnsupportedMidasToken();

        _checkAmountAvailable(safe, midasToken, amount);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = midasToken;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, redemptionVault, amount);

        to[1] = redemptionVault;
        data[1] = abi.encodeWithSelector(IMidasVault.redeemRequest.selector, asset, amount, safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        emit Withdrawal(safe, amount, asset, midasToken);
    }

    /**
     * @notice Adds new Midas vaults to the module
     * @param midasTokens Array of Midas token addresses to add
     * @param depositVaults Array of deposit vault addresses corresponding to the Midas tokens
     * @param redemptionVaults Array of redemption vault addresses corresponding to the Midas tokens
     * @dev Only callable by accounts with the MIDAS_MODULE_ADMIN role
     * @custom:throws Unauthorized If caller doesn't have the admin role
     * @custom:throws ArrayLengthMismatch If the lengths of arrays mismatch
     * @custom:throws InvalidInput If any provided address is zero or the array is empty
     */
    function addMidasVaults(address[] calldata midasTokens, address[] calldata depositVaults, address[] calldata redemptionVaults) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(MIDAS_MODULE_ADMIN, msg.sender)) revert Unauthorized();

        uint256 len = midasTokens.length;
        if (len != depositVaults.length || len != redemptionVaults.length) revert ArrayLengthMismatch();
        if (len == 0) revert InvalidInput();

        for (uint256 i = 0; i < len;) {
            address midasToken = midasTokens[i];
            address depositVault = depositVaults[i];
            address redemptionVault = redemptionVaults[i];

            if (midasToken == address(0) || depositVault == address(0) || redemptionVault == address(0)) revert InvalidInput();

            vaults[midasToken] = MidasVaultConfig({ depositVault: depositVault, redemptionVault: redemptionVault });

            unchecked {
                ++i;
            }
        }

        emit MidasVaultsAdded(midasTokens, depositVaults, redemptionVaults);
    }

    /**
     * @notice Removes Midas vaults from the module
     * @param midasTokens Array of Midas token addresses to remove
     * @dev Only callable by accounts with the MIDAS_MODULE_ADMIN role
     * @custom:throws Unauthorized If caller doesn't have the admin role
     * @custom:throws InvalidInput If the array is empty
     */
    function removeMidasVaults(address[] calldata midasTokens) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(MIDAS_MODULE_ADMIN, msg.sender)) revert Unauthorized();

        uint256 len = midasTokens.length;
        if (len == 0) revert InvalidInput();

        for (uint256 i = 0; i < len;) {
            delete vaults[midasTokens[i]];
            unchecked {
                ++i;
            }
        }

        emit MidasVaultsRemoved(midasTokens);
    }
}
