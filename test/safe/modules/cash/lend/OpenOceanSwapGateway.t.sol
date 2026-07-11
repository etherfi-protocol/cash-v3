// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { OpenOceanSwapModule } from "../../../../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title OpenOceanSwapGatewayTest
 * @notice Exercises the swap module's Aave sandwich against the real LendGateway: the input is supplied to
 *         Aave, so the swap must withdraw it back, swap through OpenOcean, and re-supply the output. Uses live
 *         OpenOcean quotes (FFI) on the Optimism fork, so run under the lend profile with FFI enabled.
 */
contract OpenOceanSwapGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    OpenOceanSwapModule internal swapModule;
    address internal openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    function setUp() public override {
        super.setUp();

        swapModule = new OpenOceanSwapModule(openOceanSwapRouter, address(dataProvider));
        _enableModule(address(swapModule));

        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        vm.prank(owner);
        gw.setDriver(address(swapModule), true);
    }

    // A swap sources its input entirely from Aave: the module withdraws the supplied input, swaps it, and
    // re-supplies the registered output as collateral. Nothing is left loose in the safe.
    function test_swap_sourcesInputFromAaveAndResuppliesOutput() public {
        uint256 supplyAmount = 1 ether;
        _supplyToGateway(address(safe), address(weETH), supplyAmount);

        uint256 weethSuppliedBefore = gw.suppliedOf(address(safe), address(weETH));
        uint256 usdcSuppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        bytes memory swapData = _quote(address(weETH), address(usdc), supplyAmount, IERC20Metadata(address(weETH)).decimals());
        (address[] memory signers, bytes[] memory signatures) = _swapSignatures(safe.nonce(), address(weETH), address(usdc), supplyAmount, 1, swapData);

        swapModule.swap(address(safe), address(weETH), address(usdc), supplyAmount, 1, swapData, signers, signatures);

        // Input pulled out of Aave, output supplied back and marked as collateral, nothing left loose.
        assertEq(gw.suppliedOf(address(safe), address(weETH)), weethSuppliedBefore - supplyAmount, "weETH not withdrawn from Aave");
        assertGt(gw.suppliedOf(address(safe), address(usdc)), usdcSuppliedBefore, "USDC output not re-supplied");
        assertEq(weETH.balanceOf(address(safe)), 0, "weETH left loose in safe");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC output left loose in safe");
    }

    // The sandwich is engine-gated, not opt-out-gated: a legacy safe still reports isLendEnabled true, yet
    // its swap must not touch Aave — the output stays loose where the DebtManager can see it.
    function test_swap_legacySafe_outputStaysLoose() public {
        _forceLegacyEngine(address(safe));
        assertTrue(gw.isLendEnabled(address(safe)), "fixture: a legacy safe still reports lend enabled");

        uint256 swapAmount = 1 ether;
        deal(address(weETH), address(safe), swapAmount);

        bytes memory swapData = _quote(address(weETH), address(usdc), swapAmount, IERC20Metadata(address(weETH)).decimals());
        (address[] memory signers, bytes[] memory signatures) = _swapSignatures(safe.nonce(), address(weETH), address(usdc), swapAmount, 1, swapData);

        swapModule.swap(address(safe), address(weETH), address(usdc), swapAmount, 1, swapData, signers, signatures);

        assertGt(usdc.balanceOf(address(safe)), 0, "output must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "output must not be supplied to Aave");
    }

    function _quote(address srcToken, address dstToken, uint256 amount, uint8 srcTokenDecimals) internal returns (bytes memory) {
        string[] memory inputs = new string[](10);
        inputs[0] = "npx";
        inputs[1] = "tsx";
        inputs[2] = "test/getQuoteOpenOcean.ts";
        inputs[3] = vm.toString(block.chainid);
        inputs[4] = vm.toString(address(safe));
        inputs[5] = vm.toString(address(safe));
        inputs[6] = vm.toString(srcToken);
        inputs[7] = vm.toString(dstToken);
        inputs[8] = vm.toString(amount);
        inputs[9] = vm.toString(srcTokenDecimals);
        return vm.ffi(inputs);
    }

    function _swapSignatures(uint256 nonce, address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, bytes memory swapData)
        internal
        view
        returns (address[] memory, bytes[] memory)
    {
        bytes32 digestHash = keccak256(
            abi.encodePacked(swapModule.SWAP_SIG(), block.chainid, address(swapModule), nonce, address(safe), abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, swapData))
        ).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        return (signers, signatures);
    }
}
