// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { IOFT } from "../interfaces/IOFT.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
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
 *         - after `deadline`: transfer the WRAPPED token to the user's deterministic
 *           TradingSafe (`ITradingSafeFactory.getDeterministicAddress(sourceSafe)`).
 * @dev A reverting compose (minReturn, wrapper paused, sanctioned recipient) is the designed
 *      retry path, not a failure mode: retries re-evaluate both branches, so every message
 *      terminates either as an unwrap or as a wrapped delivery to the safe. `rescueTokens` is
 *      break-glass only, for messages that can never succeed on either branch.
 */
contract StockUnwrapper is UpgradeableProxy, ILayerZeroComposer {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:etherfi.storage.StockUnwrapper
    struct StockUnwrapperStorage {
        /// @notice LayerZero V2 endpoint; only caller allowed on `lzCompose`.
        address lzEndpoint;
        /// @notice Source chain (OP) endpoint ID; messages from any other EID are rejected.
        uint32 srcEid;
        /// @notice The OP `StockWithdrawModule` as bytes32 (`composeFrom` must match).
        bytes32 srcModule;
        /// @notice Mainnet TradingSafe factory used to derive the deadline-fallback address.
        ITradingSafeFactory tradingSafeFactory;
        /// @notice Mainnet OFTAdapters allowed to compose into this contract.
        mapping(address adapter => bool registered) registeredAdapters;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockUnwrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockUnwrapperStorageLocation = 0x6e9822439d6ab393c03c3490c3eb1d75bff2e8473b0dc1e0a74b73fd90a39c00;

    /// @notice Role allowed to configure adapters/source module and rescue stranded tokens.
    bytes32 public constant STOCK_UNWRAPPER_ADMIN_ROLE = keccak256("STOCK_UNWRAPPER_ADMIN_ROLE");

    event AdaptersConfigured(address[] adapters, bool[] registered);
    event SrcModuleSet(bytes32 oldSrcModule, bytes32 newSrcModule);
    event StockUnwrapped(bytes32 indexed guid, address indexed sourceSafe, address indexed recipient, address wrappedToken, uint256 amountIn, uint256 assetsOut);
    event WrappedDeliveredToSafe(bytes32 indexed guid, address indexed sourceSafe, address indexed tradingSafe, address wrappedToken, uint256 amount);
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
     * @notice Initialises the proxy.
     * @param _roleRegistry Mainnet role registry (upgrade authority + pause control + admin role).
     * @param _lzEndpoint LayerZero V2 endpoint on Ethereum.
     * @param _srcEid OP mainnet endpoint ID.
     * @param _srcModule The OP `StockWithdrawModule` proxy address.
     * @param _tradingSafeFactory Mainnet `TradingSafeFactory`.
     */
    function initialize(address _roleRegistry, address _lzEndpoint, uint32 _srcEid, address _srcModule, address _tradingSafeFactory) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        if (_lzEndpoint == address(0) || _srcEid == 0 || _srcModule == address(0) || _tradingSafeFactory == address(0)) revert InvalidInput();
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        $.lzEndpoint = _lzEndpoint;
        $.srcEid = _srcEid;
        $.srcModule = OFTComposeMsgCodec.addressToBytes32(_srcModule);
        $.tradingSafeFactory = ITradingSafeFactory(_tradingSafeFactory);
    }

    // ---- Admin config ----

    /// @notice Registers/unregisters mainnet OFTAdapters allowed to compose into this contract.
    function configureAdapters(address[] calldata adapters, bool[] calldata registered) external {
        _onlyAdmin();
        uint256 len = adapters.length;
        if (len == 0 || len != registered.length) revert ArrayLengthMismatch();
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        for (uint256 i = 0; i < len;) {
            if (adapters[i] == address(0)) revert InvalidInput();
            // Sanity: a registered adapter must expose the wrapped token it locks.
            if (registered[i] && IOFT(adapters[i]).token() == address(0)) revert InvalidInput();
            $.registeredAdapters[adapters[i]] = registered[i];
            unchecked {
                ++i;
            }
        }
        emit AdaptersConfigured(adapters, registered);
    }

    /// @notice Updates the trusted OP source module (e.g. after an OP-side redeploy).
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
     *         succeed on either branch (e.g. recipient AND TradingSafe both sanctioned, or a
     *         permanently paused wrapper). Normal failures MUST go through LZ retry instead.
     */
    function rescueTokens(address token, address to, uint256 amount) external {
        _onlyAdmin();
        if (token == address(0) || to == address(0) || amount == 0) revert InvalidInput();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // ---- Views ----

    function getLzEndpoint() external view returns (address) {
        return _getStockUnwrapperStorage().lzEndpoint;
    }

    function getSrcEid() external view returns (uint32) {
        return _getStockUnwrapperStorage().srcEid;
    }

    function getSrcModule() external view returns (bytes32) {
        return _getStockUnwrapperStorage().srcModule;
    }

    function getTradingSafeFactory() external view returns (address) {
        return address(_getStockUnwrapperStorage().tradingSafeFactory);
    }

    function isRegisteredAdapter(address adapter) external view returns (bool) {
        return _getStockUnwrapperStorage().registeredAdapters[adapter];
    }

    // ---- Compose ----

    /**
     * @notice LayerZero compose entrypoint. The wrapped tokens were already credited to this
     *         contract by the OFTAdapter's `lzReceive` before this call.
     * @param _from The composing OApp — must be a registered OFTAdapter.
     * @param _guid LZ message guid (event linking only).
     * @param _message `OFTComposeMsgCodec`-encoded payload.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable nonReentrant whenNotPaused {
        StockUnwrapperStorage storage $ = _getStockUnwrapperStorage();
        if (msg.sender != $.lzEndpoint) revert OnlyEndpoint();
        if (!$.registeredAdapters[_from]) revert UnregisteredAdapter();
        if (OFTComposeMsgCodec.srcEid(_message) != $.srcEid) revert WrongSrcEid();
        if (OFTComposeMsgCodec.composeFrom(_message) != $.srcModule) revert WrongComposeSender();

        // amountLD is the amount ACTUALLY credited on this chain — authoritative over
        // anything the source encoded.
        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        (address sourceSafe, address recipient, uint256 minReturn, uint256 deadline) =
            abi.decode(OFTComposeMsgCodec.composeMsg(_message), (address, address, uint256, uint256));
        address wrappedToken = IOFT(_from).token();

        if (block.timestamp > deadline) {
            // Expired: deliver the WRAPPED asset to the user's deterministic TradingSafe.
            // A plain ERC-20 transfer works even before the safe is deployed (CREATE3 address).
            address tradingSafe = $.tradingSafeFactory.getDeterministicAddress(sourceSafe);
            IERC20(wrappedToken).safeTransfer(tradingSafe, amount);
            emit WrappedDeliveredToSafe(_guid, sourceSafe, tradingSafe, wrappedToken, amount);
        } else {
            // Backed wrappers are standard ERC-4626 vaults: redeem shares → underlying stock.
            uint256 assets = IERC4626(wrappedToken).redeem(amount, recipient, address(this));
            if (assets < minReturn) revert InsufficientReturn(assets, minReturn);
            emit StockUnwrapped(_guid, sourceSafe, recipient, wrappedToken, amount, assets);
        }
    }

    // ---- Internals ----

    function _onlyAdmin() internal view {
        if (!roleRegistry().hasRole(STOCK_UNWRAPPER_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }

    function _getStockUnwrapperStorage() internal pure returns (StockUnwrapperStorage storage $) {
        assembly {
            $.slot := StockUnwrapperStorageLocation
        }
    }
}
