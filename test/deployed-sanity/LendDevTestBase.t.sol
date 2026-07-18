// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { BinSponsor, Cashback, ICashModule, Mode } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashVerificationLib } from "../../src/libraries/CashVerificationLib.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

/**
 * @title LendDevTestBase
 * @notice Shared base for the deployed-sanity lend suite: forks LIVE Optimism dev, binds to the deployed
 *         addresses from deployments/dev/10, impersonates the dev admin for role-gated calls, and signs
 *         safe-owner operations with a test key. Nothing is deployed in-test except fresh safes through
 *         the live factory (and etched stubs over external protocols where a test needs one).
 * @dev Run policy: manual, after every dev deploy or config change (see the deployment runbook):
 *      source .env && forge test --match-path "test/deployed-sanity/LendDev*" -vv
 */
abstract contract LendDevTestBase is Test {
    using MessageHashUtils for bytes32;

    ICashModule internal cashModule;
    CashLens internal cashLens;
    IDebtManager internal debtManager;
    LendGateway internal gw;
    EtherFiSafeFactory internal factory;
    EtherFiDataProvider internal dataProvider;
    RoleRegistry internal registry;
    TopUpDest internal topUpDest;
    EtherFiLiquidModule internal liquidModule;
    IAaveV4Spoke internal spoke;

    IERC20 internal usdc;
    IERC20 internal weETH;
    address internal devAdmin;

    address internal ownerA;
    uint256 internal ownerAPk;
    address internal recipient = makeAddr("lendDevRecipient");

    uint64 internal withdrawalDelay;
    uint64 internal modeDelay;
    uint256 internal liquidUsdAssetId;
    bool internal gatewayWasDefaultModule;

    string internal baseJson;
    string internal lendJson;
    string internal aaveJson;

    uint256 internal constant FLOOR = 1.05e18;
    uint256 internal constant DAILY_LIMIT_USD = 100_000e6;
    uint256 internal constant MONTHLY_LIMIT_USD = 1_000_000e6;
    int256 internal constant TIMEZONE_OFFSET = 0;

    function setUp() public virtual {
        // Pin LEND_DEV_FORK_BLOCK to reuse the local fork cache across runs (kinder to the RPC).
        uint256 forkBlock = vm.envOr("LEND_DEV_FORK_BLOCK", uint256(0));
        string memory rpc = vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io"));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        require(block.chainid == 10, "Optimism only");

        string memory dir = string.concat(vm.projectRoot(), "/deployments/dev/10/");
        string memory base = vm.readFile(string.concat(dir, "deployments.json"));
        baseJson = base;
        lendJson = vm.readFile(string.concat(dir, "cash-lend.json"));
        aaveJson = vm.readFile(string.concat(dir, "aave-v4-test.json"));

        cashModule = ICashModule(stdJson.readAddress(base, ".addresses.CashModule"));
        cashLens = CashLens(stdJson.readAddress(base, ".addresses.CashLens"));
        debtManager = IDebtManager(stdJson.readAddress(base, ".addresses.DebtManager"));
        factory = EtherFiSafeFactory(stdJson.readAddress(base, ".addresses.EtherFiSafeFactory"));
        dataProvider = EtherFiDataProvider(stdJson.readAddress(base, ".addresses.EtherFiDataProvider"));
        registry = RoleRegistry(stdJson.readAddress(base, ".addresses.RoleRegistry"));
        topUpDest = TopUpDest(payable(stdJson.readAddress(base, ".addresses.TopUpDest")));
        gw = LendGateway(stdJson.readAddress(lendJson, ".lendGateway"));
        liquidModule = EtherFiLiquidModule(payable(stdJson.readAddress(lendJson, ".newModules.liquid")));
        spoke = IAaveV4Spoke(stdJson.readAddress(aaveJson, ".spoke"));

        weETH = IERC20(_findReserveByAssetId(stdJson.readUint(aaveJson, ".details.weETH.assetId")));
        usdc = IERC20(_findReserveByAssetId(stdJson.readUint(aaveJson, ".details.USDC.assetId")));
        liquidUsdAssetId = stdJson.readUint(aaveJson, ".details.liquidUSD.assetId");

        devAdmin = registry.owner();
        require(registry.hasRole(keccak256("ETHER_FI_WALLET_ROLE"), devAdmin), "dev admin missing wallet role");

        (ownerA, ownerAPk) = makeAddrAndKey("lendDevFlowsOwner");
        (withdrawalDelay,, modeDelay) = cashModule.getDelays();

        // The gateway self-approves as the safe's Aave position manager through execTransactionFromModule,
        // which requires it to be a default module (see LendGateway's header). If the live deployment misses
        // that config, patch it on the fork so the flow tests still validate everything downstream;
        // test_deployedConfig_gatewayIsDefaultModule stays red until the live chain is fixed.
        gatewayWasDefaultModule = dataProvider.isDefaultModule(address(gw));
        if (!gatewayWasDefaultModule) {
            console.log("WARNING: live gateway is not a default module; patching on the fork");
            vm.prank(devAdmin);
            dataProvider.configureDefaultModules(_addr1(address(gw)), _bool1(true));
        }
    }

    // ----------------------------------------------------------------- safe deployment

    /// @dev Deploys a fresh single-owner safe through the live factory with the four-field cash setup payload.
    function _deploySafe(bytes32 salt, bool useLend) internal returns (address) {
        return _deploySafeWithModules(salt, useLend, address(0));
    }

    function _deploySafeWithModules(bytes32 salt, bool useLend, address extraModule) internal returns (address) {
        uint256 count = extraModule == address(0) ? 1 : 2;
        address[] memory modules = new address[](count);
        bytes[] memory setupData = new bytes[](count);
        modules[0] = address(cashModule);
        setupData[0] = abi.encode(DAILY_LIMIT_USD, MONTHLY_LIMIT_USD, TIMEZONE_OFFSET, useLend);
        if (extraModule != address(0)) {
            modules[1] = extraModule;
            setupData[1] = "";
        }
        vm.prank(devAdmin);
        factory.deployEtherFiSafe(salt, _addr1(ownerA), modules, setupData, 1);
        return factory.getDeterministicAddress(salt);
    }

    /// @dev Supplies borrowable USDC liquidity to the test Spoke through a dedicated seed safe, so credit
    ///      spends, signed borrows, and migrations can draw on it (dev holds only a few dollars).
    function _seedAaveUsdcLiquidity() internal {
        address seed = _deploySafe("lend-dev-seed", true);
        deal(address(usdc), seed, 500_000e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(seed, _addr1(address(usdc)));
    }

    // ----------------------------------------------------------------- signed safe operations

    function _requestWithdrawal(address safe, address token, uint256 amount) internal {
        (address[] memory signers, bytes[] memory sigs) = _withdrawalSigs(safe, token, amount);
        cashModule.requestWithdrawal(safe, _addr1(token), _uint1(amount), recipient, signers, sigs);
    }

    function _withdrawalSigs(address safe, address token, uint256 amount) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, safe, EtherFiSafe(payable(safe)).nonce(), abi.encode(_addr1(token), _uint1(amount), recipient))).toEthSignedMessageHash();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(digest);
        return (_signers(), sigs);
    }

    function _cancelWithdrawalSigs(address safe) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.CANCEL_WITHDRAWAL_METHOD, block.chainid, safe, EtherFiSafe(payable(safe)).nonce())).toEthSignedMessageHash();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(digest);
        return (_signers(), sigs);
    }

    function _setMode(address safe, Mode mode) internal {
        cashModule.setMode(safe, mode, ownerA, _setModeSig(safe, mode));
    }

    function _setModeSig(address safe, Mode mode) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, safe, cashModule.getNonce(safe), abi.encode(mode))).toEthSignedMessageHash();
        return _sign(digest);
    }

    function _toggleLend(address safe, bool optIn) internal {
        cashModule.toggleLend(safe, optIn, ownerA, _toggleLendSig(safe, optIn));
    }

    function _toggleLendSig(address safe, bool optIn) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, safe, cashModule.getNonce(safe), abi.encode(optIn))).toEthSignedMessageHash();
        return _sign(digest);
    }

    function _borrowSigs(address safe, address token, uint256 amountInUsd) internal view returns (bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, safe, EtherFiSafe(payable(safe)).nonce(), abi.encode(token, amountInUsd))).toEthSignedMessageHash();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(digest);
        return sigs;
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerAPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signers() internal view returns (address[] memory) {
        return _addr1(ownerA);
    }

    // ----------------------------------------------------------------- lookups and small arrays

    function _findReserveByAssetId(uint256 assetId) internal view returns (address) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i = 0; i < count; ++i) {
            IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(i);
            if (reserve.assetId == assetId) {
                return reserve.underlying;
            }
        }
        revert("reserve not found");
    }

    /// @dev Resolves a listed reserve's underlying by its symbol key in aave-v4-test.json's details map.
    function _reserveBySymbol(string memory symbol) internal view returns (address) {
        return _findReserveByAssetId(stdJson.readUint(aaveJson, string.concat(".details.", symbol, ".assetId")));
    }

    function _noCashback() internal pure returns (Cashback[] memory) {
        Cashback[] memory cashbacks;
        return cashbacks;
    }

    function _addr1(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function _uint1(uint256 a) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = a;
        return arr;
    }

    function _bool1(bool b) internal pure returns (bool[] memory) {
        bool[] memory arr = new bool[](1);
        arr[0] = b;
        return arr;
    }
}
