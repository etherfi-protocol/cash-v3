// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { ERC4626WrapModule } from "../../../../../src/modules/erc4626/ERC4626WrapModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @dev Minimal synchronous ERC-4626. The exchange rate is deliberately NOT 1:1 — one share
 *      is worth 1.25 assets — so the sandwich has to re-supply the amount it measured
 *      coming out, not the amount that went in. A 1:1 stub would let that confusion pass.
 */
contract MockERC4626Vault is ERC20 {
    address public immutable asset;

    constructor(address _asset) ERC20("Mock Vault", "mVLT") {
        asset = _asset;
    }

    function sharesFor(uint256 assets) public pure returns (uint256) {
        return assets * 4 / 5;
    }

    function assetsFor(uint256 shares) public pure returns (uint256) {
        return shares * 5 / 4;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        shares = sharesFor(assets);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        _burn(owner_, shares);
        assets = assetsFor(shares);
        IERC20(asset).transfer(receiver, assets);
    }
}

/**
 * @title ERC4626WrapGatewayTest
 * @notice Exercises `ERC4626WrapModule`'s Aave sandwich against the real LendGateway: wrap sources its asset
 *         from Aave and re-supplies the share output as collateral, and unwrap pulls the supplied shares back
 *         and re-supplies the asset output. That second re-supply is where this module diverges from
 *         `MidasModule`, whose redemption is asynchronous and so has nothing to supply. The vault is a stub;
 *         the gateway and Aave are real.
 */
contract ERC4626WrapGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    ERC4626WrapModule internal wrapModule;
    MockERC4626Vault internal vault;
    MockERC20 internal asset;

    function setUp() public override {
        super.setUp();

        asset = new MockERC20("Wrappable Asset", "WRAP", 18);
        vault = new MockERC4626Vault(address(asset));

        // Both legs of the sandwich need listed reserves: the asset so wrap can source it and unwrap can
        // re-supply it, the share token so wrap can re-supply it and unwrap can pull it back.
        uint256 assetReserveId = _addAaveReserve(address(asset), usdcUsdOracle, 8000, false);
        uint256 vaultReserveId = _addAaveReserve(address(vault), usdcUsdOracle, 8000, false);

        // Redemption pays out of the vault's own asset balance.
        asset.mint(address(vault), 1_000_000 ether);

        wrapModule = new ERC4626WrapModule(address(dataProvider), _addr1(address(vault)));
        _enableModule(address(wrapModule));

        vm.startPrank(owner);
        gw.setReserveId(address(asset), assetReserveId);
        gw.setReserveId(address(vault), vaultReserveId);
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(wrapModule), true);
        vm.stopPrank();
    }

    // A wrap sources its asset input from Aave and re-supplies the share output as collateral.
    function test_wrap_sourcesAssetFromAaveAndResuppliesShares() public {
        uint256 amount = 1000 ether;
        _supplyToGateway(address(safe), address(asset), amount);
        uint256 assetSuppliedBefore = gw.suppliedOf(address(safe), address(asset));

        uint256 expectedShares = vault.sharesFor(amount);
        wrapModule.wrap(address(safe), address(vault), amount, expectedShares, owner1, _wrapSig(amount, expectedShares));

        assertEq(gw.suppliedOf(address(safe), address(asset)), assetSuppliedBefore - amount, "asset not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(vault)), expectedShares, "share output not re-supplied");
        assertEq(asset.balanceOf(address(safe)), 0, "asset left loose in safe");
        assertEq(vault.balanceOf(address(safe)), 0, "share output left loose in safe");
    }

    // An unwrap pulls the supplied shares back out of Aave and re-supplies the asset output. ERC-4626
    // redemption is synchronous, so unlike an async redemption request the output is here to re-supply.
    function test_unwrap_pullsSuppliedSharesAndResuppliesAssets() public {
        uint256 shares = 500 ether;
        _supplyToGateway(address(safe), address(vault), shares);

        uint256 expectedAssets = vault.assetsFor(shares);
        wrapModule.unwrap(address(safe), address(vault), shares, expectedAssets, owner1, _unwrapSig(shares, expectedAssets));

        assertEq(gw.suppliedOf(address(safe), address(vault)), 0, "shares not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(asset)), expectedAssets, "asset output not re-supplied");
        assertEq(vault.balanceOf(address(safe)), 0, "shares left loose in safe");
        assertEq(asset.balanceOf(address(safe)), 0, "asset output left loose in safe");
    }

    // A legacy safe that has not opted out yet must not touch Aave: the share output stays loose.
    function test_wrap_legacySafe_outputStaysLoose() public {
        _forceLegacyEngine(address(safe));
        assertFalse(cashModule.isLendActive(address(safe)), "fixture: a legacy safe is not lend-active");

        uint256 amount = 1000 ether;
        deal(address(asset), address(safe), amount);

        uint256 expectedShares = vault.sharesFor(amount);
        wrapModule.wrap(address(safe), address(vault), amount, expectedShares, owner1, _wrapSig(amount, expectedShares));

        assertEq(vault.balanceOf(address(safe)), expectedShares, "share output must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(vault)), 0, "share output must not be supplied to Aave");
    }

    function _wrapSig(uint256 assets, uint256 minShares) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(wrapModule.WRAP_SIG(), block.chainid, address(wrapModule), wrapModule.getNonce(address(safe)), address(safe), abi.encode(address(vault), assets, minShares))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }

    function _unwrapSig(uint256 shares, uint256 minAssets) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(wrapModule.UNWRAP_SIG(), block.chainid, address(wrapModule), wrapModule.getNonce(address(safe)), address(safe), abi.encode(address(vault), shares, minAssets))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
