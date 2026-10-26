// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test, Vm } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IBackedCCIPBridge } from "../../src/interfaces/IBackedCCIPBridge.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { BackedCCIPWrapperBridgeAdapter } from "../../src/top-up/bridge/BackedCCIPWrapperBridgeAdapter.sol";
import { Constants } from "../../src/utils/Constants.sol";

interface IBackedShares {
    function sharesOf(address account) external view returns (uint256);
}

/// @notice Runs the wrapper adapter through a real TopUpFactory against Backed's live bridge on a mainnet fork:
///         the factory holds wSPYx, Backed's custody receives raw SPYx.
contract BackedCCIPWrapperBridgeAdapterTest is Test, Constants {
    TopUpFactory factory;
    RoleRegistry roleRegistry;
    BackedCCIPWrapperBridgeAdapter adapter;

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
        adapter = new BackedCCIPWrapperBridgeAdapter();

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        TopUp topUpImpl = new TopUp(address(weth));
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(topUpImpl))))));
        roleRegistry.grantRole(keccak256("ADMIN_TIMELOCK_ROLE"), owner);

        _setRoute(WSPYX);

        roleRegistry.grantRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), address(this));
        vm.stopPrank();
    }

    function _setRoute(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OP_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(adapter), recipientOnDestChain: topUpDest, maxSlippageInBps: 0, additionalData: abi.encode(BACKED_BRIDGE, OP_SELECTOR) });
        factory.setTokenConfig(tokens, chainIds, configs);
    }

    /// @dev Mints wrapper shares to the factory from raw stock taken out of the vault, as a TradingSafe redirect leaves them.
    function _fundFactoryWithWrapper(uint256 rawAmount) internal returns (uint256) {
        vm.prank(WSPYX);
        IERC20(SPYX).transfer(address(this), rawAmount);
        uint256 received = IERC20(SPYX).balanceOf(address(this));
        IERC20(SPYX).approve(WSPYX, received);
        IERC4626(WSPYX).deposit(received, address(factory));
        return IERC20(WSPYX).balanceOf(address(factory));
    }

    /// The factory's fee quote is Backed's delivery fee in ETH for the raw amount the shares redeem to.
    function test_getBridgeFee_matchesBridgeQuote() public view {
        (address feeToken, uint256 fee) = factory.getBridgeFee(WSPYX, 1e18, OP_CHAIN_ID);
        assertEq(feeToken, ETH, "fee token should be ETH");
        uint256 rawAmount = IERC4626(WSPYX).previewRedeem(1e18);
        assertEq(fee, IBackedCCIPBridge(BACKED_BRIDGE).getDeliveryFeeCost(OP_SELECTOR, bytes32(uint256(uint160(topUpDest))), SPYX, rawAmount, ""));
        assertGt(fee, 0);
    }

    /// Bridging redeems the shares, moves the raw stock into Backed's custody, spends the fee, and leaves no allowance.
    function test_bridge_redeemsAndSendsRawToCustody() public {
        uint256 shares = _fundFactoryWithWrapper(1e18);
        uint256 rawAmount = IERC4626(WSPYX).previewRedeem(shares);
        (, uint256 fee) = factory.getBridgeFee(WSPYX, shares, OP_CHAIN_ID);
        uint256 custodyBefore = IERC20(SPYX).balanceOf(BACKED_CUSTODY);
        uint256 custodySharesBefore = IBackedShares(SPYX).sharesOf(BACKED_CUSTODY);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(WSPYX, shares, OP_CHAIN_ID);
        vm.recordLogs();
        factory.bridge{ value: fee }(WSPYX, shares, OP_CHAIN_ID);

        assertEq(_bridgedShares(), IBackedShares(SPYX).sharesOf(BACKED_CUSTODY) - custodySharesBefore, "event should carry the shares custody received");

        assertEq(IERC20(WSPYX).balanceOf(address(factory)), 0, "shares should have left the factory");
        assertLe(IERC20(SPYX).balanceOf(address(factory)), 2, "raw stock should have left the factory");
        assertGe(IERC20(SPYX).balanceOf(BACKED_CUSTODY) - custodyBefore, rawAmount - 2, "custody did not receive the stock");
        assertEq(IERC20(SPYX).allowance(address(factory), BACKED_BRIDGE), 0, "allowance left on the bridge");
        assertEq(address(factory).balance, 0, "fee not spent");
    }

    /// The raw shares the adapter's event reports, from the recorded logs
    function _bridgedShares() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == BackedCCIPWrapperBridgeAdapter.BridgeBackedCCIPWrapper.selector) {
                (, uint256 sharesBridged,) = abi.decode(logs[i].data, (uint256, uint256, bytes32));
                return sharesBridged;
            }
        }
        revert("bridge event not emitted");
    }

    /// The factory rejects a bridge call that underpays the quoted fee.
    function test_bridge_reverts_whenFeeShort() public {
        uint256 shares = _fundFactoryWithWrapper(1e18);
        (, uint256 fee) = factory.getBridgeFee(WSPYX, shares, OP_CHAIN_ID);
        // The factory compares msg.value with the adapter's quote before delegating
        vm.expectRevert(TopUpFactory.InsufficientFeePassed.selector);
        factory.bridge{ value: fee - 1 }(WSPYX, shares, OP_CHAIN_ID);
    }

    /// A token that is not an ERC-4626 wrapper cannot be quoted through the adapter.
    function test_getBridgeFee_reverts_whenTokenNotAWrapper() public {
        vm.prank(owner);
        _setRoute(address(weth));

        deal(address(weth), address(factory), 1 ether);
        vm.expectRevert();
        factory.getBridgeFee(address(weth), 1 ether, OP_CHAIN_ID);
    }
}
