// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../modules/ModuleCheckBalance.sol";
import { ModuleLendGatewaySandwich } from "../modules/ModuleLendGatewaySandwich.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title StockMigrationModule
 * @notice Moves a safe's stock from a stand-in token to Backed's ERC-4626 wrapper on this chain, one safe at a
 *         time and 1:1, out of a pot of wrapper seeded here. Stock the safe has supplied to Aave is swapped in
 *         place: the wrapper is supplied first and the stand-in withdrawn second, so collateral never dips.
 *         Stand-in held loose in the safe is replaced directly. The same module wraps raw stock sitting in a
 *         safe into its wrapper. Both jobs are keeper driven; nothing here needs a user signature.
 * @dev A default module (it drives `execTransactionFromModule` on any safe) and a lend gateway driver (it moves
 *      the safe's Aave position). Every call leaves the safe holding wrapper for exactly the stand-in or raw
 *      stock it gave up, and the gateway's not-worsened health check closes the Aave leg. A safe with a pending
 *      withdrawal of the stand-in, or opted out of lend with a supplied position, is refused so the keeper can
 *      handle it by hand. Collected stand-ins and unused seed leave only through the admin sweep.
 * @author ether.fi
 */
contract StockMigrationModule is ModuleBase, ModuleCheckBalance, ModuleLendGatewaySandwich, UpgradeableProxy {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:etherfi.storage.StockMigrationModule
    struct StockMigrationModuleStorage {
        /// @notice Wrapper paid out for each stand-in token
        mapping(address standIn => address wrapper) swapPairs;
        /// @notice Wrapper each raw stock is deposited into
        mapping(address raw => address wrapper) wrapPairs;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockMigrationModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockMigrationModuleStorageLocation = 0x8e53134b5f30830a21a79ee07e1b8fd9da4539c386018f3a5fde30e4e19be400;

    /// @notice Role that sets pairs and sweeps this contract's balances
    bytes32 public constant STOCK_MIGRATION_MODULE_ADMIN_ROLE = keccak256("STOCK_MIGRATION_MODULE_ADMIN_ROLE");
    /// @notice Role that runs the swaps and wraps
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    event SwapPairSet(address indexed standIn, address indexed wrapper);
    event WrapPairSet(address indexed raw, address indexed wrapper);
    event Migrated(address indexed safe, address indexed standIn, address indexed wrapper, uint256 supplied, uint256 loose);
    event MigrateSkipped(address indexed safe, address indexed standIn, bytes reason);
    event Wrapped(address indexed safe, address indexed raw, address indexed wrapper, uint256 amount, uint256 shares);
    event WrapSkipped(address indexed safe, address indexed raw, bytes reason);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error OnlySelf();
    error PairNotSet();
    error InvalidWrapperAsset();
    error PendingWithdrawal();
    error LendOptedOut();
    error NothingToMigrate();
    error InsufficientSeed();
    error WrapMintedNothing();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    // ---- Admin ----

    /**
     * @notice Sets the wrapper paid out for each stand-in token; a zero wrapper removes the pair
     * @param standIns Stand-in tokens
     * @param wrappers Wrapper per stand-in
     */
    function setSwapPairs(address[] calldata standIns, address[] calldata wrappers) external onlyRole(STOCK_MIGRATION_MODULE_ADMIN_ROLE) {
        uint256 len = standIns.length;
        if (len != wrappers.length) revert ArrayLengthMismatch();
        StockMigrationModuleStorage storage $ = _getStockMigrationModuleStorage();

        for (uint256 i = 0; i < len; ++i) {
            if (standIns[i] == address(0)) revert InvalidInput();
            $.swapPairs[standIns[i]] = wrappers[i];
            emit SwapPairSet(standIns[i], wrappers[i]);
        }
    }

    /**
     * @notice Sets the wrapper each raw stock is deposited into; a zero wrapper removes the pair
     * @param raws Raw stock tokens
     * @param wrappers Wrapper per raw stock; must report the raw stock as its asset
     */
    function setWrapPairs(address[] calldata raws, address[] calldata wrappers) external onlyRole(STOCK_MIGRATION_MODULE_ADMIN_ROLE) {
        uint256 len = raws.length;
        if (len != wrappers.length) revert ArrayLengthMismatch();
        StockMigrationModuleStorage storage $ = _getStockMigrationModuleStorage();

        for (uint256 i = 0; i < len; ++i) {
            if (raws[i] == address(0)) revert InvalidInput();
            if (wrappers[i] != address(0) && IERC4626(wrappers[i]).asset() != raws[i]) revert InvalidWrapperAsset();
            $.wrapPairs[raws[i]] = wrappers[i];
            emit WrapPairSet(raws[i], wrappers[i]);
        }
    }

    /**
     * @notice Sends this contract's balance of a token to `to`: collected stand-ins or unused seed
     * @param token Token to sweep
     * @param to Recipient
     * @param amount Amount, 0 for the whole balance
     */
    function sweep(address token, address to, uint256 amount) external onlyRole(STOCK_MIGRATION_MODULE_ADMIN_ROLE) {
        if (to == address(0)) revert InvalidInput();
        if (amount == 0) amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // ---- Keeper ----

    /**
     * @notice Swaps one safe's stand-in token for its wrapper, 1:1, supplied position first and loose balance second
     * @param safe The safe to migrate
     * @param standIn The stand-in token to replace
     * @return supplied Amount swapped inside the safe's Aave position
     * @return loose Amount swapped in the safe's wallet
     */
    function migrate(address safe, address standIn) external whenNotPaused nonReentrant onlyRole(ETHER_FI_WALLET_ROLE) onlyEtherFiSafe(safe) returns (uint256 supplied, uint256 loose) {
        return _migrate(safe, standIn);
    }

    /**
     * @notice Swaps many safes; a safe that fails is skipped with its reason so the batch finishes
     * @param safes The safes to migrate
     * @param standIn The stand-in token to replace
     * @return migrated How many safes were swapped in this call
     */
    function migrateMany(address[] calldata safes, address standIn) external whenNotPaused nonReentrant onlyRole(ETHER_FI_WALLET_ROLE) returns (uint256 migrated) {
        uint256 len = safes.length;
        for (uint256 i = 0; i < len; ++i) {
            try this.migrateSelf(safes[i], standIn) {
                ++migrated;
            } catch (bytes memory reason) {
                emit MigrateSkipped(safes[i], standIn, reason);
            }
        }
        return migrated;
    }

    /// @dev Self-call target for migrateMany's try/catch; nothing else may call it
    function migrateSelf(address safe, address standIn) external onlyEtherFiSafe(safe) returns (uint256, uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _migrate(safe, standIn);
    }

    /**
     * @notice Wraps the raw stock a safe holds loose into its wrapper, credited to the safe, then supplies it to Aave
     * @param safe The safe holding raw stock
     * @param raw The raw stock token
     * @return shares Wrapper shares the safe received
     */
    function wrap(address safe, address raw) external whenNotPaused nonReentrant onlyRole(ETHER_FI_WALLET_ROLE) onlyEtherFiSafe(safe) returns (uint256 shares) {
        return _wrap(safe, raw);
    }

    /**
     * @notice Wraps raw stock in many safes; a safe that fails is skipped with its reason
     * @param safes The safes holding raw stock
     * @param raw The raw stock token
     * @return wrapped How many safes were wrapped in this call
     */
    function wrapMany(address[] calldata safes, address raw) external whenNotPaused nonReentrant onlyRole(ETHER_FI_WALLET_ROLE) returns (uint256 wrapped) {
        uint256 len = safes.length;
        for (uint256 i = 0; i < len; ++i) {
            try this.wrapSelf(safes[i], raw) {
                ++wrapped;
            } catch (bytes memory reason) {
                emit WrapSkipped(safes[i], raw, reason);
            }
        }
        return wrapped;
    }

    /// @dev Self-call target for wrapMany's try/catch; nothing else may call it
    function wrapSelf(address safe, address raw) external onlyEtherFiSafe(safe) returns (uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _wrap(safe, raw);
    }

    // ---- Views ----

    function swapPairFor(address standIn) external view returns (address) {
        return _getStockMigrationModuleStorage().swapPairs[standIn];
    }

    function wrapPairFor(address raw) external view returns (address) {
        return _getStockMigrationModuleStorage().wrapPairs[raw];
    }

    // ---- Internals ----

    function _migrate(address safe, address standIn) internal returns (uint256, uint256) {
        address wrapper = _getStockMigrationModuleStorage().swapPairs[standIn];
        if (wrapper == address(0)) revert PairNotSet();
        if (cashModule.getPendingWithdrawalAmount(safe, standIn) != 0) revert PendingWithdrawal();

        uint256 supplied;
        uint256 healthFactorBefore;
        if (_onGatewayEngine(safe)) {
            supplied = gateway().suppliedOf(safe, standIn);
            if (supplied != 0 && cashModule.isLendOptedOut(safe)) revert LendOptedOut();
            healthFactorBefore = _gatewayHealthFactor(safe);
        }
        uint256 loose = IERC20(standIn).balanceOf(safe);
        if (supplied == 0 && loose == 0) revert NothingToMigrate();
        if (IERC20(wrapper).balanceOf(address(this)) < supplied + loose) revert InsufficientSeed();

        if (supplied != 0) {
            // Supply the wrapper before withdrawing the stand-in so the position never loses collateral.
            // The gateway pulls the wrapper from the safe, so it goes there first.
            ILendGateway lendGateway = gateway();
            IERC20(wrapper).safeTransfer(safe, supplied);
            lendGateway.supply(safe, wrapper, supplied);
            lendGateway.withdraw(safe, standIn, supplied, address(this));
        }

        if (loose != 0) {
            // Wrapper lands before the stand-in leaves: a legacy safe's health check runs on the transfer out
            IERC20(wrapper).safeTransfer(safe, loose);
            _safeTransferOut(safe, standIn, loose);
            _resupplyToGateway(safe, wrapper, loose);
        }

        if (supplied != 0) _ensureGatewayFloor(safe, healthFactorBefore);

        emit Migrated(safe, standIn, wrapper, supplied, loose);
        return (supplied, loose);
    }

    function _wrap(address safe, address raw) internal returns (uint256) {
        address wrapper = _getStockMigrationModuleStorage().wrapPairs[raw];
        if (wrapper == address(0)) revert PairNotSet();

        uint256 amount = _getAvailableAmount(safe, raw);
        if (amount == 0) revert NothingToMigrate();

        // The safe approves the wrapper and deposits with itself as receiver, in one module batch
        address[] memory to = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        to[0] = raw;
        data[0] = abi.encodeCall(IERC20.approve, (wrapper, amount));
        to[1] = wrapper;
        data[1] = abi.encodeCall(IERC4626.deposit, (amount, safe));

        uint256 before = IERC20(wrapper).balanceOf(safe);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        uint256 shares = IERC20(wrapper).balanceOf(safe) - before;
        if (shares == 0) revert WrapMintedNothing();

        _resupplyToGateway(safe, wrapper, shares);

        emit Wrapped(safe, raw, wrapper, amount, shares);
        return shares;
    }

    /// @dev Has the safe send `amount` of `token` here
    function _safeTransferOut(address safe, address token, uint256 amount) internal {
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = token;
        data[0] = abi.encodeCall(IERC20.transfer, (address(this), amount));
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    function _getStockMigrationModuleStorage() private pure returns (StockMigrationModuleStorage storage $) {
        assembly {
            $.slot := StockMigrationModuleStorageLocation
        }
    }
}
