// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title TopUpDest
 * @notice Contract for managing token deposits and disbursements to EtherFi safes
 * @dev Extends UpgradeableProxy with reentrancy protection and pause functionality
 * @author ether.fi
 */
contract TopUpDest is UpgradeableProxy {
    using SafeERC20 for IERC20;

    /// @notice Role identifier for accounts authorized to deposit tokens
    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role identifier for accounts authorized to top up user safes
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    bytes32 public constant TOP_UP_APPROVAL_TYPEHASH = keccak256("TopUpApproval(bytes32 txHash,address user,uint256 sourceChainId,address token,uint256 amount,uint256 deadline,uint256 epoch)");
    bytes32 private constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    struct TopUpApproval {
        bytes32 txHash;
        address user;
        uint256 sourceChainId;
        address token;
        uint256 amount;
        uint256 deadline;
    }

    IWETH public immutable weth;

    IEtherFiDataProvider public immutable etherFiDataProvider;

    /**
     * @dev Storage structure for TopUpDest using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.TopUpDest
     */
    struct TopUpDestStorage {
        /// @notice Tracks the total deposits for each token
        mapping(address token => uint256 deposits) deposits;

        /// @notice Tracks whether a transaction has been processed
        mapping(bytes32 txId => bool completed) transactionCompleted;

        /// @notice ERC-4626 wrapper that raw stock arriving here is wrapped into
        mapping(address raw => address wrapper) stockWrappers;

        // Append only: existing completion IDs and mapping slots must never change.
        address cosigner;
        bool cosignerRequired;
        uint256 cosignerEpoch;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TopUpDest")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TopUpDestStorageLocation = 0xcf0121b0f46cee8ebfce652f58f0ad785e4fcd91a62127b83995179fc450fe00;

    /**
     * @notice Emitted when tokens are deposited into the contract
     * @param token Address of the deposited token
     * @param amount Amount of tokens deposited
     */
    event Deposit(address indexed token, uint256 amount);

    /**
     * @notice Emitted when tokens are withdrawn from the contract
     * @param token Address of the withdrawn token
     * @param amount Amount of tokens withdrawn
     */
    event Withdrawal(address indexed token, uint256 amount);

    /**
     * @notice Emitted when tokens are sent to a user's safe
     * @param txId TxId created for deduplication = keccak256(txhash || token || user)
     * @param user Address of the recipient safe
     * @param sourceTxHash Tx hash for the source tx
     * @param chainId ID of the blockchain where the user topped up
     * @param token Address of the token used for top-up
     * @param amount Amount of tokens sent
     */
    event TopUp(bytes32 indexed txId, address indexed user, address indexed token, bytes32 sourceTxHash, uint256 chainId, uint256 amount);

    /// @notice Emitted when a best-effort top-up supply to the lend gateway fails
    event LendSupplyFailed(address indexed safe, address indexed token, uint256 amount, bytes reason);

    /// @notice Emitted when a raw stock's wrapper is set; a zero wrapper removes the pair
    event StockWrapperSet(address indexed raw, address indexed wrapper);

    /// @notice Emitted when raw stock held here is wrapped and the shares added to the wrapper's deposit
    event StockWrapped(address indexed raw, address indexed wrapper, uint256 amount, uint256 shares);

    /// @notice Error thrown when the contract has insufficient token balance
    error BalanceTooLow();

    /// @notice Error thrown when withdrawal amount exceeds deposit
    error AmountGreaterThanDeposit();

    /// @notice Error thrown when a zero amount is provided
    error AmountCannotBeZero();

    /// @notice Error thrown when an operation is attempted on an unregistered safe
    error NotARegisteredSafe();

    /// @notice Error thrown when input arrays have different lengths
    error ArrayLengthMismatch();

    /// @notice Error thrown when the topup is already processed
    error TopUpAlreadyProcessed();

    /// @notice Error thrown when a self-call-only function is called externally
    error OnlySelf();

    /// @notice Error thrown when a wrapper's underlying asset is not the raw stock it is paired with
    error InvalidWrapperAsset();

    /// @notice Error thrown when a raw stock has no wrapper set
    error StockWrapperNotSet();

    /// @notice Thrown when wrapping raw stock minted no wrapper shares
    error WrapMintedNothing();

    event CosignerConfigured(address indexed cosigner, bool required, uint256 epoch);
    error CosignerRequired();
    error InvalidCosigner();
    error ApprovalExpired();
    error InvalidCosignature();

    /**
     * @dev Constructor that disables initializers to prevent implementation contract initialization
     */
    constructor(address _etherFiDataProvider, address _weth) {
        weth = IWETH(_weth);
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
        _disableInitializers();
    }

    /**
     * @notice Initializes the TopUpDest contract
     * @dev Sets up role registry, reentrancy guard, and data provider
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the TopUpDestStorage struct
     */
    function _getTopUpDestStorage() internal pure returns (TopUpDestStorage storage $) {
        assembly {
            $.slot := TopUpDestStorageLocation
        }
    }

    /**
     * @notice Deposits tokens into the contract
     * @dev Only callable by accounts with TOP_UP_DEPOSITOR_ROLE
     * @param token Address of the token to deposit
     * @param amount Amount of tokens to deposit
     * @custom:throws AmountCannotBeZero if amount is zero
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function deposit(address token, uint256 amount) external onlyRole(TOP_UP_DEPOSITOR_ROLE) {
        if (amount == 0) revert AmountCannotBeZero();
        // A rebasing stock delivers whole shares, which can be less than the amount asked for
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;

        _getTopUpDestStorage().deposits[token] += received;
        emit Deposit(token, received);
    }

    /**
     * @notice Withdraws tokens from the contract
     * @dev Only callable by the upgrader role
     * @param token Address of the token to withdraw
     * @param amount Amount of tokens to withdraw
     * @custom:throws AmountCannotBeZero if amount is zero
     * @custom:throws AmountGreaterThanDeposit if amount exceeds available deposit
     */
    function withdraw(address token, uint256 amount) external nonReentrant onlyAdminTimelock {
        TopUpDestStorage storage $ = _getTopUpDestStorage();

        if (amount == 0) revert AmountCannotBeZero();
        if (amount > $.deposits[token]) revert AmountGreaterThanDeposit();

        $.deposits[token] -= amount;
        _transfer(msg.sender, token, amount);

        emit Withdrawal(token, amount);
    }

    /**
     * @notice Tops up multiple user safes in a single transaction
     * @dev Only callable by accounts with TOP_UP_ROLE when contract is not paused
     * @param txHashes Array of transaction hashes for source transactions
     * @param users Array of safe addresses to top up
     * @param chainIds Array of chain IDs where the user topped-up
     * @param tokens Array of token addresses to send
     * @param amounts Array of token amounts to send
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function topUpUserSafeBatch(bytes32[] memory txHashes, address[] memory users, uint256[] memory chainIds, address[] memory tokens, uint256[] memory amounts) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        if (_getTopUpDestStorage().cosignerRequired) revert CosignerRequired();
        uint256 len = txHashes.length;
        if (len != users.length || len != chainIds.length || len != tokens.length || len != amounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            _topUp(txHashes[i], users[i], chainIds[i], tokens[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Tops up a single user safe
     * @dev Only callable by accounts with TOP_UP_ROLE when contract is not paused
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param chainId Chain ID where the user topped-up
     * @param token Address of the token to send
     * @param amount Amount of tokens to send
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function topUpUserSafe(bytes32 txHash, address user, uint256 chainId, address token, uint256 amount) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        if (_getTopUpDestStorage().cosignerRequired) revert CosignerRequired();
        _topUp(txHash, user, chainId, token, amount);
    }

    /**
     * @notice Sets the co-signer and whether unsigned payouts are blocked
     * @dev Every call increments the epoch and invalidates outstanding approvals, even if the settings
     *      are unchanged. Signed payout methods always verify signatures regardless of enforcement.
     * @param signer Address whose payout signatures are accepted; zero disables signed payouts
     * @param required Whether the legacy unsigned payout methods must revert
     * @custom:throws OnlyAdminTimelock if caller does not have the admin timelock role
     * @custom:throws InvalidCosigner if enforcement is required with a zero signer
     */
    function configureCosigner(address signer, bool required) external onlyAdminTimelock {
        if (required && signer == address(0)) revert InvalidCosigner();
        TopUpDestStorage storage $ = _getTopUpDestStorage();
        $.cosigner = signer;
        $.cosignerRequired = required;
        ++$.cosignerEpoch;
        emit CosignerConfigured(signer, required, $.cosignerEpoch);
    }

    /**
     * @notice Gets the current co-signer configuration
     * @return Address whose payout signatures are accepted
     * @return Whether legacy unsigned payouts are blocked
     * @return Current configuration epoch included in approval digests
     */
    function cosignerConfig() external view returns (address, bool, uint256) {
        TopUpDestStorage storage $ = _getTopUpDestStorage();
        return ($.cosigner, $.cosignerRequired, $.cosignerEpoch);
    }

    /**
     * @notice Calculates the EIP-712 digest for a payout approval
     * @dev Binds the payout to this destination chain, proxy and current configuration epoch.
     *      This digest does not replace getTxId or completion tracking.
     * @param approval Source reference, recipient, token, amount and inclusive expiry to approve
     * @return Digest to sign without an additional personal-message prefix
     */
    function getTopUpApprovalDigest(TopUpApproval memory approval) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("EtherFiTopUpDest"), keccak256("1"), block.chainid, address(this)));
        bytes32 structHash = keccak256(abi.encode(TOP_UP_APPROVAL_TYPEHASH, approval.txHash, approval.user, approval.sourceChainId, approval.token, approval.amount, approval.deadline, _getTopUpDestStorage().cosignerEpoch));
        return MessageHashUtils.toTypedDataHash(domain, structHash);
    }

    /**
     * @notice Tops up a user safe with a co-signer approval
     * @dev Requires TOP_UP_ROLE, an unpaused contract and a valid signature even when enforcement is disabled.
     * @param approval Payout details and inclusive expiry approved by the co-signer
     * @param signature Co-signer's 65-byte EIP-712 signature
     * @custom:throws Unauthorized if caller does not have TOP_UP_ROLE
     * @custom:throws EnforcedPause if the contract is paused
     * @custom:throws InvalidCosigner if no co-signer is configured
     * @custom:throws ApprovalExpired if the approval deadline has passed
     * @custom:throws InvalidCosignature if the signature is malformed or does not match the co-signer
     * @custom:throws NotARegisteredSafe if the recipient is not a registered safe
     * @custom:throws TopUpAlreadyProcessed if the payout was already completed
     * @custom:throws BalanceTooLow if the contract has insufficient payout tokens
     */
    function topUpUserSafeWithApproval(TopUpApproval calldata approval, bytes calldata signature) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        _topUpWithApproval(approval, signature);
    }

    /**
     * @notice Tops up multiple user safes with one co-signer approval per payout
     * @dev Uses the same checks as topUpUserSafeWithApproval; any failure rolls back the entire batch.
     * @param approvals Payout details and inclusive expiry for each item
     * @param signatures Co-signer signature for each approval in the same order
     * @custom:throws ArrayLengthMismatch if approval and signature counts differ
     */
    function topUpUserSafeBatchWithApproval(TopUpApproval[] calldata approvals, bytes[] calldata signatures) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        if (approvals.length != signatures.length) revert ArrayLengthMismatch();
        for (uint256 i; i < approvals.length; ++i) {
            _topUpWithApproval(approvals[i], signatures[i]);
        }
    }

    /**
     * @notice Verifies a co-signer approval before executing the existing payout logic
     * @dev Uses the current signer and epoch; approval remains valid at its exact deadline.
     * @param approval Exact payout details and inclusive expiry to verify
     * @param signature Co-signer's 65-byte EIP-712 signature
     * @custom:throws InvalidCosigner if no co-signer is configured
     * @custom:throws ApprovalExpired if the approval deadline has passed
     * @custom:throws InvalidCosignature if signature recovery fails or recovers a different signer
     */
    function _topUpWithApproval(TopUpApproval memory approval, bytes memory signature) internal {
        address signer = _getTopUpDestStorage().cosigner;
        if (signer == address(0)) revert InvalidCosigner();
        if (block.timestamp > approval.deadline) revert ApprovalExpired();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(getTopUpApprovalDigest(approval), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert InvalidCosignature();
        _topUp(approval.txHash, approval.user, approval.sourceChainId, approval.token, approval.amount);
    }

    /**
     * @notice Internal implementation of top-up logic
     * @dev Verifies the safe, transfers tokens, and updates transaction records
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param chainId Chain ID where the user topped-up
     * @param token Address of the token to send
     * @param amount Amount of tokens to send
     * @custom:throws NotARegisteredSafe if the user address is not a registered safe
     * @custom:throws TopUpAlreadyProcessed if the transaction has already been processed
     * @custom:throws BalanceTooLow if the contract has insufficient token balance
     */
    function _topUp(bytes32 txHash, address user, uint256 chainId, address token, uint256 amount) internal {
        TopUpDestStorage storage $ = _getTopUpDestStorage();

        bytes32 txId = getTxId(txHash, user, token);
        if (!etherFiDataProvider.isEtherFiSafe(user)) revert NotARegisteredSafe();
        if ($.transactionCompleted[txId]) revert TopUpAlreadyProcessed();

        $.transactionCompleted[txId] = true;
        _transfer(user, token, amount);

        try this.supplyTopUpToLend(user, token, amount) { }
        catch (bytes memory reason) {
            emit LendSupplyFailed(user, token, amount, reason);
        }

        emit TopUp(txId, user, token, txHash, chainId, amount);
    }

    /**
     * @notice Supplies a topped-up amount into the lend gateway on behalf of the safe
     * @dev External + self-call only: try/catch needs an external call, so _topUp invokes this via
     *      this.supplyTopUpToLend(...) to isolate any failure and fall back to a loose topup. The
     *      msg.sender guard keeps it a private helper. No-op unless the safe is lend-active and the
     *      token is registered.
     * @param safe Address of the safe that was topped up
     * @param token Address of the topped-up token
     * @param amount Amount of tokens to supply
     * @custom:throws OnlySelf if called by anyone other than this contract
     */
    function supplyTopUpToLend(address safe, address token, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();

        ICashModule cashModule = ICashModule(etherFiDataProvider.getCashModule());
        if (!cashModule.isLendActive(safe)) return;

        ILendGateway lendGateway = cashModule.getLendGateway();
        if (!lendGateway.isRegistered(token)) return;

        lendGateway.supply(safe, token, amount);
    }

    /**
     * @notice Sets the ERC-4626 wrapper for each raw stock; a zero wrapper removes the pair
     * @dev Only callable by the admin timelock. The wrapper must report the raw stock as its asset.
     * @param raws Raw stock tokens
     * @param wrappers Wrapper per raw stock
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws InvalidWrapperAsset if a wrapper's asset is not the raw stock
     */
    function setStockWrappers(address[] calldata raws, address[] calldata wrappers) external onlyAdminTimelock {
        uint256 len = raws.length;
        if (len != wrappers.length) revert ArrayLengthMismatch();
        TopUpDestStorage storage $ = _getTopUpDestStorage();

        for (uint256 i = 0; i < len; ++i) {
            if (wrappers[i] != address(0) && IERC4626(wrappers[i]).asset() != raws[i]) revert InvalidWrapperAsset();
            $.stockWrappers[raws[i]] = wrappers[i];
            emit StockWrapperSet(raws[i], wrappers[i]);
        }
    }

    /**
     * @notice Wraps this contract's whole balance of a raw stock into its wrapper and adds the shares to the
     *         wrapper's deposit, so a bridge payout of raw stock becomes wrapper available for top-ups
     * @dev Only callable by accounts with TOP_UP_ROLE when contract is not paused
     * @param raw Raw stock token to wrap
     * @custom:throws StockWrapperNotSet if the raw stock has no wrapper
     * @custom:throws AmountCannotBeZero if this contract holds none of the raw stock
     * @custom:throws WrapMintedNothing if the wrapper minted no shares for the deposit
     */
    function wrapStock(address raw) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        TopUpDestStorage storage $ = _getTopUpDestStorage();
        address wrapper = $.stockWrappers[raw];
        if (wrapper == address(0)) revert StockWrapperNotSet();

        uint256 amount = IERC20(raw).balanceOf(address(this));
        if (amount == 0) revert AmountCannotBeZero();

        IERC20(raw).forceApprove(wrapper, amount);
        uint256 shares = IERC4626(wrapper).deposit(amount, address(this));
        if (shares == 0) revert WrapMintedNothing();
        IERC20(raw).forceApprove(wrapper, 0);
        // The wrapper pulls whole shares, so a sub-share remainder stays here until the next wrap
        uint256 wrapped = amount - IERC20(raw).balanceOf(address(this));
        // Raw booked through deposit() has left as wrapper. Raw from the bridge was never booked, but it
        // refills the float that already paid those top-ups, so its shares are booked like a deposit.
        uint256 booked = $.deposits[raw];
        $.deposits[raw] -= wrapped > booked ? booked : wrapped;
        $.deposits[wrapper] += shares;

        emit StockWrapped(raw, wrapper, wrapped, shares);
    }

    /**
     * @notice Gets the wrapper set for a raw stock, zero if none
     * @param raw Raw stock token
     * @return Wrapper address
     */
    function stockWrapperFor(address raw) external view returns (address) {
        return _getTopUpDestStorage().stockWrappers[raw];
    }

    /**
     * @notice Gets the total deposit amount for a specific token
     * @dev Returns the current deposit balance of a token in the contract
     * @param token Address of the token to query
     * @return Amount of token deposited
     */
    function getDeposit(address token) external view returns (uint256) {
        return _getTopUpDestStorage().deposits[token];
    }

    /**
     * @notice Calculates txId based on the input parameters
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param token Address of the token to send
     * @return bytes32 txId
     */
    function getTxId(bytes32 txHash, address user, address token) public pure returns (bytes32) {
        return keccak256(abi.encode(txHash, user, token));
    }

    /**
     * @notice Checks if a transaction has been processed
     * @dev Returns boolean indicating transaction status
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param token Address of the token to send
     * @return Boolean indicating whether the transaction has been processed
     */
    function isTransactionCompleted(bytes32 txHash, address user, address token) external view returns (bool) {
        return _getTopUpDestStorage().transactionCompleted[getTxId(txHash, user, token)];
    }

    /**
     * @notice Checks if a transaction has been processed based on txId
     * @dev Returns boolean indicating transaction status
     * @param txId Unique transaction identifier
     * @return Boolean indicating whether the transaction has been processed
     */
    function isTransactionCompletedByTxId(bytes32 txId) external view returns (bool) {
        return _getTopUpDestStorage().transactionCompleted[txId];
    }

    receive() external payable {
        weth.deposit{ value: msg.value }();
    }

    /**
     * @notice Internal function to transfer tokens to a recipient
     * @dev Checks balance before transferring
     * @param to Address of the recipient
     * @param token Address of the token to transfer
     * @param amount Amount of tokens to transfer
     * @custom:throws BalanceTooLow if the contract has insufficient token balance
     */
    function _transfer(address to, address token, uint256 amount) internal {
        if (IERC20(token).balanceOf(address(this)) < amount) revert BalanceTooLow();
        IERC20(token).safeTransfer(to, amount);
    }
}
