// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../../src/interfaces/IRoleRegistry.sol";
import { Withdrawal } from "../../../src/interfaces/ITradingSafeWithdrawModule.sol";
import { TradingSafe } from "../../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeWithdrawModule } from "../../../src/trading-safe/TradingSafeWithdrawModule.sol";

interface IBackedToken {
    function minter() external view returns (address);
    function mint(address to, uint256 amount) external;
}

/**
 * @notice End-to-end withdrawal against the **production** Ethereum mainnet trading deployment, with
 *         the real wTSLAx / TSLAx contracts rather than a mock. This is the test that actually proves
 *         auto-unwrap works on the assets a mainnet TradingSafe holds: every tokenized equity in the
 *         trading catalog is a `WrappedBackedToken` ERC-4626 vault over a rebasing Backed xStock, and
 *         the module redeems it straight to the recipient.
 *
 * Flow: deploy a safe via the prod TradingSafeFactory → deploy the module → register it as a default
 *       module on the prod DataProvider → wrap real TSLAx into the safe → owner-signed withdrawal.
 *
 * Env: MAINNET_RPC, FORK_BLOCK (0 / unset = latest).
 *
 * Run: forge test --match-contract TradingSafeWithdrawModuleForkE2E -vvv
 */
contract TradingSafeWithdrawModuleForkE2E is Test {
    using MessageHashUtils for bytes32;

    // Production Ethereum deployment (deployments/mainnet/1/trading-account.json).
    address constant DATA_PROVIDER = 0xcaC7ec798A9561B00Ff2F3C7505a0C2c1B543d0C;
    address constant ROLE_REGISTRY = 0xBdAe3A2EfDFf4f27Dc1D89E0BEdb88F3e9A62Bd0;
    address constant TRADING_SAFE_FACTORY = 0xE54e00b0e72F8FC8Cb7e124C378bAd2E7371d2b8;

    // Backed xStocks: the wrapper the safe holds, and the underlying a user actually wants.
    address constant WTSLAX = 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171;
    address constant TSLAX = 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;

    uint256 constant DEADLINE = type(uint256).max;

    TradingSafeWithdrawModule module;
    TradingSafe safe;
    address safeAddr;
    address ownerAddr;
    uint256 ownerPk;
    address recipient = makeAddr("withdrawRecipient");
    address relayer = makeAddr("relayer");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string("https://eth.llamarpc.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        require(DATA_PROVIDER.code.length > 0, "fork is not on Ethereum mainnet (prod DataProvider missing)");

        (ownerAddr, ownerPk) = makeAddrAndKey("safeOwner");

        TradingSafeFactory factory = TradingSafeFactory(TRADING_SAFE_FACTORY);
        EtherFiDataProvider dataProvider = EtherFiDataProvider(DATA_PROVIDER);
        IRoleRegistry roleRegistry = IRoleRegistry(ROLE_REGISTRY);

        // Authorize ourselves the way ether.fi's deployer is authorized in prod.
        address roleRegistryOwner = roleRegistry.owner();
        vm.startPrank(roleRegistryOwner);
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), address(this));
        // The deployed data provider pre-dates the role consolidation and still gates its
        // config functions on DATA_PROVIDER_ADMIN_ROLE, so grant it by raw hash.
        roleRegistry.grantRole(keccak256("DATA_PROVIDER_ADMIN_ROLE"), address(this));
        vm.stopPrank();

        address sourceSafe = makeAddr("sourceSafeForWithdrawForkTest");
        address[] memory owners = new address[](1);
        owners[0] = ownerAddr;
        safeAddr = factory.getDeterministicAddress(sourceSafe);
        factory.deployTradingSafe(sourceSafe, owners, new address[](0), new bytes[](0), 1);
        safe = TradingSafe(payable(safeAddr));

        module = new TradingSafeWithdrawModule(DATA_PROVIDER);
        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        dataProvider.configureDefaultModules(mods, flags);
    }

    function test_fork_withdrawUnwrapsRealWTslaxToTslax() public {
        uint256 shares = _fundSafeWithWrappedTsla(100e18);
        uint256 redeemed = shares / 4;
        uint256 expectedAssets = IERC4626(WTSLAX).previewRedeem(redeemed);
        assertGt(expectedAssets, 0, "precondition: redeem yields underlying");

        (address[] memory signers, bytes[] memory sigs) = _sign(WTSLAX, redeemed, true);

        vm.prank(relayer);
        module.withdraw(safeAddr, _legs(WTSLAX, redeemed, true), recipient, DEADLINE, signers, sigs);

        assertEq(IERC20(TSLAX).balanceOf(recipient), expectedAssets, "recipient holds real TSLAx");
        assertEq(IERC20(WTSLAX).balanceOf(recipient), 0, "recipient holds no wrapper");
        assertEq(IERC20(WTSLAX).balanceOf(safeAddr), shares - redeemed, "safe debited exactly the signed shares");
    }

    function test_fork_withdrawKeepsWrapperWhenUnwrapNotRequested() public {
        uint256 shares = _fundSafeWithWrappedTsla(100e18);
        uint256 sent = shares / 4;

        (address[] memory signers, bytes[] memory sigs) = _sign(WTSLAX, sent, false);

        vm.prank(relayer);
        module.withdraw(safeAddr, _legs(WTSLAX, sent, false), recipient, DEADLINE, signers, sigs);

        assertEq(IERC20(WTSLAX).balanceOf(recipient), sent, "recipient holds the wrapper");
        assertEq(IERC20(TSLAX).balanceOf(recipient), 0, "no unwrap happened");
    }

    /// @dev Mints real TSLAx as the Backed minter and wraps it into the safe, so the safe's wTSLAx is
    ///      backed exactly as it would be after an Enso swap — no storage overrides.
    function _fundSafeWithWrappedTsla(uint256 assets) internal returns (uint256 shares) {
        vm.prank(IBackedToken(TSLAX).minter());
        IBackedToken(TSLAX).mint(address(this), assets);

        IERC20(TSLAX).approve(WTSLAX, assets);
        shares = IERC4626(WTSLAX).deposit(assets, safeAddr);
        assertEq(IERC20(WTSLAX).balanceOf(safeAddr), shares, "safe funded with wrapped xStock");
    }

    function _legs(address token, uint256 amount, bool unwrap) internal pure returns (Withdrawal[] memory legs) {
        legs = new Withdrawal[](1);
        legs[0] = Withdrawal(token, amount, unwrap);
    }

    function _sign(address token, uint256 amount, bool unwrap) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("TradingSafeWithdrawModule.withdraw"), block.chainid, address(module), safe.nonce(), safeAddr, keccak256(abi.encode(_legs(token, amount, unwrap))), recipient, DEADLINE)).toEthSignedMessageHash();

        signers = new address[](1);
        signers[0] = ownerAddr;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
    }
}
