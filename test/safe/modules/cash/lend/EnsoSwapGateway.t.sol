// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { EnsoSwapModule } from "../../../../../src/enso/EnsoSwapModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev Minimal Enso Router stand-in: pulls the input from the caller (the safe) and, for the
///      same-chain shape, pays a pre-funded output to the recipient. Lets the sandwich be asserted
///      against the real LendGateway without live Enso calldata.
contract EnsoRouterStub {
    function swap(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function swapTo(address srcToken, uint256 srcAmount, address dstToken, address recipient, uint256 dstAmount) external {
        IERC20(srcToken).transferFrom(msg.sender, address(this), srcAmount);
        IERC20(dstToken).transfer(recipient, dstAmount);
    }
}

/**
 * @title EnsoSwapGatewayTest
 * @notice Exercises EnsoSwapModule's Aave sandwich against the real LendGateway: a gateway safe's
 *         input may be supplied to Aave, so the request-time sourcing (CashModule hold) and the
 *         module's execute-time bookends must withdraw it back, swap, and re-supply a same-chain
 *         output delivered to the safe. Runs on the Optimism fork under the lend profile.
 */
contract EnsoSwapGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    EnsoSwapModule internal swapModule;
    EnsoRouterStub internal router;
    address internal keeper = makeAddr("keeper");

    uint256 internal constant SRC_AMOUNT = 1_000e6;
    uint256 internal constant OUT_AMOUNT = 1 ether;

    function setUp() public override {
        super.setUp();

        router = new EnsoRouterStub();
        address impl = address(new EnsoSwapModule(address(dataProvider)));
        swapModule = EnsoSwapModule(address(new UUPSProxy(
            impl,
            abi.encodeWithSelector(EnsoSwapModule.initialize.selector, address(roleRegistry), address(router))
        )));
        _enableModule(address(swapModule));

        vm.startPrank(owner);
        cashModule.configureModulesCanRequestWithdraw(_addr1(address(swapModule)), _bool1(true));
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(swapModule), true);
        vm.stopPrank();
    }

    // The whole flow sources from Aave: request-time sourcing pulls the supplied input loose, and the
    // executed same-chain swap re-supplies the output to Aave as collateral. Nothing is left loose.
    function test_executeSwap_sourcesInputFromAaveAndResuppliesSameChainOutput() public {
        _supplyToGateway(address(safe), address(usdc), SRC_AMOUNT);
        assertEq(usdc.balanceOf(address(safe)), 0, "fixture: input sits in Aave, not loose");

        deal(address(weETH), address(router), OUT_AMOUNT);
        EnsoSwapModule.Order memory order = _sameChainOrderToSafe();
        bytes memory swapData = abi.encodeCall(
            EnsoRouterStub.swapTo, (address(usdc), SRC_AMOUNT, address(weETH), address(safe), OUT_AMOUNT)
        );
        _request(order, swapData);

        // Request-time sourcing (CashModule hold) pulled the input out of Aave into the safe.
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 0, 1, "input not pulled from Aave at request");
        assertEq(usdc.balanceOf(address(safe)), SRC_AMOUNT, "input not loose after request");

        _warpPastDelay();
        vm.prank(keeper);
        swapModule.executeSwap(address(safe));

        assertEq(usdc.balanceOf(address(safe)), 0, "input not consumed by the router");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), OUT_AMOUNT, 1, "output not re-supplied to Aave");
        assertEq(weETH.balanceOf(address(safe)), 0, "output left loose in safe");
    }

    // The execute-time front bookend: the input was loose at request (no pull), then got supplied into
    // Aave during the withdrawal delay. executeSwap must pull the shortfall back out to fund the swap.
    function test_executeSwap_pullsShortfallSuppliedDuringDelay() public {
        deal(address(usdc), address(safe), SRC_AMOUNT);
        _request(_crossChainOrder(), abi.encodeCall(EnsoRouterStub.swap, (address(usdc), SRC_AMOUNT)));

        // Simulate the loose input landing in Aave during the delay window.
        vm.startPrank(driver);
        gw.supply(address(safe), address(usdc), SRC_AMOUNT);
        gw.setUsingAsCollateral(address(safe), address(usdc), true);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(safe)), 0, "fixture: input moved into Aave");

        _warpPastDelay();
        vm.prank(keeper);
        swapModule.executeSwap(address(safe));

        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 0, 2, "shortfall not pulled from Aave at execute");
        assertEq(usdc.balanceOf(address(safe)), 0, "input not consumed by the router");
    }

    // The sandwich is engine-gated: a legacy safe's swap must not touch Aave — the output stays loose
    // where the DebtManager can see it.
    function test_executeSwap_legacySafe_outputStaysLoose() public {
        _forceLegacyEngine(address(safe));
        deal(address(usdc), address(safe), SRC_AMOUNT);
        deal(address(weETH), address(router), OUT_AMOUNT);

        EnsoSwapModule.Order memory order = _sameChainOrderToSafe();
        bytes memory swapData = abi.encodeCall(
            EnsoRouterStub.swapTo, (address(usdc), SRC_AMOUNT, address(weETH), address(safe), OUT_AMOUNT)
        );
        _request(order, swapData);
        _warpPastDelay();

        vm.prank(keeper);
        swapModule.executeSwap(address(safe));

        assertEq(weETH.balanceOf(address(safe)), OUT_AMOUNT, "output must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "output must not be supplied to Aave");
    }

    // ---- Helpers ----

    function _sameChainOrderToSafe() internal view returns (EnsoSwapModule.Order memory) {
        return EnsoSwapModule.Order({
            srcToken: address(usdc),
            srcAmount: SRC_AMOUNT,
            dstChainId: block.chainid,
            dstToken: address(weETH),
            recipient: address(safe),
            minOut: OUT_AMOUNT,
            deadline: block.timestamp + 3 days
        });
    }

    function _crossChainOrder() internal returns (EnsoSwapModule.Order memory) {
        return EnsoSwapModule.Order({
            srcToken: address(usdc),
            srcAmount: SRC_AMOUNT,
            dstChainId: 1,
            dstToken: makeAddr("dstToken"),
            recipient: makeAddr("dstRecipient"),
            minOut: 1,
            deadline: block.timestamp + 3 days
        });
    }

    function _request(EnsoSwapModule.Order memory order, bytes memory swapData) internal {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("EnsoSwapModule.requestSwap"),
            block.chainid,
            address(swapModule),
            safe.nonce(),
            address(safe),
            abi.encode(order),
            keccak256(swapData),
            swapModule.getEnsoRouter()
        )).toEthSignedMessageHash();
        (address[] memory signers, bytes[] memory sigs) = _twoSig(digest);
        swapModule.requestSwap(address(safe), order, swapData, signers, sigs);
    }

    function _twoSig(bytes32 digest) internal view returns (address[] memory, bytes[] memory) {
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);
        return (signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }
}
