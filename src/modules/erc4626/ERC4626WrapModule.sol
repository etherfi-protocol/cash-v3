// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { ModuleLendGatewaySandwich } from "../ModuleLendGatewaySandwich.sol";

/**
 * @title ERC4626WrapModule
 * @author ether.fi
 * @notice Module that wraps a safe's assets into an allowlisted ERC-4626 vault and unwraps
 *         the shares back, e.g. ZCHF into the Frankencoin savings vault svZCHF.
 * @dev Extends ModuleBase with the same shape as MidasModule: EIP-191 admin-signature
 *      entrypoints over a per-safe nonce, a role-gated vault allowlist, and the lend
 *      gateway bookends. A gateway safe's assets may be supplied to Aave, so each leg pulls
 *      any shortfall of its input out of the safe's Aave position first and re-supplies its
 *      output as collateral afterwards.
 *
 *      Three deliberate choices:
 *
 *      1. The vault's asset is read once, when an admin registers the vault, and stored.
 *         The allowlist therefore blesses a (vault, asset) PAIR: a vault that later reports
 *         a different `asset()` cannot redirect a safe's funds into a token nobody approved.
 *         Reading `asset()` live at call time would follow such a repoint.
 *
 *      2. `deposit` and `redeem` are the legs used, not `mint` and `withdraw`. Both take an
 *         exact input amount and floor the output, which is what the bookends model — they
 *         require exactly `amount` of the input loose in the safe. `mint`/`withdraw` take an
 *         exact output with a variable input, which that contract cannot express.
 *
 *      3. Unlike `MidasModule.withdraw`, the unwrap leg DOES re-supply. Midas redemption is
 *         asynchronous, so its asset output arrives in a later transaction and there is
 *         nothing to supply; ERC-4626 `redeem` is synchronous, so the assets are in the safe
 *         before the call returns.
 *
 *      The allowlist is for synchronous vaults. An async, queue-based vault registered by
 *      mistake mints nothing, so the `minShares` floor rejects the wrap rather than letting
 *      the deposit disappear. Fee-on-transfer and rebasing assets are out of scope: the
 *      before/after balance measurement reports what actually arrived, but the `minShares` /
 *      `minAssets` floors are the only protection against a lossy token.
 *
 *      Deployment note: the module must be authorised as a `LendGateway` driver via
 *      `setDriver`, or every shortfall pull reverts with `OnlyDriver`.
 */
