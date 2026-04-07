// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, console } from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../../scripts/utils/GnosisHelpers.sol";

/**
 * @title HyperEVMBridgeAfterUpgrade
 * @notice Fork test that replays the 3CP #428 HyperEVM Gnosis bundle and then
 *         attempts to bridge wHYPE and beHYPE to Scroll via the new config.
 *         If the OFT adapter addresses are misconfigured the bridge calls will revert.
 */
contract HyperEVMBridgeAfterUpgrade is Test, GnosisHelpers {
    address constant SAFE = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;
    address constant TOP_UP_FACTORY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;

    IERC20 constant wHYPE = IERC20(0x5555555555555555555555555555555555555555);
    IERC20 constant beHYPE = IERC20(0xd8FC8F0b03eBA61F64D08B0bef69d80916E5DdA9);
    IERC20 constant USDT = IERC20(0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb);

    uint256 constant SCROLL_CHAIN_ID = 534352;
    uint256 constant OP_CHAIN_ID = 10;

    TopUpFactory factory = TopUpFactory(payable(TOP_UP_FACTORY));
    RoleRegistry roleRegistry = RoleRegistry(ROLE_REGISTRY);

    string constant TX_BUNDLE_PATH = "test/top-up/UpgradeTopUpFactoryHyperEVM-999.json";

    function setUp() public {
        string memory rpcUrl = vm.envOr("HYPEREVM_RPC", string("https://rpc.hyperliquid.xyz/evm"));
        vm.createSelectFork(rpcUrl);
    }

    function _executeUpgrade() internal {
        executeGnosisTransactionBundle(TX_BUNDLE_PATH);

        bytes32 bridgerRole = factory.TOPUP_FACTORY_BRIDGER_ROLE();
        vm.prank(SAFE);
        roleRegistry.grantRole(bridgerRole, address(this));
    }

    function test_bridgeWHYPE_afterUpgrade() public {
        _executeUpgrade();

        uint256 amount = 1 ether;
        deal(address(wHYPE), address(factory), amount);
        deal(address(this), 10 ether);

        (, uint256 fee) = factory.getBridgeFee(address(wHYPE), amount, SCROLL_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(address(wHYPE), amount, SCROLL_CHAIN_ID);
        factory.bridge{ value: fee }(address(wHYPE), amount, SCROLL_CHAIN_ID);

        assertEq(wHYPE.balanceOf(address(factory)), 0, "wHYPE should be fully bridged");
    }

    function test_bridgeBeHYPE_afterUpgrade() public {
        _executeUpgrade();

        uint256 amount = 1 ether;
        deal(address(beHYPE), address(factory), amount);
        deal(address(this), 10 ether);

        (, uint256 fee) = factory.getBridgeFee(address(beHYPE), amount, SCROLL_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(address(beHYPE), amount, SCROLL_CHAIN_ID);
        factory.bridge{ value: fee }(address(beHYPE), amount, SCROLL_CHAIN_ID);

        assertEq(beHYPE.balanceOf(address(factory)), 0, "beHYPE should be fully bridged");
    }

    function test_bridgeUSDT_toScroll_afterUpgrade() public {
        _executeUpgrade();

        uint256 amount = 1000e6;
        deal(address(USDT), address(factory), amount);
        deal(address(this), 10 ether);

        (, uint256 fee) = factory.getBridgeFee(address(USDT), amount, SCROLL_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(address(USDT), amount, SCROLL_CHAIN_ID);
        factory.bridge{ value: fee }(address(USDT), amount, SCROLL_CHAIN_ID);
    }

    function test_bridgeBeHYPE_toOP_afterUpgrade() public {
        _executeUpgrade();

        uint256 amount = 1 ether;
        deal(address(beHYPE), address(factory), amount);
        deal(address(this), 10 ether);

        (, uint256 fee) = factory.getBridgeFee(address(beHYPE), amount, OP_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(address(beHYPE), amount, OP_CHAIN_ID);
        factory.bridge{ value: fee }(address(beHYPE), amount, OP_CHAIN_ID);
    }

    function test_bridgeUSDT_toOP_afterUpgrade() public {
        _executeUpgrade();

        uint256 amount = 1000e6;
        deal(address(USDT), address(factory), amount);
        deal(address(this), 10 ether);

        (, uint256 fee) = factory.getBridgeFee(address(USDT), amount, OP_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(address(USDT), amount, OP_CHAIN_ID);
        factory.bridge{ value: fee }(address(USDT), amount, OP_CHAIN_ID);
    }

    receive() external payable {}
}
