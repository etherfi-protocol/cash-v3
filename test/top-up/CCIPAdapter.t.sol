// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EVM2AnyMessage, EVMTokenAmount, GENERIC_EXTRA_ARGS_V2_TAG, GenericExtraArgsV2, ICCIPRouter } from "../../src/interfaces/ICCIPRouter.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { BridgeAdapterBase } from "../../src/top-up/bridge/BridgeAdapterBase.sol";
import { CCIPAdapter } from "../../src/top-up/bridge/CCIPAdapter.sol";
import { Constants } from "../../src/utils/Constants.sol";

/**
 * @title CCIPAdapterTest
 * @notice Mainnet-fork tests for `CCIPAdapter`, bridging Frankencoin (ZCHF) to OP Mainnet
 *         through the real Chainlink CCIP Router.
 * @dev ZCHF is a Chainlink CCT with a `BurnMintTokenPool 1.5.1` on both ends of this lane,
 *      so the transfer is strictly 1:1 and there is no slippage to assert on.
 */
contract CCIPAdapterTest is Test, Constants {
    TopUpFactory factory;
    RoleRegistry roleRegistry;
    CCIPAdapter ccipAdapter;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address dataProvider = makeAddr("dataProvider");

    /// @dev CCIP Router v1.2.0 on Ethereum mainnet.
    address constant CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    /// @dev CCIP chain selector for OP Mainnet — not a chain id, and not an LZ EID.
    uint64 constant OP_CHAIN_SELECTOR = 3734403246176062136;
    uint256 constant OP_CHAIN_ID = 10;

    /// @dev Frankencoin (ZCHF) on mainnet; its OP counterpart is 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553.
    IERC20 constant zchf = IERC20(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);
    /// @dev ZCHF's `BurnMintTokenPool` on mainnet. The lane's source-side burner.
    address constant ZCHF_POOL = 0x9359cd75549DaE00Cdd8D22297BC9B13FbBe4B79;
    IERC20 constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    /// @dev weETH is deliberately NOT one of the 25 tokens registered on the mainnet → OP
    ///      lane, so it stands in for "configured token has no CCIP pool here".
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    uint256 constant AMOUNT = 100 ether; // ZCHF is 18 decimals

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC");
        if (bytes(rpcUrl).length == 0) rpcUrl = "https://mainnet.gateway.tenderly.co";
        // Pin a block at which the ZCHF pool is registered on the mainnet → OP lane, so
        // the fork tests stay deterministic.
        vm.createSelectFork(rpcUrl, 25790000);

        vm.startPrank(owner);
        ccipAdapter = new CCIPAdapter();

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        TopUp topUpImpl = new TopUp(address(weth));
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(topUpImpl))))));

        _configure(address(zchf));

        roleRegistry.grantRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), address(this));
        vm.stopPrank();
    }

    /// @dev Registers `token` on the CCIP adapter for the OP lane. Slippage is 0 bps
    ///      because CCIP burn/mint pools move the amount 1:1 — the adapter ignores it.
    function _configure(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(ccipAdapter), recipientOnDestChain: alice, maxSlippageInBps: 0, additionalData: abi.encode(CCIP_ROUTER, OP_CHAIN_SELECTOR) });
        factory.setTokenConfig(tokens, chainIds, configs);
    }

    /// @dev Builds the same token-only message the adapter builds, but with `extraArgs`
    ///      as the caller supplies them, so a test can price one encoding against another.
    function _message(bytes memory extraArgs) internal view returns (EVM2AnyMessage memory) {
        EVMTokenAmount[] memory tokenAmounts = new EVMTokenAmount[](1);
        tokenAmounts[0] = EVMTokenAmount({ token: address(zchf), amount: AMOUNT });
        return EVM2AnyMessage({ receiver: abi.encode(alice), data: new bytes(0), tokenAmounts: tokenAmounts, feeToken: address(0), extraArgs: extraArgs });
    }

    function test_getBridgeFee_returnsNonZeroEthFee() public view {
        (address feeToken, uint256 fee) = factory.getBridgeFee(address(zchf), AMOUNT, OP_CHAIN_ID);
        assertEq(feeToken, ETH, "CCIP fee must be quoted in native, the only token TopUpFactory can fund from msg.value");
        assertGt(fee, 0, "CCIP native fee should be nonzero");
    }

    function test_bridge_burnsZchfAndSpendsExactlyTheQuotedFee() public {
        deal(address(zchf), address(factory), AMOUNT);
        // Give the factory ETH beyond the fee. The Router v1.2.0 wraps the WHOLE msg.value
        // and refunds nothing above the quote, so an adapter that forwarded its balance
        // rather than the quote would donate this idle ETH to Chainlink. Without a surplus
        // to strand, that bug is invisible.
        uint256 idleEth = 5 ether;
        vm.deal(address(factory), idleEth);

        (, uint256 fee) = factory.getBridgeFee(address(zchf), AMOUNT, OP_CHAIN_ID);
        uint256 supplyBefore = zchf.totalSupply();
        uint256 poolBalanceBefore = zchf.balanceOf(ZCHF_POOL);

        vm.recordLogs();
        factory.bridge{ value: fee }(address(zchf), AMOUNT, OP_CHAIN_ID);

        assertEq(zchf.balanceOf(address(factory)), 0, "all ZCHF should have left the factory");
        assertEq(address(factory).balance, idleEth, "adapter must send exactly the quoted fee, never its whole balance");
        assertEq(zchf.allowance(address(factory), CCIP_ROUTER), 0, "Router pulls exactly `amount`, so no allowance should remain");
        assertEq(supplyBefore - zchf.totalSupply(), AMOUNT, "burn/mint pool should have burned the full amount 1:1");
        assertEq(zchf.balanceOf(ZCHF_POOL), poolBalanceBefore, "a burn/mint pool should burn the tokens, not accumulate them");

        assertTrue(_bridgeViaCcipMessageId(vm.getRecordedLogs()) != bytes32(0), "CCIP messageId should be nonzero");
    }

    /// @dev The adapter's own fee guard cannot be reached through `TopUpFactory.bridge()`
    ///      — the factory already requires `msg.value >= fee`, and that value is part of
    ///      the balance the delegatecalled adapter sees. Exercise it directly instead.
    function test_bridge_revertsWhenAdapterCannotCoverTheFee() public {
        assertEq(address(ccipAdapter).balance, 0, "premise: adapter holds no ETH");
        vm.expectRevert(BridgeAdapterBase.InsufficientNativeFee.selector);
        ccipAdapter.bridge(address(zchf), AMOUNT, alice, 0, abi.encode(CCIP_ROUTER, OP_CHAIN_SELECTOR));
    }

    /// @dev CCIP can only move a token that has a pool registered for the lane; a config
    ///      naming any other token is unusable rather than silently lossy.
    function test_bridge_revertsForTokenWithNoPoolOnTheLane() public {
        vm.prank(owner);
        _configure(WEETH);
        deal(WEETH, address(factory), AMOUNT);

        // Raised out of the Router's quote, so the factory's internal fee pre-check trips
        // before the delegatecall — the misconfiguration can't even be priced.
        vm.expectRevert(abi.encodeWithSelector(ICCIPRouter.UnsupportedToken.selector, WEETH));
        factory.bridge{ value: 1 ether }(WEETH, AMOUNT, OP_CHAIN_ID);
    }

    /// @dev Pins the property documented in the adapter natspec: the message is a
    ///      token-only transfer, so `extraArgs` carries `gasLimit: 0`. Leaving `extraArgs`
    ///      empty makes CCIP bill the default 200k gas limit for a `ccipReceive` that the
    ///      OffRamp never calls, so the zero-gas encoding must quote strictly cheaper.
    function test_zeroGasLimitExtraArgsQuoteCheaperThanCcipDefault() public view {
        (, uint256 adapterFee) = factory.getBridgeFee(address(zchf), AMOUNT, OP_CHAIN_ID);
        uint256 defaultGasFee = ICCIPRouter(CCIP_ROUTER).getFee(OP_CHAIN_SELECTOR, _message(new bytes(0)));

        assertLt(adapterFee, defaultGasFee, "zero-gasLimit extraArgs should be cheaper than CCIP's 200k default");
        assertEq(adapterFee, ICCIPRouter(CCIP_ROUTER).getFee(OP_CHAIN_SELECTOR, _message(abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, GenericExtraArgsV2({ gasLimit: 0, allowOutOfOrderExecution: true })))), "adapter should quote the gasLimit-0, out-of-order-allowed message");
    }

    /// @dev Extracts the `messageId` from the adapter's `BridgeViaCCIP` log. `token` is the
    ///      only indexed member, so the remaining four are ABI-encoded in `data`.
    function _bridgeViaCcipMessageId(Vm.Log[] memory logs) internal pure returns (bytes32) {
        bytes32 topic = keccak256("BridgeViaCCIP(address,uint256,uint64,address,bytes32)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (,,, bytes32 messageId) = abi.decode(logs[i].data, (uint256, uint64, address, bytes32));
                return messageId;
            }
        }
        return bytes32(0);
    }
}
