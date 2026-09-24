// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Hashes } from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import { Test } from "forge-std/Test.sol";

import { StockMigrationDistributor } from "../../src/migration/StockMigrationDistributor.sol";

/// @dev A four-leaf tree built the way OpenZeppelin's StandardMerkleTree builds it: double-hashed leaves,
///      commutative pair hashing, so proofs from the JavaScript builder verify against the same root.
abstract contract MerkleFixture is Test {
    function _hash(StockMigrationDistributor.Leaf memory l) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(l.token, l.recipient, l.shares))));
    }

    function _root(StockMigrationDistributor.Leaf[4] memory leaves) internal pure returns (bytes32) {
        return Hashes.commutativeKeccak256(Hashes.commutativeKeccak256(_hash(leaves[0]), _hash(leaves[1])), Hashes.commutativeKeccak256(_hash(leaves[2]), _hash(leaves[3])));
    }

    function _proof(StockMigrationDistributor.Leaf[4] memory leaves, uint256 i) internal pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = _hash(leaves[i ^ 1]);
        proof[1] = Hashes.commutativeKeccak256(_hash(leaves[(i ^ 2) & 2]), _hash(leaves[((i ^ 2) & 2) + 1]));
        return proof;
    }
}

contract StockMigrationDistributorTest is MerkleFixture {
    address owner = makeAddr("operatingSafe");
    address stranger = makeAddr("stranger");
    ERC20Mock tokenA;
    ERC20Mock tokenB;
    StockMigrationDistributor distributor;
    StockMigrationDistributor.Leaf[4] leaves;
    bytes32 root;

    function setUp() public {
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        distributor = new StockMigrationDistributor(owner);
        leaves[0] = StockMigrationDistributor.Leaf(address(tokenA), makeAddr("safe1"), 100e18);
        leaves[1] = StockMigrationDistributor.Leaf(address(tokenA), makeAddr("safe2"), 25e18);
        leaves[2] = StockMigrationDistributor.Leaf(address(tokenB), makeAddr("safe1"), 7e18);
        leaves[3] = StockMigrationDistributor.Leaf(address(tokenB), makeAddr("wallet"), 1e15);
        root = _root(leaves);
        tokenA.mint(address(distributor), 125e18);
        tokenB.mint(address(distributor), 7e18 + 1e15);
    }

    function _setRoot() internal {
        vm.prank(owner);
        distributor.setRoot(root);
    }

    function test_setRoot_onceAndNonZero() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.setRoot(root);

        vm.prank(owner);
        vm.expectRevert(StockMigrationDistributor.InvalidRoot.selector);
        distributor.setRoot(bytes32(0));

        vm.prank(owner);
        vm.expectEmit();
        emit StockMigrationDistributor.RootSet(root);
        distributor.setRoot(root);
        assertEq(distributor.root(), root);

        vm.prank(owner);
        vm.expectRevert(StockMigrationDistributor.RootAlreadySet.selector);
        distributor.setRoot(keccak256("other"));
    }

    function test_distribute_beforeRootReverts() public {
        vm.expectRevert(StockMigrationDistributor.RootNotSet.selector);
        distributor.distribute(leaves[0], _proof(leaves, 0));
    }

    function test_distribute_paysOnceFromAnyCaller() public {
        _setRoot();
        vm.prank(stranger);
        vm.expectEmit();
        emit StockMigrationDistributor.Distributed(address(tokenA), leaves[0].recipient, 100e18);
        distributor.distribute(leaves[0], _proof(leaves, 0));
        assertEq(tokenA.balanceOf(leaves[0].recipient), 100e18);
        assertTrue(distributor.paid(_hash(leaves[0])));

        vm.expectRevert(StockMigrationDistributor.AlreadyPaid.selector);
        distributor.distribute(leaves[0], _proof(leaves, 0));
        assertEq(tokenA.balanceOf(leaves[0].recipient), 100e18);
    }

    function test_distribute_rejectsTamperedLeafOrProof() public {
        _setRoot();
        StockMigrationDistributor.Leaf memory inflated = leaves[1];
        inflated.shares = 26e18;
        vm.expectRevert(StockMigrationDistributor.InvalidProof.selector);
        distributor.distribute(inflated, _proof(leaves, 1));

        vm.expectRevert(StockMigrationDistributor.InvalidProof.selector);
        distributor.distribute(leaves[1], _proof(leaves, 2));
        assertEq(tokenA.balanceOf(leaves[1].recipient), 0);
    }

    function test_distributeMany_skipsPaidAndCounts() public {
        _setRoot();
        distributor.distribute(leaves[2], _proof(leaves, 2));

        StockMigrationDistributor.Leaf[] memory batch = new StockMigrationDistributor.Leaf[](4);
        bytes32[][] memory proofs = new bytes32[][](4);
        for (uint256 i = 0; i < 4; ++i) {
            batch[i] = leaves[i];
            proofs[i] = _proof(leaves, i);
        }
        assertEq(distributor.distributeMany(batch, proofs), 3);
        assertEq(distributor.distributeMany(batch, proofs), 0);
        assertEq(tokenA.balanceOf(address(distributor)), 0);
        assertEq(tokenB.balanceOf(address(distributor)), 0);
        assertEq(tokenB.balanceOf(leaves[3].recipient), 1e15);
    }

    function test_distributeMany_badLeafRevertsWholeBatch() public {
        _setRoot();
        StockMigrationDistributor.Leaf[] memory batch = new StockMigrationDistributor.Leaf[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        batch[0] = leaves[0];
        proofs[0] = _proof(leaves, 0);
        batch[1] = leaves[1];
        proofs[1] = _proof(leaves, 3);
        vm.expectRevert(StockMigrationDistributor.InvalidProof.selector);
        distributor.distributeMany(batch, proofs);
        assertEq(tokenA.balanceOf(leaves[0].recipient), 0);

        bytes32[][] memory tooFew = new bytes32[][](1);
        vm.expectRevert(StockMigrationDistributor.LengthMismatch.selector);
        distributor.distributeMany(batch, tooFew);
    }

    function test_pause_blocksDistributeUntilUnpaused() public {
        _setRoot();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.pause();

        vm.prank(owner);
        distributor.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.distribute(leaves[0], _proof(leaves, 0));

        vm.prank(owner);
        distributor.unpause();
        distributor.distribute(leaves[0], _proof(leaves, 0));
        assertEq(tokenA.balanceOf(leaves[0].recipient), 100e18);
    }

    function test_sweep_ownerOnlyAnyTime() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.sweep(address(tokenA), owner);

        vm.prank(owner);
        vm.expectRevert(StockMigrationDistributor.InvalidAddress.selector);
        distributor.sweep(address(tokenA), address(0));

        _setRoot();
        distributor.distribute(leaves[1], _proof(leaves, 1));
        vm.prank(owner);
        vm.expectEmit();
        emit StockMigrationDistributor.Swept(address(tokenA), owner, 100e18);
        distributor.sweep(address(tokenA), owner);
        assertEq(tokenA.balanceOf(owner), 100e18);
        assertEq(tokenA.balanceOf(address(distributor)), 0);
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        distributor.renounceOwnership();

        vm.prank(owner);
        vm.expectRevert(StockMigrationDistributor.RenounceDisabled.selector);
        distributor.renounceOwnership();
        assertEq(distributor.owner(), owner);
    }
}

