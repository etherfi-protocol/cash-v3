// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IMidasVault } from "../../../../../src/interfaces/IMidasVault.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { MidasModule } from "../../../../../src/modules/midas/MidasModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev Midas vault stub (deposit + redemption in one): depositInstant pulls the approved asset and mints the
///      18-decimal midas token; redeemRequest escrows the midas token and returns nothing (async redemption on
///      the real vault). Enough to drive the sandwich without the real Midas mechanics.
contract MockMidasVault is IMidasVault {
    MockERC20 internal immutable midasToken;

    constructor(address _midasToken) {
        midasToken = MockERC20(_midasToken);
    }

    function depositInstant(address tokenIn, uint256 amountToken, uint256, bytes32) external {
        uint256 pull = IERC20(tokenIn).allowance(msg.sender, address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), pull);
        midasToken.mint(msg.sender, amountToken);
    }

    function redeemInstant(address, uint256, uint256) external { }

    function redeemRequest(address, uint256 amountMTokenIn, address) external returns (uint256) {
        midasToken.transferFrom(msg.sender, address(this), amountMTokenIn);
        return 0;
    }
}

/**
 * @title MidasGatewayTest
 * @notice Exercises the Midas module's Aave sandwich against the real LendGateway: the deposit sources its
 *         asset from Aave and re-supplies the midas-token output as collateral; the withdraw pulls the supplied
 *         midas token back for the async redemption request (no re-supply, since the asset arrives later). The
 *         vault is a stub; the gateway and Aave are real.
 */
contract MidasGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    MidasModule internal midasModule;
    MockMidasVault internal vault;
    MockERC20 internal midasToken;

    function setUp() public override {
        super.setUp();

        midasToken = new MockERC20("Midas mToken", "mTKN", 18);

        // The midas token is a listed reserve so the deposit can re-supply it and the withdraw can pull it back.
        uint256 midasReserveId = _addAaveReserve(address(midasToken), usdcUsdOracle, 8000, false);

        vault = new MockMidasVault(address(midasToken));

        address[] memory midasTokens = _addr1(address(midasToken));
        address[] memory depositVaults = _addr1(address(vault));
        address[] memory redemptionVaults = _addr1(address(vault));
        midasModule = new MidasModule(address(dataProvider), midasTokens, depositVaults, redemptionVaults);
        _enableModule(address(midasModule));

        vm.startPrank(owner);
        gw.setReserveId(address(midasToken), midasReserveId);
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(midasModule), true);
        vm.stopPrank();
    }

    // A deposit sources its USDC input from Aave and re-supplies the midas-token output as collateral.
    function test_deposit_sourcesUsdcFromAaveAndResuppliesMidasToken() public {
        uint256 amount = 1000e6;
        _supplyToGateway(address(safe), address(usdc), amount);
        uint256 usdcSuppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        uint256 minReturn = amount * 1e12; // 6-decimal USDC -> 18-decimal midas token
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturn, owner1, _depositSig(address(usdc), amount, minReturn));

        assertEq(gw.suppliedOf(address(safe), address(usdc)), usdcSuppliedBefore - amount, "USDC not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(midasToken)), minReturn, "midas token output not re-supplied");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC left loose in safe");
        assertEq(midasToken.balanceOf(address(safe)), 0, "midas token output left loose in safe");
    }

    // A withdraw pulls the supplied midas token back out of Aave for the async redemption request. The asset
    // output arrives later through the vault, so nothing is re-supplied here.
    function test_withdraw_pullsSuppliedMidasTokenForRequest() public {
        uint128 amount = 500e18;
        _supplyToGateway(address(safe), address(midasToken), amount);

        midasModule.withdraw(address(safe), address(midasToken), amount, address(usdc), owner1, _withdrawSig(address(midasToken), amount, address(usdc)));

        assertEq(gw.suppliedOf(address(safe), address(midasToken)), 0, "midas token not withdrawn from Aave");
        assertEq(midasToken.balanceOf(address(vault)), amount, "midas token not escrowed for the redemption request");
        assertEq(midasToken.balanceOf(address(safe)), 0, "midas token left loose in safe");
    }

    // A legacy safe has not opted out yet must not touch Aave: the midas-token output stays loose.
    function test_deposit_legacySafe_outputStaysLoose() public {
        _forceLegacyEngine(address(safe));
        assertFalse(cashModule.isLendActive(address(safe)), "fixture: a legacy safe is not lend-active");

        uint256 amount = 1000e6;
        deal(address(usdc), address(safe), amount);

        uint256 minReturn = amount * 1e12;
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturn, owner1, _depositSig(address(usdc), amount, minReturn));

        assertEq(midasToken.balanceOf(address(safe)), minReturn, "midas token output must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(midasToken)), 0, "midas token output must not be supplied to Aave");
    }

    function _depositSig(address asset, uint256 amount, uint256 minReturn) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(asset, address(midasToken), amount, minReturn))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }

    function _withdrawSig(address midasToken_, uint128 amount, address asset) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.WITHDRAW_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(midasToken_, amount, asset))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
