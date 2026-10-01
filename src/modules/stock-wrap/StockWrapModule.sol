// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title StockWrapModule
 * @notice Wraps raw stock sitting in a safe into its ERC-4626 wrapper, credited to the same safe. Keeper driven;
 *         nothing here needs a user signature.
 * @dev A default module (it drives `execTransactionFromModule` on any safe) and nothing more: it never holds
 *      tokens and never touches the safe's lend position. The wrapper stays loose in the safe for the lend
 *      sweep to supply. Only the balance net of pending withdrawals is wrapped.
 * @author ether.fi
 */
contract StockWrapModule is ModuleBase, ModuleCheckBalance, UpgradeableProxy {
    /// @custom:storage-location erc7201:etherfi.storage.StockWrapModule
    struct StockWrapModuleStorage {
        /// @notice Wrapper each raw stock is deposited into
        mapping(address raw => address wrapper) wrapPairs;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockWrapModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockWrapModuleStorageLocation = 0x6b563e72367a90aa1f226d57839ae0b7fea2bc078b9e3d85a77763d4baef7200;

    /// @notice Role that runs the wraps
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    event WrapPairSet(address indexed raw, address indexed wrapper);
    event Wrapped(address indexed safe, address indexed raw, address indexed wrapper, uint256 amount, uint256 shares);
    event WrapSkipped(address indexed safe, address indexed raw, bytes reason);

    error OnlySelf();
    error PairNotSet();
    error InvalidWrapperAsset();
    error NothingToWrap();
    error WrapMintedNothing();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _disableInitializers();
    }

    /// @notice Sets up the proxy with the role registry that gates admin, keeper and pause calls
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Sets the wrapper each raw stock is deposited into; a zero wrapper removes the pair
     * @param raws Raw stock tokens
     * @param wrappers Wrapper per raw stock; must report the raw stock as its asset
     */
    function setWrapPairs(address[] calldata raws, address[] calldata wrappers) external onlyAdminTimelock {
        uint256 len = raws.length;
        if (len != wrappers.length) revert ArrayLengthMismatch();
        StockWrapModuleStorage storage $ = _getStockWrapModuleStorage();

        for (uint256 i = 0; i < len; ++i) {
            if (raws[i] == address(0)) revert InvalidInput();
            if (wrappers[i] != address(0) && IERC4626(wrappers[i]).asset() != raws[i]) revert InvalidWrapperAsset();
            $.wrapPairs[raws[i]] = wrappers[i];
            emit WrapPairSet(raws[i], wrappers[i]);
        }
    }

    /**
     * @notice Wraps the raw stock a safe holds, net of pending withdrawals, into its wrapper, credited to the safe
     * @param safe The safe holding raw stock
     * @param raw The raw stock token
     * @return Wrapper shares the safe received
     */
    function wrap(address safe, address raw) external whenNotPaused nonReentrant onlyRole(ETHER_FI_WALLET_ROLE) onlyEtherFiSafe(safe) returns (uint256) {
        return _wrap(safe, raw);
    }

    /**
     * @notice Wraps raw stock in many safes; a safe that fails is skipped with its reason
     * @param safes The safes holding raw stock
     * @param raw The raw stock token
     * @return How many safes were wrapped in this call
     */
    function wrapMany(address[] calldata safes, address raw) external whenNotPaused nonReentrant onlyRole(ETHER_FI_WALLET_ROLE) returns (uint256) {
        uint256 wrapped;
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

    /// @notice The wrapper a raw stock is wrapped into, zero if none is set
    function wrapPairFor(address raw) external view returns (address) {
        return _getStockWrapModuleStorage().wrapPairs[raw];
    }

    /// @dev Has the safe deposit its available raw stock into the wrapper and returns the shares it received
    function _wrap(address safe, address raw) internal returns (uint256) {
        address wrapper = _getStockWrapModuleStorage().wrapPairs[raw];
        if (wrapper == address(0)) revert PairNotSet();

        uint256 amount = _getAvailableAmount(safe, raw);
        if (amount == 0) revert NothingToWrap();

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

        emit Wrapped(safe, raw, wrapper, amount, shares);
        return shares;
    }

    /// @dev The module's ERC-7201 storage
    function _getStockWrapModuleStorage() private pure returns (StockWrapModuleStorage storage $) {
        assembly {
            $.slot := StockWrapModuleStorageLocation
        }
    }
}