/// @notice Against live Optimism: the real wSPYx wrapper moves through the distributor to live safes.
contract StockMigrationDistributorForkTest is MerkleFixture {
    address constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Holds a little wSPYx from the real deposit test
    address constant FUNDER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address constant SAFE_A = 0x0FCDa4D56Ce5Ade64031A66C2838401f3448e1A9;
    address constant SAFE_B = 0x9daAa8268781dA4538610b1F8851E48f7b6c3c54;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
    }

    function test_fork_realWrapperReachesSafes() public {
        uint256 pot = IERC20(WSPYX).balanceOf(FUNDER);
        assertGt(pot, 4, "funder holds no wSPYx");
        StockMigrationDistributor distributor = new StockMigrationDistributor(OPERATING_SAFE);
        vm.prank(FUNDER);
        IERC20(WSPYX).transfer(address(distributor), pot);

        StockMigrationDistributor.Leaf[4] memory leaves = [StockMigrationDistributor.Leaf(WSPYX, SAFE_A, pot / 2), StockMigrationDistributor.Leaf(WSPYX, SAFE_B, pot / 4), StockMigrationDistributor.Leaf(WSPYX, makeAddr("wallet"), pot / 8), StockMigrationDistributor.Leaf(WSPYX, OPERATING_SAFE, pot - pot / 2 - pot / 4 - pot / 8)];
        vm.prank(OPERATING_SAFE);
        distributor.setRoot(_root(leaves));

        uint256[4] memory before = [IERC20(WSPYX).balanceOf(SAFE_A), IERC20(WSPYX).balanceOf(SAFE_B), 0, IERC20(WSPYX).balanceOf(OPERATING_SAFE)];
        StockMigrationDistributor.Leaf[] memory batch = new StockMigrationDistributor.Leaf[](4);
        bytes32[][] memory proofs = new bytes32[][](4);
        for (uint256 i = 0; i < 4; ++i) {
            batch[i] = leaves[i];
            proofs[i] = _proof(leaves, i);
        }
        assertEq(distributor.distributeMany(batch, proofs), 4);
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(IERC20(WSPYX).balanceOf(leaves[i].recipient) - before[i], leaves[i].shares, "recipient did not receive its leaf");
        }
        assertEq(IERC20(WSPYX).balanceOf(address(distributor)), 0);
    }
}
