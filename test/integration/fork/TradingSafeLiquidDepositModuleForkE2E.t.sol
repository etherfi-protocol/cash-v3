// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { ILayerZeroTeller } from "../../../src/interfaces/ILayerZeroTeller.sol";
import { IRoleRegistry } from "../../../src/interfaces/IRoleRegistry.sol";
import { ITradingSafeLiquidDepositModule } from "../../../src/interfaces/ITradingSafeLiquidDepositModule.sol";
import { TradingSafe } from "../../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeLiquidDepositModule } from "../../../src/trading-safe/TradingSafeLiquidDepositModule.sol";

interface ITopUpFactoryLike {
    function deployTopUpContract(bytes32 salt) external;
    function numContractsDeployed() external view returns (uint256);
    function getDeployedAddresses(uint256 start, uint256 n) external view returns (address[] memory);
    function isTokenSupported(address token) external view returns (bool);
    function processTopUpFromContracts(address[] calldata tokens, address[] calldata topUpContracts) external;
}

/**
 * @notice End-to-end deposit against the **production** Ethereum mainnet trading deployment with the
 *         real WBTC, Liquid BTC share token, and Veda teller — no mocks. Proves the whole rail this
 *         module targets: real WBTC held by a prod-factory TradingSafe becomes real Liquid BTC
 *         delivered to that safe's factory-bound TopUp address, and from there enters the existing,
 *         permissionless TopUp sweep path unchanged (the same path that already bridges Liquid BTC
 *         to Optimism).
 *
 * Flow: deploy a real TopUp via the prod TopUpSourceFactory → deploy a TradingSafe bound to it via the
 *       prod TradingSafeFactory → register the module as a default module on the prod DataProvider →
 *       deal real WBTC into the safe → owner-signed deposit → assert Liquid BTC lands at the TopUp →
 *       permissionless `processTopUpFromContracts` sweeps it to the TopUpFactory.
 *
 * Env: MAINNET_RPC, FORK_BLOCK (0 / unset = latest).
 *
 * Run: forge test --match-contract TradingSafeLiquidDepositModuleForkE2E -vvv
 */
