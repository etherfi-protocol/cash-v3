// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title StockMigrationDistributor
 * @notice Pays every holder of a retired collateral token its share of the replacement token from a
 *         published snapshot. The owner funds the contract and sets one Merkle root over the snapshot's
 *         (token, recipient, shares) rows, once. From then on anyone may push any row to its recipient; a
 *         row pays out at most once. The owner can pause and sweep, and cannot change who gets what.
 * @dev Leaves follow the OpenZeppelin StandardMerkleTree encoding so the JavaScript tree builder and this
 *      contract agree: keccak256(bytes.concat(keccak256(abi.encode(token, recipient, shares)))).
 * @author ether.fi
 */
contract StockMigrationDistributor is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    struct Leaf {
        address token;
        address recipient;
        uint256 shares;
    }

    /// @notice The snapshot root; zero until set
    bytes32 public root;
    /// @notice Whether a leaf has been paid, by leaf hash
    mapping(bytes32 leafHash => bool) public paid;

    event RootSet(bytes32 indexed root);
    event Distributed(address indexed token, address indexed recipient, uint256 shares);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error RootAlreadySet();
    error RootNotSet();
    error InvalidRoot();
    error InvalidProof();
    error AlreadyPaid();
    error InvalidAddress();
    error LengthMismatch();
    error RenounceDisabled();

    constructor(address _owner) Ownable(_owner) { }

    /// @notice Publishes the snapshot root. Callable once.
    function setRoot(bytes32 _root) external onlyOwner {
        if (root != bytes32(0)) revert RootAlreadySet();
        if (_root == bytes32(0)) revert InvalidRoot();
        root = _root;
        emit RootSet(_root);
    }

    /// @notice Pays one snapshot row to its recipient. Anyone may call. Reverts if already paid.
    function distribute(Leaf calldata leaf, bytes32[] calldata proof) external whenNotPaused {
        if (!_distribute(leaf, proof)) revert AlreadyPaid();
    }

    /// @notice Pays many rows; rows already paid are skipped so a rerun finishes what an earlier run left.
    /// @return The number of rows paid in this call
    function distributeMany(Leaf[] calldata leaves, bytes32[][] calldata proofs) external whenNotPaused returns (uint256) {
        if (leaves.length != proofs.length) revert LengthMismatch();
        uint256 count;
        for (uint256 i = 0; i < leaves.length; ++i) {
            if (_distribute(leaves[i], proofs[i])) ++count;
        }
        return count;
    }

    /// @notice The hash of a row, as stored in `paid` and as the tree leaf
    function leafHash(Leaf calldata leaf) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(leaf.token, leaf.recipient, leaf.shares))));
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled: without an owner the root could never be set and funds could never be swept
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Returns the contract's whole balance of `token` to `to`. Owner only, any time.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    function _distribute(Leaf calldata leaf, bytes32[] calldata proof) internal returns (bool) {
        if (root == bytes32(0)) revert RootNotSet();
        if (leaf.recipient == address(0)) revert InvalidAddress();
        bytes32 hash = leafHash(leaf);
        if (!MerkleProof.verifyCalldata(proof, root, hash)) revert InvalidProof();
        if (paid[hash]) return false;
        paid[hash] = true;
        IERC20(leaf.token).safeTransfer(leaf.recipient, leaf.shares);
        emit Distributed(leaf.token, leaf.recipient, leaf.shares);
        return true;
    }
}
