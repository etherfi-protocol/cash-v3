// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IOFT } from "../../src/interfaces/IOFT.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StockOFTBridgeAdapter } from "../../src/top-up/bridge/StockOFTBridgeAdapter.sol";
import { Constants } from "../../src/utils/Constants.sol";

contract StockOFTBridgeAdapterTest is Test, Constants {
    TopUpFactory factory;
    RoleRegistry roleRegistry;
    StockOFTBridgeAdapter stockAdapter;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address dataProvider = makeAddr("dataProvider");

    address constant WSPYX_ADAPTER = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;
    uint32 constant OP_EID = 30111;
    uint256 constant OP_CHAIN_ID = 10;
    IERC20 constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint96 constant MAX_SLIPPAGE_BPS = 100;
    /// @dev Executor lzReceive gas for the destination credit; the Backed OFTs have no
    ///      enforced SEND options, so the send must carry this explicitly.
    uint128 constant LZ_RECEIVE_GAS = 150_000;

    address wrapper;
    address stock;
    uint256 oneStock;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC");
        if (bytes(rpcUrl).length == 0) rpcUrl = "https://mainnet.gateway.tenderly.co";
        // Pin a block at which the wSPYx OFTAdapter is deployed with its OP peer and
        // executor config live, so the fork tests stay deterministic.
        vm.createSelectFork(rpcUrl, 25703946);

        // Derive the asset chain from the OFT adapter — the same derivation the
        // adapter under test performs.
        wrapper = IOFT(WSPYX_ADAPTER).token();
        stock = IERC4626(wrapper).asset();
        oneStock = 10 ** IERC20Metadata(stock).decimals();

        vm.startPrank(owner);
        stockAdapter = new StockOFTBridgeAdapter();

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        TopUp topUpImpl = new TopUp(address(weth));
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(topUpImpl))))));

        address[] memory tokens = new address[](1);
        tokens[0] = stock;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({
            bridgeAdapter: address(stockAdapter),
            recipientOnDestChain: alice,
            maxSlippageInBps: MAX_SLIPPAGE_BPS,
            additionalData: abi.encode(WSPYX_ADAPTER, OP_EID, LZ_RECEIVE_GAS)
        });
        factory.setTokenConfig(tokens, chainIds, configs);

        roleRegistry.grantRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), address(this));
        vm.stopPrank();
    }

    /// @dev `deal` can't locate the stock token's balance slot (it is a rebasing,
    ///      shares-based token à la stETH), so fund the factory from the richest
    ///      on-chain holder we know exists: the ERC-4626 wrapper vault itself. Because
    ///      of shares rounding the credited balance can be a wei or two below `amount`,
    ///      so callers must bridge the returned actual balance.
    function _fundFactoryWithStock(uint256 amount) internal returns (uint256) {
        assertGe(IERC20(stock).balanceOf(wrapper), amount, "wrapper vault holds too little stock to fund the test");
        vm.prank(wrapper);
        IERC20(stock).transfer(address(factory), amount);
        return IERC20(stock).balanceOf(address(factory));
    }

    /// @dev Registers WETH (not the wrapper's asset) on the stock adapter, pointing at
    ///      the wSPYx OFT — the misconfiguration InvalidWrapperAsset defends against.
    function _configureWethOnStockAdapter() internal {
        vm.startPrank(owner);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({
            bridgeAdapter: address(stockAdapter),
            recipientOnDestChain: alice,
            maxSlippageInBps: MAX_SLIPPAGE_BPS,
            additionalData: abi.encode(WSPYX_ADAPTER, OP_EID, LZ_RECEIVE_GAS)
        });
        factory.setTokenConfig(tokens, chainIds, configs);
        vm.stopPrank();
    }

    function test_getBridgeFee_returnsEthFee() public view {
        (address feeToken, uint256 fee) = factory.getBridgeFee(stock, 10 * oneStock, OP_CHAIN_ID);
        assertEq(feeToken, ETH, "fee token should be ETH");
        assertGt(fee, 0, "OFT native fee should be nonzero");
    }

    function test_getBridgeFee_reverts_whenTokenNotWrapperAsset() public {
        _configureWethOnStockAdapter();
        vm.expectRevert(StockOFTBridgeAdapter.InvalidWrapperAsset.selector);
        factory.getBridgeFee(address(weth), 1 ether, OP_CHAIN_ID);
    }

    function test_bridge_succeeds_wrapsAndSends() public {
        uint256 amount = _fundFactoryWithStock(10 * oneStock);
        uint256 expectedShares = IERC4626(wrapper).previewDeposit(amount);
        uint256 lockedBefore = IERC20(wrapper).balanceOf(WSPYX_ADAPTER);
        (, uint256 fee) = factory.getBridgeFee(stock, amount, OP_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(stock, amount, OP_CHAIN_ID);
        factory.bridge{ value: fee }(stock, amount, OP_CHAIN_ID);

        // The rebasing stock's shares rounding can leave a wei or two behind on the
        // vault's transferFrom (the stETH-style "1-2 wei corner").
        assertLe(IERC20(stock).balanceOf(address(factory)), 2, "raw stock should be fully wrapped");

        // The OFTAdapter locks the sent shares; dust below the OFT's shared-decimals
        // resolution stays with the factory.
        uint256 locked = IERC20(wrapper).balanceOf(WSPYX_ADAPTER) - lockedBefore;
        uint256 minShares = expectedShares * (10_000 - MAX_SLIPPAGE_BPS) / 10_000;
        assertGe(locked, minShares, "locked shares below slippage floor");
        assertEq(IERC20(wrapper).balanceOf(address(factory)), expectedShares - locked, "factory should hold only dust");
    }

    /// @dev Regression: `_send` pins `amountLD` to `quoteOFT`'s `amountSentLD`, so the approval
    ///      granted to the OFTAdapter matches exactly what it debits. Approving the untruncated
    ///      share count instead left the OFT's shared-decimals dust behind as a standing
    ///      allowance from the factory to a third-party contract we do not control.
    function test_bridge_leavesNoResidualApprovalToOftAdapter() public {
        // The residual only exists when the adapter pulls via allowance at all.
        assertTrue(IOFT(WSPYX_ADAPTER).approvalRequired(), "premise: OFTAdapter debits via allowance");

        // +1 raw unit nudges previewDeposit off a round number if it happened to be one.
        uint256 amount = _fundFactoryWithStock(10 * oneStock + 1);
        uint256 shares = IERC4626(wrapper).previewDeposit(amount);
        uint256 conversionRate = 10 ** (IERC20Metadata(wrapper).decimals() - IOFT(WSPYX_ADAPTER).sharedDecimals());
        // Deterministic on the pinned block; if a future re-pin lands on dust-free shares,
        // adjust `amount` until dust != 0 — without dust there is no residual to leave behind.
        assertGt(shares % conversionRate, 0, "test needs an amount that produces dusty shares");

        (, uint256 fee) = factory.getBridgeFee(stock, amount, OP_CHAIN_ID);
        factory.bridge{ value: fee }(stock, amount, OP_CHAIN_ID);

        assertEq(IERC20(wrapper).allowance(address(factory), WSPYX_ADAPTER), 0, "dust-sized allowance left behind");
    }

    function test_bridge_reverts_whenTokenNotWrapperAsset() public {
        _configureWethOnStockAdapter();
        deal(address(weth), address(factory), 1 ether);
        // Reverts in the factory's internal getBridgeFee pre-check, before the delegatecall.
        vm.expectRevert(StockOFTBridgeAdapter.InvalidWrapperAsset.selector);
        factory.bridge{ value: 1 ether }(address(weth), 1 ether, OP_CHAIN_ID);
    }

    function test_bridge_reverts_whenInsufficientFeePassed() public {
        uint256 amount = _fundFactoryWithStock(10 * oneStock);
        (, uint256 fee) = factory.getBridgeFee(stock, amount, OP_CHAIN_ID);

        vm.expectRevert(TopUpFactory.InsufficientFeePassed.selector);
        factory.bridge{ value: fee - 1 }(stock, amount, OP_CHAIN_ID);
    }

    /// @dev Pins the property documented in the adapter natspec: with 0 bps slippage,
    ///      minAmountLD equals the exact shares, so the OFT's shared-decimals dust
    ///      truncation reverts with SlippageExceeded already inside quoteSend — the
    ///      route can't even be quoted, so configs MUST use a small nonzero slippage.
    function test_bridge_reverts_whenZeroSlippageAndDustyShares() public {
        vm.startPrank(owner);
        address[] memory tokens = new address[](1);
        tokens[0] = stock;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({
            bridgeAdapter: address(stockAdapter),
            recipientOnDestChain: alice,
            maxSlippageInBps: 0,
            additionalData: abi.encode(WSPYX_ADAPTER, OP_EID, LZ_RECEIVE_GAS)
        });
        factory.setTokenConfig(tokens, chainIds, configs);
        vm.stopPrank();

        // +1 raw unit nudges previewDeposit off a round number if it happened to be one.
        uint256 amount = _fundFactoryWithStock(10 * oneStock + 1);

        uint256 shares = IERC4626(wrapper).previewDeposit(amount);
        uint256 conversionRate = 10 ** (IERC20Metadata(wrapper).decimals() - IOFT(WSPYX_ADAPTER).sharedDecimals());
        uint256 dust = shares % conversionRate;
        // Deterministic on the pinned block; if a future re-pin lands on dust-free
        // shares, adjust `amount` until dust != 0 — the scenario requires it.
        assertGt(dust, 0, "test needs an amount that produces dusty shares");

        // Even the quote reverts...
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, shares - dust, shares));
        factory.getBridgeFee(stock, amount, OP_CHAIN_ID);

        // ...and so does the bridge, in the factory's internal fee pre-check.
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, shares - dust, shares));
        factory.bridge{ value: 1 ether }(stock, amount, OP_CHAIN_ID);
    }
}
