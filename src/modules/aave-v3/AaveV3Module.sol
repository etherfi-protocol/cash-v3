// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IAavePoolV3 } from "../../interfaces/IAavePoolV3.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title AaveV3Module
 * @author ether.fi
 * @notice Module for interacting with Aave V3 Protocol from a Safe
 * @dev Extends ModuleBase to provide Aave V3 integration for Safes
 */
contract AaveV3Module is ModuleBase {
    using MessageHashUtils for bytes32;

    /// @notice Aave V3 Pool contract interface
    IAavePoolV3 public immutable aaveV3Pool;

    /// @notice TypeHash for supply function signature
    bytes32 public constant SUPPLY_SIG = keccak256("supply");

    /// @notice Thrown when the Safe doesn't have sufficient token balance
    error InsufficientBalanceOnSafe();

    /**
     * @notice Contract constructor
     * @param _aavePool Address of the Aave V3 Pool contract
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     */
    constructor(address _aavePool, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        if (_aavePool == address(0)) revert InvalidInput();
        aaveV3Pool = IAavePoolV3(_aavePool);
    }

    /**
     * @notice Supply tokens to Aave V3 Pool using admin privileges
     * @param safe The Safe address which holds the tokens
     * @param asset The address of the ERC20 token to be supplied
     * @param amount The amount of tokens to be supplied
     * @dev Executes token approval and supply through the Safe's module execution
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     */
    function supplyAdmin(address safe, address asset, uint256 amount) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, msg.sender) {
        _supply(safe, asset, amount);
    }

    /**
     * @notice Supply tokens to Aave V3 Pool using signature verification
     * @param safe The Safe address which holds the tokens
     * @param asset The address of the ERC20 token to be supplied
     * @param amount The amount of tokens to be supplied
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and supply through the Safe's module execution
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     */
    function supplyWithSignature(address safe, address asset, uint256 amount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encode(SUPPLY_SIG, block.chainid, address(this), _useNonce(safe), safe, asset, amount)).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _supply(safe, asset, amount);
    }

    function _supply(address safe, address asset, uint256 amount) internal {
        if (IERC20(asset).balanceOf(safe) < amount) revert InsufficientBalanceOnSafe();

        address[] memory to = new address[](2);
        to[0] = asset;
        to[1] = address(aaveV3Pool);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(aaveV3Pool), amount);
        data[1] = abi.encodeWithSelector(IAavePoolV3.supply.selector, asset, amount, address(0), 0);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }
}
