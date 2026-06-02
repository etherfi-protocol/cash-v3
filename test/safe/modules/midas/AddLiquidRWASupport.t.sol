// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ICashModule } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../../../../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../../../../src/oracle/PriceProvider.sol";
import { MessageHashUtils, SafeTestSetup } from "../../SafeTestSetup.t.sol";

/**
 * @title AddLiquidRWASupportTest
 * @notice Verifies the four on-chain config changes from COR-888 / scripts/AddLiquidRWASupport.s.sol
 *         for the Liquid RWA (Midas) token on Optimism:
 *           1. PriceProvider oracle registration (7D staleness).
 *           2. DebtManager collateral config.
 *           3. CashModule withdrawable-asset whitelist.
 *           4. MidasModule deposit/redemption vault registration + mint/redeem round-trip.
 *
 * @dev Run against an Optimism fork: `TEST_CHAIN=10 forge test --match-contract AddLiquidRWASupportTest`.
 *      The whole suite skips on any other chain because the addresses below are OP-mainnet specific.
 *      Like MidasModule.t.sol, this deploys a fresh MidasModule on the fork but points it at the
 *      real on-chain Liquid RWA vaults and oracle.
 */
contract AddLiquidRWASupportTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    // --- COR-888 addresses (Optimism) ---
    address constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
    address constant DEPOSIT_VAULT = 0x97b30c9D53A010009136b830f8A12f8d5624Bc43;
    address constant REDEMPTION_VAULT = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;
    address constant PRICE_ORACLE = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080;

    // Collateral values confirmed (COR-888).
    uint80 constant LTV = 70e18;
    uint80 constant LT = 80e18;
    uint96 constant LB = 4e18;

    MidasModule midasModule;
    IERC20 liquidRWA = IERC20(LIQUID_RWA);

    function setUp() public override {
        // OP-mainnet specific addresses. The fork is only selected inside super.setUp()
        // (driven by TEST_CHAIN), so gate on the env var here and return early when skipping
        // to avoid super.setUp() reverting on a non-OP / unset chain.
        string memory chain = vm.envOr("TEST_CHAIN", string(""));
        if (keccak256(bytes(chain)) != keccak256(bytes("10"))) {
            vm.skip(true, "Liquid RWA integration only valid on Optimism (run with TEST_CHAIN=10)");
            return;
        }

        super.setUp();

        vm.startPrank(owner);

        // --- Change 4: deploy MidasModule pointed at the Liquid RWA vaults ---
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = LIQUID_RWA;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;

        midasModule = new MidasModule(address(dataProvider), midasTokens, depositVaults, redemptionVaults);

        address[] memory modules = new address[](1);
        modules[0] = address(midasModule);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        dataProvider.configureDefaultModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        // --- Change 3: whitelist Liquid RWA as a withdrawable asset ---
        address[] memory assets = new address[](1);
        assets[0] = LIQUID_RWA;
        cashModule.configureWithdrawAssets(assets, shouldWhitelist);

        // --- Change 1: register the Liquid RWA oracle (7D staleness, USD-denominated) ---
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: PRICE_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(PRICE_ORACLE).decimals(),
            maxStaleness: 7 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        priceProvider.setTokenConfig(assets, configs);

        // --- Change 2: collateral config ---
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: LTV,
            liquidationThreshold: LT,
            liquidationBonus: LB
        });
        debtManager.supportCollateralToken(LIQUID_RWA, collateralConfig);
        debtManager.supportBorrowToken(LIQUID_RWA, 1, type(uint128).max);

        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Config-wiring assertions (robust — only need the token + oracle on-chain)
    // ---------------------------------------------------------------------

    function test_oracle_registeredWith7dStaleness() public view {
        PriceProvider.Config memory cfg = priceProvider.tokenConfig(LIQUID_RWA);
        assertEq(cfg.oracle, PRICE_ORACLE);
        assertEq(cfg.maxStaleness, 7 days);
        assertTrue(cfg.isChainlinkType);
        assertFalse(cfg.isStableToken);
    }

    function test_oracle_returnsPositivePrice() public view {
        // PriceProvider normalizes to 6 decimals; a live oracle must yield a positive USD price.
        assertGt(priceProvider.price(LIQUID_RWA), 0);
    }

    function test_midasVault_configured() public view {
        (address depositVault, address redemptionVault) = midasModule.vaults(LIQUID_RWA);
        assertEq(depositVault, DEPOSIT_VAULT);
        assertEq(redemptionVault, REDEMPTION_VAULT);
    }

    function test_withdrawAsset_whitelisted() public view {
        address[] memory whitelisted = cashModule.getWhitelistedWithdrawAssets();
        bool found;
        for (uint256 i = 0; i < whitelisted.length; i++) {
            if (whitelisted[i] == LIQUID_RWA) found = true;
        }
        assertTrue(found, "Liquid RWA not whitelisted as withdraw asset");
    }

    function test_collateral_configured() public view {
        assertTrue(debtManager.isCollateralToken(LIQUID_RWA));
        IDebtManager.CollateralTokenConfig memory cfg = debtManager.collateralTokenConfig(LIQUID_RWA);
        assertEq(cfg.ltv, LTV);
        assertEq(cfg.liquidationThreshold, LT);
        assertEq(cfg.liquidationBonus, LB);
    }

    // ---------------------------------------------------------------------
    // Integration round-trip (needs the live Liquid RWA vaults at the fork block)
    // ---------------------------------------------------------------------

    function test_deposit_usdc_mintsLiquidRWA() public {
        _depositAsset(address(usdc));
    }

    function test_deposit_usdt_mintsLiquidRWA() public {
        _depositAsset(address(usdt));
    }

    function _depositAsset(address asset) internal {
        uint256 amount = 1000 * 10 ** ERC20(asset).decimals();
        deal(asset, address(safe), amount);

        // minReturnAmount = 0: this is a path/round-trip check, not a slippage assertion.
        uint256 minReturnAmount = 0;

        bytes32 digestHash = keccak256(
            abi.encodePacked(
                midasModule.DEPOSIT_SIG(),
                block.chainid,
                address(midasModule),
                midasModule.getNonce(address(safe)),
                address(safe),
                abi.encode(asset, LIQUID_RWA, amount, minReturnAmount)
            )
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 rwaBefore = liquidRWA.balanceOf(address(safe));
        midasModule.deposit(address(safe), asset, LIQUID_RWA, amount, minReturnAmount, owner1, signature);

        assertGt(liquidRWA.balanceOf(address(safe)), rwaBefore, "no Liquid RWA minted");
    }

    function test_withdraw_requestsRedemptionToUsdc() public {
        uint128 amount = 1000 * 10 ** 18;
        deal(LIQUID_RWA, address(safe), amount);

        bytes32 digestHash = keccak256(
            abi.encodePacked(
                midasModule.WITHDRAW_SIG(),
                block.chainid,
                address(midasModule),
                midasModule.getNonce(address(safe)),
                address(safe),
                abi.encode(LIQUID_RWA, amount, address(usdc))
            )
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 rwaBefore = liquidRWA.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit MidasModule.Withdrawal(address(safe), amount, address(usdc), LIQUID_RWA);
        midasModule.withdraw(address(safe), LIQUID_RWA, amount, address(usdc), owner1, signature);

        assertEq(liquidRWA.balanceOf(address(safe)), rwaBefore - amount);
    }
}
