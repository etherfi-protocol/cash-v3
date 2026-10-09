// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IBackedCCIPBridge } from "../../src/interfaces/IBackedCCIPBridge.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { BackedCCIPBridgeAdapter } from "../../src/top-up/bridge/BackedCCIPBridgeAdapter.sol";
import { Constants } from "../../src/utils/Constants.sol";

/// @notice Runs the adapter through a real TopUpFactory against Backed's live bridge on a mainnet fork.
contract BackedCCIPBridgeAdapterTest is Test, Constants {
    TopUpFactory factory;
    RoleRegistry roleRegistry;
    BackedCCIPBridgeAdapter adapter;

    address owner = makeAddr("owner");
    address topUpDest = makeAddr("topUpDest");
    address dataProvider = makeAddr("dataProvider");

    address constant BACKED_BRIDGE = 0x9eC0e4A4c411493773E01e2ABF4D42395788846b;
    address constant BACKED_CUSTODY = 0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD;
    uint64 constant OP_SELECTOR = 3_734_403_246_176_062_136;
    uint256 constant OP_CHAIN_ID = 10;
    address constant SPYX = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    address constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    IERC20 constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC", string(""));
        vm.skip(bytes(rpcUrl).length == 0);
        vm.createSelectFork(rpcUrl);

        vm.startPrank(owner);
        adapter = new BackedCCIPBridgeAdapter();

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        TopUp topUpImpl = new TopUp(address(weth));
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(topUpImpl))))));
        roleRegistry.grantRole(keccak256("ADMIN_TIMELOCK_ROLE"), owner);

        address[] memory tokens = new address[](1);
        tokens[0] = SPYX;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(adapter), recipientOnDestChain: topUpDest, maxSlippageInBps: 0, additionalData: abi.encode(BACKED_BRIDGE, OP_SELECTOR) });
        factory.setTokenConfig(tokens, chainIds, configs);

        roleRegistry.grantRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), address(this));
        vm.stopPrank();
    }

    /// @dev The stock is a rebasing token `deal` cannot place, so fund the factory from the wrapper vault.
    function _fundFactoryWithStock(uint256 amount) internal returns (uint256) {
        vm.prank(WSPYX);
        IERC20(SPYX).transfer(address(factory), amount);
        return IERC20(SPYX).balanceOf(address(factory));
    }

    /// The factory's fee quote is Backed's own delivery fee in ETH for the TopUpDest recipient.
    function test_getBridgeFee_matchesBridgeQuote() public view {
        (address feeToken, uint256 fee) = factory.getBridgeFee(SPYX, 1e18, OP_CHAIN_ID);
        assertEq(feeToken, ETH, "fee token should be ETH");
        assertEq(fee, IBackedCCIPBridge(BACKED_BRIDGE).getDeliveryFeeCost(OP_SELECTOR, bytes32(uint256(uint160(topUpDest))), SPYX, 1e18, ""));
        assertGt(fee, 0);
    }

    /// Bridging moves the stock from the factory into Backed's custody, spends the fee, and leaves no allowance.
    function test_bridge_sendsExactAmountToCustody() public {
        uint256 amount = _fundFactoryWithStock(1e18);
        (, uint256 fee) = factory.getBridgeFee(SPYX, amount, OP_CHAIN_ID);
        uint256 custodyBefore = IERC20(SPYX).balanceOf(BACKED_CUSTODY);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(SPYX, amount, OP_CHAIN_ID);
        factory.bridge{ value: fee }(SPYX, amount, OP_CHAIN_ID);

        assertLe(IERC20(SPYX).balanceOf(address(factory)), 2, "stock should have left the factory");
        assertGe(IERC20(SPYX).balanceOf(BACKED_CUSTODY) - custodyBefore, amount - 2, "custody did not receive the stock");
        assertEq(IERC20(SPYX).allowance(address(factory), BACKED_BRIDGE), 0, "allowance left on the bridge");
        assertEq(address(factory).balance, 0, "fee not spent");
    }

    /// The factory rejects a bridge call that underpays the quoted fee.
    function test_bridge_reverts_whenFeeShort() public {
        uint256 amount = _fundFactoryWithStock(1e18);
        (, uint256 fee) = factory.getBridgeFee(SPYX, amount, OP_CHAIN_ID);
        // The factory compares msg.value with the adapter's quote before delegating
        vm.expectRevert(TopUpFactory.InsufficientFeePassed.selector);
        factory.bridge{ value: fee - 1 }(SPYX, amount, OP_CHAIN_ID);
    }

    /// A token the bridge does not list cannot be quoted through the adapter.
    function test_bridge_reverts_whenTokenNotOnBridge() public {
        vm.startPrank(owner);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(adapter), recipientOnDestChain: topUpDest, maxSlippageInBps: 0, additionalData: abi.encode(BACKED_BRIDGE, OP_SELECTOR) });
        factory.setTokenConfig(tokens, chainIds, configs);
        vm.stopPrank();

        deal(address(weth), address(factory), 1 ether);
        vm.expectRevert();
        factory.getBridgeFee(address(weth), 1 ether, OP_CHAIN_ID);
    }
}
