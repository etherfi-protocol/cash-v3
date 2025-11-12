// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableRoles } from "solady/auth/EnumerableRoles.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICCTPTokenMessenger } from "../interfaces/ICCTPTokenMessenger.sol";

/**
 * @title PixWalletAutoTopup
 * @notice A contract that allows to bridge USDC via CCTP to the Pix wallet on the Base
 * @author ether.fi
 */
contract PixWalletAutoTopup is UUPSUpgradeable, EnumerableRoles, Ownable {
    using SafeERC20 for IERC20;

    /**
     * @notice The destination domain ID for the Base network
     */
    uint32 public constant CCTP_DEST_DOMAIN_BASE = 6;

    /**
     * @notice The address of the USDC token
     */
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /**
     * @notice The address of the CCTP TokenMessenger contract
     */
    address public constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d; 
    /**
     * @notice The maximum fee to pay on the destination domain when bridging tokens via CCTP
     */
    uint256 public constant CCTP_MAX_FEE = 0; 
    /**
     * @notice The minimum finality threshold for the CCTP TokenMessenger contract
     */
    uint32 public constant CCTP_MIN_FINALITY_THRESHOLD = 2000;
    
    /**
     * @notice The address of the Pix wallet on the Base network
     */
    address public pixWalletOnBase;

    /**
     * @notice Emitted when tokens are bridged via CCTP
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param destinationDomain The destination domain ID
     * @param mintRecipient The address of the recipient on the Base network
     */
    event BridgeViaCCTP(address token, uint256 amount, uint32 destinationDomain, bytes32 mintRecipient);

    /**
     * @notice Error thrown when the input is invalid
     */
    error InvalidInput();

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param _owner The address of the owner of the contract
     * @param _pixWalletOnBase The address of the Pix wallet on the Base network
     */
    function initialize(address _owner, address _pixWalletOnBase) external initializer {
        if (_owner == address(0) || _pixWalletOnBase == address(0)) revert InvalidInput();
        _initializeOwner(_owner);
        __UUPSUpgradeable_init();
        pixWalletOnBase = _pixWalletOnBase;
    }

    /**
     * @notice Sets the Pix wallet on the Base network
     * @param _pixWalletOnBase The address of the Pix wallet on the Base network
     */
    function setPixWalletOnBase(address _pixWalletOnBase) external onlyOwner {
        if (_pixWalletOnBase == address(0)) revert InvalidInput();
        pixWalletOnBase = _pixWalletOnBase;
    }

    /**
     * @notice Bridges USDC via CCTP to the Pix wallet on the Base network
     * @param amount The amount of USDC to bridge
     */
    function bridgeViaCCTP(uint256 amount) external {
        uint256 balance = IERC20(USDC).balanceOf(address(this));
        if (amount > balance) amount = balance;

        IERC20(USDC).forceApprove(CCTP_TOKEN_MESSENGER, amount);
        bytes32 mintRecipient = bytes32(uint256(uint160(pixWalletOnBase)));

        ICCTPTokenMessenger(CCTP_TOKEN_MESSENGER).depositForBurn(
            amount,
            CCTP_DEST_DOMAIN_BASE,
            mintRecipient,
            USDC,
            bytes32(0),
            CCTP_MAX_FEE,
            CCTP_MIN_FINALITY_THRESHOLD
        );

        emit BridgeViaCCTP(USDC, amount, CCTP_DEST_DOMAIN_BASE, mintRecipient);
    }

    /**
     * @notice Returns the maximum allowed role value
     * @dev This is used by EnumerableRoles._validateRole to ensure roles are within valid range
     * @return uint256 The maximum role value
    */
    function MAX_ROLE() public pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract
     * @param newImplementation Address of the new implementation contract
     * @custom:throws Unauthorized if the caller is not the contract owner
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner { }
}