contract TradingSafeLiquidDepositModuleForkE2E is Test {
    using MessageHashUtils for bytes32;

    // Production Ethereum deployment (deployments/mainnet/1/*.json).
    address constant DATA_PROVIDER = 0xcaC7ec798A9561B00Ff2F3C7505a0C2c1B543d0C;
    address constant ROLE_REGISTRY = 0xBdAe3A2EfDFf4f27Dc1D89E0BEdb88F3e9A62Bd0;
    address constant TRADING_SAFE_FACTORY = 0xE54e00b0e72F8FC8Cb7e124C378bAd2E7371d2b8;
    address constant TOPUP_SOURCE_FACTORY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;

    // Real mainnet assets (deployments/mainnet/fixtures/top-up-fixtures.json).
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;

    uint256 constant DEADLINE = type(uint256).max;
    uint256 constant DEPOSIT_AMOUNT = 1e8; // 1 WBTC (8 decimals)

    TradingSafeLiquidDepositModule module;
    TradingSafe safe;
    address safeAddr;
    address topUp;
    address ownerAddr;
    uint256 ownerPk;
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
        ITopUpFactoryLike topUpFactory = ITopUpFactoryLike(TOPUP_SOURCE_FACTORY);

        // Deploy a real TopUp via the prod TopUpSourceFactory. Binding the TradingSafe to this TopUp
        // (as its sourceSafe) makes `getTopUpAddress(safe)` resolve to a TopUp that the existing
        // permissionless sweep path actually recognizes.
        topUpFactory.deployTopUpContract(keccak256("TradingSafeLiquidDepositModuleForkE2E"));
        topUp = topUpFactory.getDeployedAddresses(topUpFactory.numContractsDeployed() - 1, 1)[0];

        // Authorize ourselves the way ether.fi's deployer is authorized in prod.
        address roleRegistryOwner = roleRegistry.owner();
        vm.startPrank(roleRegistryOwner);
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), address(this));
        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), address(this));
        vm.stopPrank();

        address[] memory owners = new address[](1);
        owners[0] = ownerAddr;
        safeAddr = factory.getDeterministicAddress(topUp);
        factory.deployTradingSafe(topUp, owners, new address[](0), new bytes[](0), 1);
        safe = TradingSafe(payable(safeAddr));
        assertEq(factory.getTopUpAddress(safeAddr), topUp, "safe bound to the deployed TopUp");

        module = new TradingSafeLiquidDepositModule(_single(LIQUID_BTC), _single(LIQUID_BTC_TELLER), DATA_PROVIDER);
        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        dataProvider.configureDefaultModules(mods, flags);
    }

    function test_fork_depositWbtcToLiquidBtcLandsAtTopUpAndSweeps() public {
        // Preconditions on the live teller and topup lane.
        assertEq(address(ILayerZeroTeller(LIQUID_BTC_TELLER).vault()), LIQUID_BTC, "teller vault is Liquid BTC");
        assertTrue(ILayerZeroTeller(LIQUID_BTC_TELLER).assetData(ERC20(WBTC)).allowDeposits, "teller accepts WBTC");
        assertEq(ILayerZeroTeller(LIQUID_BTC_TELLER).shareLockPeriod(), 0, "no share lock");
        assertTrue(ITopUpFactoryLike(TOPUP_SOURCE_FACTORY).isTokenSupported(LIQUID_BTC), "Liquid BTC is topup-supported");

        deal(WBTC, safeAddr, DEPOSIT_AMOUNT);

        ITradingSafeLiquidDepositModule.DepositRequest memory request = _request();
        (address[] memory signers, bytes[] memory sigs) = _sign(request);

        uint256 topUpBefore = IERC20(LIQUID_BTC).balanceOf(topUp);

        // Permissionless relay submits the owner-signed authorization.
        vm.prank(relayer);
        module.depositToTopUp(request, signers, sigs);

        uint256 minted = IERC20(LIQUID_BTC).balanceOf(topUp) - topUpBefore;
        assertGt(minted, 0, "TopUp received freshly minted Liquid BTC");
        assertEq(IERC20(WBTC).balanceOf(safeAddr), 0, "all WBTC deposited");
        assertEq(IERC20(LIQUID_BTC).balanceOf(safeAddr), 0, "no Liquid BTC lingers in the safe");

        // The existing, permissionless sweep pulls the TopUp's Liquid BTC into the TopUpFactory,
        // the same rail that then bridges it to Optimism. No new roles, no config changes.
        uint256 factoryBefore = IERC20(LIQUID_BTC).balanceOf(TOPUP_SOURCE_FACTORY);
        address[] memory tokens = new address[](1);
        tokens[0] = LIQUID_BTC;
        address[] memory contracts = new address[](1);
        contracts[0] = topUp;

        vm.prank(makeAddr("sweeper"));
        ITopUpFactoryLike(TOPUP_SOURCE_FACTORY).processTopUpFromContracts(tokens, contracts);

        assertEq(IERC20(LIQUID_BTC).balanceOf(topUp), topUpBefore, "TopUp swept to pre-deposit level");
        assertEq(IERC20(LIQUID_BTC).balanceOf(TOPUP_SOURCE_FACTORY) - factoryBefore, minted, "TopUpFactory received the swept Liquid BTC");
    }

    // --- helpers ---

    function _request() internal view returns (ITradingSafeLiquidDepositModule.DepositRequest memory) {
        return ITradingSafeLiquidDepositModule.DepositRequest({ safe: safeAddr, assetToDeposit: WBTC, liquidAsset: LIQUID_BTC, amountToDeposit: DEPOSIT_AMOUNT, minReturn: 1, deadline: DEADLINE });
    }

    function _sign(ITradingSafeLiquidDepositModule.DepositRequest memory request) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("TradingSafeLiquidDepositModule.depositToTopUp"), block.chainid, address(module), safe.nonce(), safeAddr, topUp, keccak256(abi.encode(request)))).toEthSignedMessageHash();

        signers = new address[](1);
        signers[0] = ownerAddr;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
    }

    function _single(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