contract ERC4626WrapModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, ModuleLendGatewaySandwich {
    using MessageHashUtils for bytes32;

    /// @notice Underlying asset registered for each allowlisted vault; zero means unsupported
    mapping(address vault => address asset) public vaultAsset;

    /// @notice TypeHash for the wrap function signature
    bytes32 public constant WRAP_SIG = keccak256("wrap");

    /// @notice TypeHash for the unwrap function signature
    bytes32 public constant UNWRAP_SIG = keccak256("unwrap");

    /// @notice Role identifier for admins of the ERC-4626 wrap module
    bytes32 public constant ERC4626_MODULE_ADMIN = keccak256("ERC4626_MODULE_ADMIN");

    /// @notice Emitted when vaults are added to the allowlist
    event VaultsAdded(address[] vaults, address[] assets);

    /// @notice Emitted when vaults are removed from the allowlist
    event VaultsRemoved(address[] vaults);

    /// @notice Emitted when a Safe wraps assets into a vault
    event Wrap(address indexed safe, address indexed vault, address indexed asset, uint256 assets, uint256 shares);

    /// @notice Emitted when a Safe unwraps shares back into the vault's asset
    event Unwrap(address indexed safe, address indexed vault, address indexed asset, uint256 shares, uint256 assets);

    /// @notice Thrown when the amount received is less than the caller's floor
    error InsufficientReturnAmount();

    /// @notice Thrown when the vault is not on the allowlist
    error UnsupportedVault();

    /// @notice Thrown when the caller lacks the required role
    error Unauthorized();

    /**
     * @notice Initializes the module, optionally seeding the vault allowlist
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _vaults ERC-4626 vaults to allowlist. May be empty: the list is admin-managed,
     *        and requiring a seed would force a placeholder entry.
     * @custom:throws InvalidInput If any vault is the zero address or reports no asset
     */
    constructor(address _etherFiDataProvider, address[] memory _vaults) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        uint256 len = _vaults.length;
        for (uint256 i = 0; i < len;) {
            _registerVault(_vaults[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Wraps `assets` of the vault's underlying into vault shares
     * @param safe The Safe address which holds the assets
     * @param vault The allowlisted ERC-4626 vault to deposit into
     * @param assets The amount of underlying to deposit
     * @param minShares The minimum shares the safe must receive
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws UnsupportedVault If the vault is not allowlisted
     * @custom:throws InsufficientReturnAmount If fewer than minShares are received
     */
    function wrap(address safe, address vault, uint256 assets, uint256 minShares, address signer, bytes calldata signature) external nonReentrant onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encodePacked(WRAP_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(vault, assets, minShares))).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _wrap(safe, vault, assets, minShares);
    }

    /**
     * @notice Unwraps `shares` of an allowlisted vault back into its underlying
     * @param safe The Safe address which holds the shares
     * @param vault The allowlisted ERC-4626 vault to redeem from
     * @param shares The amount of shares to redeem
     * @param minAssets The minimum underlying the safe must receive
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws UnsupportedVault If the vault is not allowlisted
     * @custom:throws InsufficientReturnAmount If fewer than minAssets are received
     */
    function unwrap(address safe, address vault, uint256 shares, uint256 minAssets, address signer, bytes calldata signature) external nonReentrant onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encodePacked(UNWRAP_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(vault, shares, minAssets))).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _unwrap(safe, vault, shares, minAssets);
    }

    /**
     * @dev Deposits `assets` from the safe into `vault`, measuring the shares actually
     *      credited rather than trusting the vault's return value.
     */
    function _wrap(address safe, address vault, uint256 assets, uint256 minShares) internal {
        if (assets == 0) revert InvalidInput();
        address asset = _requireVault(vault);

        // Pull any shortfall of the input out of the safe's Aave position, then confirm the
        // safe holds the full amount loose.
        uint256 healthFactorBefore = _pullAndRequire(safe, asset, assets);

        uint256 sharesBefore = ERC20(vault).balanceOf(safe);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = asset;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, vault, assets);
        to[1] = vault;
        data[1] = abi.encodeWithSelector(IERC4626.deposit.selector, assets, safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 sharesReceived = ERC20(vault).balanceOf(safe) - sharesBefore;
        if (sharesReceived < minShares) revert InsufficientReturnAmount();

        // Re-supply the share output as collateral when the gateway lists it; otherwise it stays loose.
        _resupplyToGateway(safe, vault, sharesReceived);

        _ensureGatewayFloor(safe, healthFactorBefore);

        emit Wrap(safe, vault, asset, assets, sharesReceived);
    }

    /**
     * @dev Redeems `shares` from `vault` back to the safe. No approval leg: the safe itself
     *      is the caller, so on `redeem(shares, safe, safe)` the owner is `msg.sender` and
     *      ERC-4626 requires no allowance.
     */
    function _unwrap(address safe, address vault, uint256 shares, uint256 minAssets) internal {
        if (shares == 0) revert InvalidInput();
        address asset = _requireVault(vault);

        // The shares are the input here, so they are what may need pulling back from Aave.
        uint256 healthFactorBefore = _pullAndRequire(safe, vault, shares);

        uint256 assetsBefore = ERC20(asset).balanceOf(safe);

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        to[0] = vault;
        data[0] = abi.encodeWithSelector(IERC4626.redeem.selector, shares, safe, safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 assetsReceived = ERC20(asset).balanceOf(safe) - assetsBefore;
        if (assetsReceived < minAssets) revert InsufficientReturnAmount();

        // ERC-4626 redemption is synchronous, so unlike an async redemption request the
        // output is here now and can go back to work as collateral.
        _resupplyToGateway(safe, asset, assetsReceived);

        _ensureGatewayFloor(safe, healthFactorBefore);

        emit Unwrap(safe, vault, asset, shares, assetsReceived);
    }

    /**
     * @notice Adds ERC-4626 vaults to the allowlist, pinning each vault's asset
     * @param vaults Vault addresses to allowlist
     * @dev Only callable by accounts with the ERC4626_MODULE_ADMIN role
     * @custom:throws Unauthorized If the caller lacks the admin role
     * @custom:throws InvalidInput If the array is empty, or a vault is zero or reports no asset
     */
    function addVaults(address[] calldata vaults) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(ERC4626_MODULE_ADMIN, msg.sender)) revert Unauthorized();

        uint256 len = vaults.length;
        if (len == 0) revert InvalidInput();

        address[] memory assets = new address[](len);
        for (uint256 i = 0; i < len;) {
            assets[i] = _registerVault(vaults[i]);
            unchecked {
                ++i;
            }
        }

        emit VaultsAdded(vaults, assets);
    }

    /**
     * @notice Removes vaults from the allowlist
     * @param vaults Vault addresses to remove
     * @dev Only callable by accounts with the ERC4626_MODULE_ADMIN role
     * @custom:throws Unauthorized If the caller lacks the admin role
     * @custom:throws InvalidInput If the array is empty
     */
    function removeVaults(address[] calldata vaults) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(ERC4626_MODULE_ADMIN, msg.sender)) revert Unauthorized();

        uint256 len = vaults.length;
        if (len == 0) revert InvalidInput();

        for (uint256 i = 0; i < len;) {
            delete vaultAsset[vaults[i]];
            unchecked {
                ++i;
            }
        }

        emit VaultsRemoved(vaults);
    }

    /**
     * @dev Records `vault`'s asset as of now. Pinning it here is what makes the allowlist a
     *      bless of the (vault, asset) pair rather than of the vault's future behaviour.
     * @return asset The vault's underlying asset
     */
    function _registerVault(address vault) internal returns (address asset) {
        if (vault == address(0)) revert InvalidInput();
        asset = IERC4626(vault).asset();
        if (asset == address(0)) revert InvalidInput();
        vaultAsset[vault] = asset;
    }

    /**
     * @dev Returns the registered asset for `vault`.
     * @custom:throws UnsupportedVault If the vault is not allowlisted
     */
    function _requireVault(address vault) internal view returns (address asset) {
        asset = vaultAsset[vault];
        if (asset == address(0)) revert UnsupportedVault();
    }
}
