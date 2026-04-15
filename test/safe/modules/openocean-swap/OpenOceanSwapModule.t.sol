// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { OpenOceanSwapModule, ModuleBase, ModuleCheckBalance } from "../../../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager } from "../../SafeTestSetup.t.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";

contract OpenOceanSwapModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    OpenOceanSwapModule public openOceanSwapModule;
    address public openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    address public ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public override {
        super.setUp();

        openOceanSwapModule = new OpenOceanSwapModule(openOceanSwapRouter, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(openOceanSwapModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory setupData = new bytes[](1);

        _configureModules(modules, shouldWhitelist, setupData);
    }

    function test_swap_worksWithERC20toERC20() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        uint256 balanceBefore = weETH.balanceOf(address(safe));

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);

        uint256 nonceAfter = safe.nonce();
        uint256 balanceAfter = weETH.balanceOf(address(safe));

        assertEq(nonceBefore + 1, nonceAfter);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_swap_worksWithERC20toNative() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = ETH;
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        uint256 balanceBefore = address(safe).balance;

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);

        uint256 balanceAfter = address(safe).balance;

        assertGt(balanceAfter, balanceBefore);
    }

    function test_swap_worksWithNativeToERC20() public {
        address fromAsset = ETH;
        uint256 fromAssetAmount = 1 ether;
        address toAsset = address(usdc);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            18
        );

        deal(address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        uint256 balanceBefore = usdc.balanceOf(address(safe));

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);

        uint256 balanceAfter = usdc.balanceOf(address(safe));

        assertGt(balanceAfter, balanceBefore);
    }

    function test_swap_revertsWhenSwappingToSameAsset() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(usdc); // Same asset
        uint256 minToAssetAmount = 1;
        bytes memory swapData = "";

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert(OpenOceanSwapModule.SwappingToSameAsset.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_revertsWhenInsufficientERC20Balance() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        // Not providing any balance to the safe
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_failsWhenPendingWithdrawalBlocksIt() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;

        deal(address(usdc), address(safe), fromAssetAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(fromAsset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        _requestWithdrawal(tokens, amounts, address(1));

        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_revertsWhenInsufficientNativeBalance() public {
        address fromAsset = ETH;
        uint256 fromAssetAmount = 1 ether;
        address toAsset = address(usdc);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            18
        );

        // Not providing any ETH to the safe
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_revertsWhenZeroMinimumOutput() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 0; // Zero minimum output
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_revertsWithInvalidSignature() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        // Create signature with wrong parameters (different amount)
        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount + 1, minToAssetAmount, swapData);

        vm.expectRevert(OpenOceanSwapModule.InvalidSignatures.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_revertsWhenNonAdminSigner() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        // Try with non-admin signer
        address nonAdmin = makeAddr("nonAdmin");
        owners[0] = nonAdmin;

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_correctlyIncrementsNonce() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 10e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid),
            address(safe),
            address(safe),
            fromAsset,
            toAsset,
            fromAssetAmount,
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);

        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);

        uint256 nonceAfter = safe.nonce();
        assertEq(nonceAfter, nonceBefore + 1);

        // Try to reuse the same signature (should fail due to nonce increment)
        vm.expectRevert(OpenOceanSwapModule.InvalidSignatures.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_whenMinimumOutputExceeds() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        // Set very high minimum output that can't be achieved
        uint256 minToAssetAmount = 1000 ether;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert();
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    function test_swap_reverts_whenUserCashPositionNotHealthy() public {
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );

        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdc), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = safe.nonce();

        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData, owners, signatures);
    }

    
    function _swapAndVerifyNonce(address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, uint256 nonceBefore) internal {
        // Use a smaller amount for the second swap to avoid price impact issues
        // The OpenOcean API quotes against live state, not the forked state
        uint256 smallAmount = fromAssetAmount / 10;
        bytes memory swapData2 = getQuoteOpenOcean(
            vm.toString(block.chainid),
            address(safe),
            address(safe),
            fromAsset,
            toAsset,
            smallAmount,
            IERC20Metadata(fromAsset).decimals()
        );
        (address[] memory owners2, bytes[] memory signatures2) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, smallAmount, minToAssetAmount, swapData2);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, smallAmount, minToAssetAmount, swapData2, owners2, signatures2);

        uint256 nonceFinal = safe.nonce();
        assertEq(nonceFinal, nonceBefore + 1);
    }

    function _createSwapSignatures(
        uint256 nonceBefore, 
        address fromAsset, 
        address toAsset, 
        uint256 fromAssetAmount, 
        uint256 minToAssetAmount, 
        bytes memory swapData
    ) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            openOceanSwapModule.SWAP_SIG(), 
            block.chainid, 
            address(openOceanSwapModule), 
            nonceBefore, 
            address(safe), 
            abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData)
        )).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r1, s1, v1);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r2, s2, v2);

        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = signature1;
        signatures[1] = signature2;

        return (owners, signatures);
    }

    function getQuoteOpenOcean(
        string memory chainId,
        address from,
        address to,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint8 srcTokenDecimals
    ) internal returns (bytes memory data) {
        string[] memory inputs = new string[](10);
        inputs[0] = "npx";
        inputs[1] = "tsx";
        inputs[2] = "test/getQuoteOpenOcean.ts";
        inputs[3] = chainId;
        inputs[4] = vm.toString(from);
        inputs[5] = vm.toString(to);
        inputs[6] = vm.toString(srcToken);
        inputs[7] = vm.toString(dstToken);
        inputs[8] = vm.toString(amount);
        inputs[9] = vm.toString(srcTokenDecimals);

        return vm.ffi(inputs);
    }

    /// @dev Minimal simpleSwap calldata (selector 0x0a9704d5) that exercises
    ///      the 9-field struct path.  Built from a real OpenOcean API response
    ///      for a WETH->USDT swap on Optimism; only the description header
    ///      matters for _validateSwapData -- the CallDescription[] tail is
    ///      trimmed to a single empty entry to keep the test small.
    function _buildSimpleSwapCalldata(
        address fromAsset,
        address toAsset,
        address dstReceiver,
        uint256 amount,
        uint256 minReturn
    ) internal pure returns (bytes memory) {
        // simpleSwap(address caller, SimpleDesc desc, CallDescription[] calls)
        // caller = address(0) (doesn't matter for validation)
        // desc = 9 fields, no guaranteedAmount
        // calls = empty array
        bytes memory inner = abi.encode(
            address(0),                     // caller
            _encodeSimpleDesc(fromAsset, toAsset, dstReceiver, amount, minReturn),
            new uint256[](0)                // empty CallDescription[]
        );
        return abi.encodePacked(bytes4(0x0a9704d5), inner);
    }

    struct _SimpleDesc {
        address srcToken;
        address dstToken;
        address srcReceiver;
        address dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
        address referrer;
        bytes permit;
    }

    function _encodeSimpleDesc(
        address fromAsset,
        address toAsset,
        address dstReceiver,
        uint256 amount,
        uint256 minReturn
    ) internal pure returns (_SimpleDesc memory) {
        return _SimpleDesc({
            srcToken: fromAsset,
            dstToken: toAsset,
            srcReceiver: address(0),
            dstReceiver: dstReceiver,
            amount: amount,
            minReturnAmount: minReturn,
            flags: 2,
            referrer: address(0),
            permit: ""
        });
    }

    function test_swap_simpleSwapCalldata_doesNotPanic() public {
        address fromAsset = address(usdc);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETH);
        uint256 minToAssetAmount = 1;

        bytes memory swapData = _buildSimpleSwapCalldata(fromAsset, toAsset, address(safe), fromAssetAmount, minToAssetAmount);

        deal(address(usdc), address(safe), fromAssetAmount);

        uint256 nonceBefore = safe.nonce();
        (address[] memory owners, bytes[] memory signatures) = _createSwapSignatures(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData);

        // The swap will revert at the router (empty CallDescription[]) but
        // the key assertion is that it does NOT revert with Panic(0x41).
        // If _validateSwapData still used the 10-field struct for this
        // simpleSwap selector, it would panic before even reaching the router.
        (bool ok, bytes memory ret) = address(openOceanSwapModule).call(
            abi.encodeWithSelector(
                openOceanSwapModule.swap.selector,
                address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount,
                swapData, owners, signatures
            )
        );

        if (!ok && ret.length == 36) {
            bytes4 sig;
            uint256 code;
            assembly { sig := mload(add(ret, 32)) code := mload(add(ret, 36)) }
            assertTrue(sig != 0x4e487b71 || code != 0x41, "must not Panic(0x41)");
        }
        // Any non-Panic revert is fine -- it means _validateSwapData succeeded
        // and the revert came from the router or downstream.
    }

    function _requestWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, recipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, signers, signatures);
    }
}
