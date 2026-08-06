// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IOFT } from "../interfaces/IOFT.sol";
import { EnumerableAddressWhitelistLib } from "../libraries/EnumerableAddressWhitelistLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title StockUnwrapper
 * @author ether.fi
 * @notice Ethereum-side composed receiver for cross-chain wrapped-stock withdrawals. The OP
 *         `StockWithdrawModule` OFT-sends an iTOKEN with this contract as the recipient and a
 *         `composeMsg` carrying `(sourceSafe, recipient, minReturn, deadline)`. The mainnet
 *         OFTAdapter credits the wrapped stock (a Backed ERC-4626 vault, e.g. wSPYx) here, then
 *         the LZ executor calls `lzCompose`:
 *         - before `deadline`: redeem the wrapper to `recipient`; revert `InsufficientReturn`
 *           if the redeemed assets are below `minReturn` (the compose message stays retryable
 *           in LayerZero's queue — tokens wait here until a retry succeeds or expires);
 *         - after `deadline`: transfer the WRAPPED token to `sourceSafe` — the user's safe
 *           address, which is deterministic across chains.
 * @dev A reverting compose (minReturn, wrapper paused, sanctioned recipient) is the designed
 *      retry path, not a failure mode: retries re-evaluate both branches, so every message
 *      terminates either as an unwrap or as a wrapped delivery to the safe. `rescueTokens` is
 *      break-glass only, for messages that can never succeed on either branch.
 */
contract StockUnwrapper is UpgradeableProxy, ILayerZeroComposer {
    using SafeERC20 for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableAddressWhitelistLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.StockUnwrapper
    struct StockUnwrapperStorage {
        /// @notice LayerZero V2 endpoint; only caller allowed on `lzCompose`.
        address lzEndpoint;
        /// @notice Source chain (OP) endpoint ID; messages from any other EID are rejected.
        uint32 srcEid;
        /// @notice The OP `StockWithdrawModule` as bytes32 (`composeFrom` must match).
        bytes32 srcModule;
        /// @notice Enumerable set of mainnet OFTAdapters allowed to compose into this contract.
        EnumerableSetLib.AddressSet registeredAdapters;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockUnwrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockUnwrapperStorageLocation = 0x6e9822439d6ab393c03c3490c3eb1d75bff2e8473b0dc1e0a74b73fd90a39c00;

    /// @notice Role allowed to configure adapters/source module and rescue stranded tokens.
    bytes32 public constant STOCK_UNWRAPPER_ADMIN_ROLE = keccak256("STOCK_UNWRAPPER_ADMIN_ROLE");

    /**
     * @notice Emitted when OFTAdapters are registered/unregistered.
     * @param adapters The adapter addresses configured.
     * @param registered Whether each adapter is registered.
     */
    event AdaptersConfigured(address[] adapters, bool[] registered);

    /**
     * @notice Emitted when the trusted OP source module is updated.
     * @param oldSrcModule The previous source module (as bytes32).
     * @param newSrcModule The new source module (as bytes32).
     */
    event SrcModuleSet(bytes32 oldSrcModule, bytes32 newSrcModule);

    /**
     * @notice Emitted when a compose message is settled by unwrapping to the recipient.
     * @param guid The LayerZero message guid.
     * @param sourceSafe The OP safe that initiated the withdrawal.
     * @param recipient The address that received the unwrapped stock.
     * @param wrappedToken The ERC-4626 wrapper that was redeemed.
     * @param amountIn The wrapper shares redeemed.
     * @param assetsOut The underlying stock delivered.
     */
    event StockUnwrapped(bytes32 indexed guid, address indexed sourceSafe, address indexed recipient, address wrappedToken, uint256 amountIn, uint256 assetsOut);

    /**
     * @notice Emitted when a compose message is settled past its deadline by delivering the
     *         wrapped token to the user's safe address.
     * @param guid The LayerZero message guid.
     * @param sourceSafe The safe that initiated the withdrawal and received the wrapped token.
     * @param wrappedToken The wrapped stock token delivered.
     * @param amount The amount delivered.
     */
    event WrappedDeliveredToSafe(bytes32 indexed guid, address indexed sourceSafe, address wrappedToken, uint256 amount);

    /**
     * @notice Emitted on a break-glass admin rescue of stranded tokens.
     * @param token The token rescued.
     * @param to The rescue recipient.
     * @param amount The amount rescued.
     */
    event TokensRescued(address token, address to, uint256 amount);

    /// @notice Reverts when `lzCompose` is called by anyone but the LZ endpoint.
    error OnlyEndpoint();
    /// @notice Reverts when the composing OApp is not a registered OFTAdapter.
    error UnregisteredAdapter();
    /// @notice Reverts when the message's source EID is not the configured OP EID.
    error WrongSrcEid();
    /// @notice Reverts when `composeFrom` is not the OP StockWithdrawModule.
    error WrongComposeSender();
    /// @notice Reverts when the redeemed assets are below the user's signed minReturn.
    error InsufficientReturn(uint256 assets, uint256 minReturn);
    /// @notice Reverts on zero/malformed constructor or setter input.
    error InvalidInput();
    /// @notice Reverts when a non-admin calls an admin function.
    error OnlyAdmin();
    /// @notice Reverts when input arrays diverge in length.
    error ArrayLengthMismatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy with the full unwrapper config. The adapter arrays may be
     *         empty and set later via `configureAdapters`.
     * @param _roleRegistry Mainnet role registry (upgrade authority + pause control + admin role).
     * @param _lzEndpoint LayerZero V2 endpoint on Ethereum.
     * @param _srcEid OP mainnet endpoint ID.
     * @param _srcModule The OP `StockWithdrawModule` proxy address.
     * @param _adapters Mainnet OFTAdapters to register.
     * @param _registered Registration flag per adapter; same length as `_adapters`.
     * @custom:throws InvalidInput If any core config value is zero.
     */
    function initialize(
        address _roleRegistry,
        address _lzEndpoint,
        uint32 _srcEid,
        address _srcModule,
        address[] calldata _adapters,
        bool[] calldata _registered
    ) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        if (_lzEndpoint == address(0) || _srcEid == 0 || _srcModule == address(0)) revert InvalidInput();
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        $.lzEndpoint = _lzEndpoint;
        $.srcEid = _srcEid;
        $.srcModule = OFTComposeMsgCodec.addressToBytes32(_srcModule);
        if (_adapters.length > 0) _configureAdapters(_adapters, _registered);
    }

    // ---- Admin config ----

    /**
     * @notice Registers/unregisters mainnet OFTAdapters allowed to compose into this contract.
     * @param adapters The adapter addresses to configure.
     * @param registered Registration flag per adapter; same length as `adapters`.
     * @custom:throws OnlyAdmin If the caller lacks `STOCK_UNWRAPPER_ADMIN_ROLE`.
     * @custom:throws ArrayLengthMismatch If the arrays diverge in length or are empty.
     * @custom:throws InvalidInput If any adapter is zero or exposes no token.
     */
    function configureAdapters(address[] calldata adapters, bool[] calldata registered) external {
        _onlyAdmin();
        _configureAdapters(adapters, registered);
    }

    /**
     * @notice Updates the trusted OP source module (e.g. after an OP-side redeploy).
     * @param _srcModule The new OP `StockWithdrawModule` proxy address.
     * @custom:throws OnlyAdmin If the caller lacks `STOCK_UNWRAPPER_ADMIN_ROLE`.
     * @custom:throws InvalidInput If the module address is zero.
     */
    function setSrcModule(address _srcModule) external {
        _onlyAdmin();
        if (_srcModule == address(0)) revert InvalidInput();
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        bytes32 newSrcModule = OFTComposeMsgCodec.addressToBytes32(_srcModule);
        emit SrcModuleSet($.srcModule, newSrcModule);
        $.srcModule = newSrcModule;
    }

    /**
     * @notice Break-glass rescue for tokens stranded by a compose message that can never
     *         succeed on either branch (e.g. recipient AND safe both sanctioned, or a
     *         permanently paused wrapper). Normal failures MUST go through LZ retry instead.
     * @param token The token to rescue.
     * @param to The rescue recipient.
     * @param amount The amount to rescue.
     * @custom:throws OnlyAdmin If the caller lacks `STOCK_UNWRAPPER_ADMIN_ROLE`.
     * @custom:throws InvalidInput If any parameter is zero.
     */
    function rescueTokens(address token, address to, uint256 amount) external {
        _onlyAdmin();
        if (token == address(0) || to == address(0) || amount == 0) revert InvalidInput();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // ---- Views ----

    /**
     * @notice Returns the LayerZero V2 endpoint allowed to call `lzCompose`.
     * @return The endpoint address.
     */
    function getLzEndpoint() external view returns (address) {
        return _getStockUnwrapperStorage().lzEndpoint;
    }

    /**
     * @notice Returns the trusted source chain endpoint ID.
     * @return The OP endpoint ID.
     */
    function getSrcEid() external view returns (uint32) {
        return _getStockUnwrapperStorage().srcEid;
    }

    /**
     * @notice Returns the trusted OP source module.
     * @return The `StockWithdrawModule` address as bytes32 (`composeFrom` format).
     */
    function getSrcModule() external view returns (bytes32) {
        return _getStockUnwrapperStorage().srcModule;
    }

    /**
     * @notice Returns whether an OFTAdapter is allowed to compose into this contract.
     * @param adapter The adapter address to query.
     * @return True if the adapter is registered.
     */
    function isRegisteredAdapter(address adapter) external view returns (bool) {
        return _getStockUnwrapperStorage().registeredAdapters.contains(adapter);
    }

    /**
     * @notice Returns all registered OFTAdapters.
     * @return The registered adapter addresses.
     */
    function getRegisteredAdapters() external view returns (address[] memory) {
        return _getStockUnwrapperStorage().registeredAdapters.values();
    }

    // ---- Compose ----

    /**
     * @notice LayerZero compose entrypoint. The wrapped tokens were already credited to this
     *         contract by the OFTAdapter's `lzReceive` before this call.
     * @param _from The composing OApp — must be a registered OFTAdapter.
     * @param _guid LZ message guid (event linking only).
     * @param _message `OFTComposeMsgCodec`-encoded payload.
     * @custom:throws OnlyEndpoint If the caller is not the LZ endpoint.
     * @custom:throws UnregisteredAdapter If `_from` is not a registered OFTAdapter.
     * @custom:throws WrongSrcEid If the message's source EID is not the configured OP EID.
     * @custom:throws WrongComposeSender If `composeFrom` is not the OP StockWithdrawModule.
     * @custom:throws InsufficientReturn If the redeemed assets are below minReturn.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable nonReentrant whenNotPaused {
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        if (msg.sender != $.lzEndpoint) revert OnlyEndpoint();
        if (!$.registeredAdapters.contains(_from)) revert UnregisteredAdapter();
        if (OFTComposeMsgCodec.srcEid(_message) != $.srcEid) revert WrongSrcEid();
        if (OFTComposeMsgCodec.composeFrom(_message) != $.srcModule) revert WrongComposeSender();

        // amountLD is the amount ACTUALLY credited on this chain — authoritative over
        // anything the source encoded.
        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        (address sourceSafe, address recipient, uint256 minReturn, uint256 deadline) =
            abi.decode(OFTComposeMsgCodec.composeMsg(_message), (address, address, uint256, uint256));
        address wrappedToken = IOFT(_from).token();

        if (block.timestamp > deadline) {
            // Expired: deliver the WRAPPED asset to the user's safe address. A plain ERC-20
            // transfer works even before the safe has code on this chain.
            IERC20(wrappedToken).safeTransfer(sourceSafe, amount);
            emit WrappedDeliveredToSafe(_guid, sourceSafe, wrappedToken, amount);
        } else {
            // Backed wrappers are standard ERC-4626 vaults: redeem shares → underlying stock.
            uint256 assets = IERC4626(wrappedToken).redeem(amount, recipient, address(this));
            if (assets < minReturn) revert InsufficientReturn(assets, minReturn);
            emit StockUnwrapped(_guid, sourceSafe, recipient, wrappedToken, amount, assets);
        }
    }

    // ---- Internals ----

    /// @dev Shared by `initialize` and `configureAdapters`. A registered adapter must expose
    ///      the wrapped token it locks. Set mutation (zero/duplicate checks included) is
    ///      delegated to `EnumerableAddressWhitelistLib`.
    function _configureAdapters(address[] calldata adapters, bool[] calldata registered) internal {
        uint256 len = adapters.length;
        if (len == 0 || len != registered.length) revert ArrayLengthMismatch();
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        for (uint256 i = 0; i < len;) {
            if (adapters[i] == address(0)) revert InvalidInput();
            if (registered[i] && IOFT(adapters[i]).token() == address(0)) revert InvalidInput();
            unchecked {
                ++i;
            }
        }
        $.registeredAdapters.configure(adapters, registered);
        emit AdaptersConfigured(adapters, registered);
    }

    /// @dev Reverts unless the caller holds `STOCK_UNWRAPPER_ADMIN_ROLE`.
    function _onlyAdmin() internal view {
        if (!roleRegistry().hasRole(STOCK_UNWRAPPER_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }

    /// @dev Returns the storage struct from the ERC-7201 namespaced slot.
    function _getStockUnwrapperStorage() internal pure returns (StockUnwrapperStorage storage $) {
        assembly {
            $.slot := StockUnwrapperStorageLocation
        }
    }
}
