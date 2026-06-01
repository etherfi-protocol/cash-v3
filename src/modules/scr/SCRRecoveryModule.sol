// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title SCRRecoveryModule
 * @author ether.fi
 * @notice Default module that pulls SCR left behind on Scroll out of opted-in user
 *         safes into a single collection wallet. The equivalent USDC is credited
 *         off-chain on Optimism; this module only moves SCR on Scroll.
 * @custom:security-contact security@etherfi.io
 */
contract SCRRecoveryModule is UpgradeableProxy {
    /// @notice Interface for accessing protocol data (safe registry)
    IEtherFiDataProvider public immutable dataProvider;

    /// @notice The SCR token on Scroll being recovered
    IERC20 public constant scr = IERC20(0xd29687c813D741E2F938F4aC377128810E217b1b);

    /// @notice Role required to call {collect} (the ether.fi backend wallet)
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    /// @notice Role required to configure the module (set the collection wallet)
    bytes32 public constant SCR_RECOVERY_ADMIN_ROLE = keccak256("SCR_RECOVERY_ADMIN_ROLE");

    /// @custom:storage-location erc7201:etherfi.storage.SCRRecoveryModule
    struct SCRRecoveryModuleStorage {
        /// @notice Destination that receives all recovered SCR
        address collectionWallet;
        /// @notice Tracks safes whose SCR has already been collected (idempotency)
        mapping(address safe => bool collected) collected;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.SCRRecoveryModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SCRRecoveryModuleStorageLocation = 0x48702ffefb46d28cd835e1b43352967b21f955b3a2f93f2a0a50cd2f4b484a00;

    /**
     * @notice Emitted when the collection wallet is set
     * @param collectionWallet Address that will receive recovered SCR
     */
    event CollectionWalletSet(address indexed collectionWallet);

    /**
     * @notice Emitted when a safe's SCR is recovered into the collection wallet
     * @param safe Address of the user's safe
     * @param amount Amount of SCR transferred out of the safe
     * @param collectionWallet Address that received the SCR
     */
    event SCRCollected(address indexed safe, uint256 amount, address indexed collectionWallet);

    /// @notice Thrown when the caller does not have ETHER_FI_WALLET_ROLE
    error OnlyEtherFiWallet();
    /// @notice Thrown when the caller does not have SCR_RECOVERY_ADMIN_ROLE
    error OnlyAdmin();
    /// @notice Thrown when a provided address is not a registered EtherFi Safe
    error NotEtherFiSafe();
    /// @notice Thrown when an input is invalid (zero address / empty array)
    error InvalidInput();
    /// @notice Thrown when {collect} is called before a collection wallet is set
    error CollectionWalletNotSet();

    /**
     * @dev Sets the immutable data provider and disables initializers on the implementation
     * @param _dataProvider Address of the EtherFiDataProvider contract
     */
    constructor(address _dataProvider) {
        if (_dataProvider == address(0)) revert InvalidInput();
        dataProvider = IEtherFiDataProvider(_dataProvider);
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with a role registry and the collection wallet
     * @param _roleRegistry Address of the role registry contract
     * @param _collectionWallet Address that will receive recovered SCR
     */
    function initialize(address _roleRegistry, address _collectionWallet) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _setCollectionWallet(_collectionWallet);
    }

    /**
     * @dev Returns the namespaced storage struct
     * @return $ Reference to SCRRecoveryModuleStorage
     */
    function _getSCRRecoveryModuleStorage() internal pure returns (SCRRecoveryModuleStorage storage $) {
        assembly {
            $.slot := SCRRecoveryModuleStorageLocation
        }
    }

    /**
     * @notice Returns the collection wallet that receives recovered SCR
     */
    function collectionWallet() external view returns (address) {
        return _getSCRRecoveryModuleStorage().collectionWallet;
    }

    /**
     * @notice Returns whether a safe's SCR has already been collected
     * @param safe Address of the safe to query
     */
    function hasCollected(address safe) external view returns (bool) {
        return _getSCRRecoveryModuleStorage().collected[safe];
    }

    /**
     * @notice Sets the collection wallet that receives recovered SCR
     * @dev Only callable by accounts with SCR_RECOVERY_ADMIN_ROLE
     * @param _collectionWallet New collection wallet address
     * @custom:throws OnlyAdmin if the caller lacks SCR_RECOVERY_ADMIN_ROLE
     * @custom:throws InvalidInput if _collectionWallet is the zero address
     */
    function setCollectionWallet(address _collectionWallet) external {
        if (!dataProvider.roleRegistry().hasRole(SCR_RECOVERY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        _setCollectionWallet(_collectionWallet);
    }

    /**
     * @notice Recovers SCR from one or more opted-in safes into the collection wallet
     * @dev Only callable by accounts with ETHER_FI_WALLET_ROLE. Opt-in is captured
     *      off-chain; the backend must only pass safes that have accepted the terms.
     *      Safes with no SCR balance, or whose SCR has already been collected, are
     *      skipped so a single bad entry never reverts the whole batch.
     * @param safes Array of EtherFi Safe addresses to recover SCR from
     * @custom:throws OnlyEtherFiWallet if the caller lacks ETHER_FI_WALLET_ROLE
     * @custom:throws InvalidInput if the safes array is empty
     * @custom:throws CollectionWalletNotSet if no collection wallet is configured
     * @custom:throws NotEtherFiSafe if any address is not a registered EtherFi Safe
     */
    function collect(address[] calldata safes) external nonReentrant {
        if (!dataProvider.roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        if (safes.length == 0) revert InvalidInput();

        address _collectionWallet = _getSCRRecoveryModuleStorage().collectionWallet;
        if (_collectionWallet == address(0)) revert CollectionWalletNotSet();

        for (uint256 i = 0; i < safes.length;) {
            _collect(safes[i], _collectionWallet);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Recovers SCR from a single safe. Skips safes that have already been
     *      collected or that hold no SCR.
     * @param safe Address of the EtherFi Safe
     * @param _collectionWallet Destination for the recovered SCR
     */
    function _collect(address safe, address _collectionWallet) internal {
        if (!dataProvider.isEtherFiSafe(safe)) revert NotEtherFiSafe();

        SCRRecoveryModuleStorage storage $ = _getSCRRecoveryModuleStorage();
        if ($.collected[safe]) return;

        uint256 balance = scr.balanceOf(safe);
        if (balance == 0) return;

        $.collected[safe] = true;

        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        to[0] = address(scr);
        data[0] = abi.encodeWithSelector(IERC20.transfer.selector, _collectionWallet, balance);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit SCRCollected(safe, balance, _collectionWallet);
    }

    /**
     * @dev Internal setter for the collection wallet
     * @param _collectionWallet New collection wallet address
     */
    function _setCollectionWallet(address _collectionWallet) internal {
        if (_collectionWallet == address(0)) revert InvalidInput();
        _getSCRRecoveryModuleStorage().collectionWallet = _collectionWallet;
        emit CollectionWalletSet(_collectionWallet);
    }
}
