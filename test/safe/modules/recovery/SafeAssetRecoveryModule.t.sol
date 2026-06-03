// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { ISafeAssetRecoveryModule } from "../../../../src/interfaces/ISafeAssetRecoveryModule.sol";
import { SafeAssetRecoveryModule } from "../../../../src/modules/recovery/SafeAssetRecoveryModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { RoleRegistry } from "../../../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafe.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";

/// @dev ERC20 that returns `false` from transfer without moving funds — exercises the post-transfer
///      balance assertion in `recover`.
contract FalseTransferToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
}

contract SafeAssetRecoveryModuleTest is SafeTestSetup {
    SafeAssetRecoveryModule public module;
    MockERC20 public token;
    address public safeAddr;
    address public recipient = makeAddr("recipient");

    function setUp() public override {
        super.setUp();
        safeAddr = address(safe);

        vm.startPrank(owner);
        module = new SafeAssetRecoveryModule(address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        token = new MockERC20("Stuck", "STUCK", 18);
        vm.stopPrank();
    }

    function test_recover_happyPath_sweepsFullBalanceAndEmits() public {
        uint256 amount = 1_000e18;
        token.mint(safeAddr, amount);

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(token), recipient);

        vm.expectEmit(true, true, true, true, address(module));
        emit ISafeAssetRecoveryModule.AssetRecovered(safeAddr, address(token), recipient, amount);
        module.recover(safeAddr, address(token), recipient, signers, sigs);

        assertEq(token.balanceOf(recipient), amount, "recipient balance");
        assertEq(token.balanceOf(safeAddr), 0, "safe drained");
    }

    function test_recover_revertsIfTokenZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(0), recipient);
        vm.expectRevert(ISafeAssetRecoveryModule.InvalidToken.selector);
        module.recover(safeAddr, address(0), recipient, signers, sigs);
    }

    function test_recover_revertsIfRecipientZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(token), address(0));
        vm.expectRevert(ISafeAssetRecoveryModule.InvalidRecipient.selector);
        module.recover(safeAddr, address(token), address(0), signers, sigs);
    }

    function test_recover_revertsIfSupportedToken() public {
        // usdc is configured as a cash collateral/borrow token in SafeTestSetup.
        token.mint(safeAddr, 0); // no-op; ensure compiler keeps token ref
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(usdc), recipient);
        vm.expectRevert(ISafeAssetRecoveryModule.OnlySupportedTokensCannotBeRecovered.selector);
        module.recover(safeAddr, address(usdc), recipient, signers, sigs);
    }

    function test_recover_revertsIfZeroBalance() public {
        // token unsupported but safe holds none.
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(token), recipient);
        vm.expectRevert(ISafeAssetRecoveryModule.NoBalanceToRecover.selector);
        module.recover(safeAddr, address(token), recipient, signers, sigs);
    }

    function test_recover_revertsIfBadSignature() public {
        token.mint(safeAddr, 1e18);
        // sign over `recipient`, submit a different recipient -> digest mismatch.
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(token), recipient);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover(safeAddr, address(token), makeAddr("other"), signers, sigs);
    }

    function test_recover_digestReplayReverts() public {
        token.mint(safeAddr, 2e18);
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(token), recipient);

        module.recover(safeAddr, address(token), recipient, signers, sigs);
        // nonce advanced; same sigs no longer match.
        token.mint(safeAddr, 2e18);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover(safeAddr, address(token), recipient, signers, sigs);
    }

    function test_recover_revertsWhenPaused() public {
        vm.prank(pauser);
        module.pause();

        token.mint(safeAddr, 1e18);
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(token), recipient);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        module.recover(safeAddr, address(token), recipient, signers, sigs);
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        module.pause();
    }

    function test_recover_revertsIfModuleNotEnabledOnSafe() public {
        // A second module: whitelisted on the data provider but NOT enabled on the safe.
        SafeAssetRecoveryModule module2 = new SafeAssetRecoveryModule(address(dataProvider));
        address[] memory mods = new address[](1);
        mods[0] = address(module2);
        bool[] memory wl = new bool[](1);
        wl[0] = true;
        vm.prank(owner);
        dataProvider.configureModules(mods, wl);

        token.mint(safeAddr, 1e18);
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module2), address(token), recipient);
        // Signature + support + balance pass; execTransactionFromModule rejects the unenabled module.
        vm.expectRevert(EtherFiSafeErrors.OnlyModules.selector);
        module2.recover(safeAddr, address(token), recipient, signers, sigs);
    }

    function test_recover_revertsOnFalseReturningToken() public {
        FalseTransferToken bad = new FalseTransferToken();
        bad.mint(safeAddr, 5e18);
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(module), address(bad), recipient);
        vm.expectRevert(ISafeAssetRecoveryModule.RecoveryTransferFailed.selector);
        module.recover(safeAddr, address(bad), recipient, signers, sigs);
    }

    // --- helpers ---

    function _signRecover(address module_, address token_, address recipient_)
        internal
        view
        returns (address[] memory signers, bytes[] memory sigs)
    {
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            module_,
            SafeAssetRecoveryModule(module_).getNonce(safeAddr),
            safeAddr,
            token_,
            recipient_
        ));

        signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
