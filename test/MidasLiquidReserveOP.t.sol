// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { IEtherFiSafe } from "../src/interfaces/IEtherFiSafe.sol";
import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { PriceProvider } from "../src/oracle/PriceProvider.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../scripts/utils/GnosisHelpers.sol";
import { Utils } from "../scripts/utils/Utils.sol";

/// @notice Fork test that executes the gnosis bundle for liquidRESERVE MidasModule config
///         on OP mainnet and then simulates a deposit and withdraw request.
contract MidasLiquidReserveOPTest is GnosisHelpers, Utils, Test {
    bytes4 constant EIP1271_MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return EIP1271_MAGIC;
    }

    address constant MIDAS_MODULE = 0x2D43400058cE6810916Fd312FB38a7DcdF9708aa;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant MIDAS_TOKEN = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address constant DEPOSIT_VAULT = 0x1561eC30da97108Df46535CBd9bAD8C8d8611B3a;
    address constant REDEMPTION_VAULT = 0xC87b51735ea5Eeee59D3e12601dC931F77F2837a;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    bytes32 constant MIDAS_MODULE_ADMIN = 0x57bb90935cfaf88839f01bfa8de28ad30d80741c4cc93a5d12373ddbb95c68c0;

    address safe;

    function setUp() public {
        vm.createSelectFork("https://mainnet.optimism.io");

        executeGnosisTransactionBundle("./output/DeployMidasModuleLiquidReserveOP.json");

        safe = _createMockSafe();
    }

    function test_depositLiquidReserve() public {
        uint256 depositAmount = 100e6; // 100 USDC
        deal(USDC, safe, depositAmount);

        uint256 midasBefore = ERC20(MIDAS_TOKEN).balanceOf(safe);

        vm.prank(safe);
        MidasModule(MIDAS_MODULE).deposit(
            safe,
            USDC,
            MIDAS_TOKEN,
            depositAmount,
            0, // minReturnAmount — 0 for testing
            address(this),
            "" // signature — bypassed via mock
        );

        uint256 midasAfter = ERC20(MIDAS_TOKEN).balanceOf(safe);
        uint256 received = midasAfter - midasBefore;

        console2.log("Deposited USDC:", depositAmount);
        console2.log("Received liquidRESERVE:", received);
        assertGt(received, 0, "Should receive liquidRESERVE tokens");
    }

    function test_withdrawLiquidReserve() public {
        // First deposit to get some liquidRESERVE
        uint256 depositAmount = 100e6;
        deal(USDC, safe, depositAmount);

        vm.prank(safe);
        MidasModule(MIDAS_MODULE).deposit(safe, USDC, MIDAS_TOKEN, depositAmount, 0, address(this), "");

        uint256 midasBalance = ERC20(MIDAS_TOKEN).balanceOf(safe);
        assertGt(midasBalance, 0, "Should have liquidRESERVE after deposit");

        uint128 withdrawAmount = uint128(midasBalance);

        vm.prank(safe);
        MidasModule(MIDAS_MODULE).withdraw(safe, MIDAS_TOKEN, withdrawAmount, USDC, address(this), "");

        uint256 midasAfter = ERC20(MIDAS_TOKEN).balanceOf(safe);
        assertEq(midasAfter, 0, "All liquidRESERVE should be submitted for redemption");
        console2.log("Withdraw request submitted for:", withdrawAmount);
    }

    function test_configState() public view {
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address debtManager = stdJson.readAddress(deployments, ".addresses.DebtManager");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        assertTrue(EtherFiDataProvider(dataProvider).isDefaultModule(MIDAS_MODULE), "MidasModule should be default");
        assertTrue(IDebtManager(debtManager).isCollateralToken(MIDAS_TOKEN), "liquidRESERVE should be collateral");
        assertTrue(IDebtManager(debtManager).isBorrowToken(MIDAS_TOKEN), "liquidRESERVE should be borrow token");
        assertTrue(RoleRegistry(roleRegistryAddr).hasRole(MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE), "Safe should have MIDAS_MODULE_ADMIN");

        (address dv, address rv) = MidasModule(MIDAS_MODULE).vaults(MIDAS_TOKEN);
        assertEq(dv, DEPOSIT_VAULT, "deposit vault mismatch");
        assertEq(rv, REDEMPTION_VAULT, "redemption vault mismatch");
    }

    /// @dev Creates a mock EtherFiSafe that the MidasModule can interact with.
    ///      Mocks `isEtherFiSafe` on the EtherFiSafeFactory so the module's modifier passes.
    function _createMockSafe() internal returns (address) {
        MockEtherFiSafe mockSafe = new MockEtherFiSafe(MIDAS_MODULE);
        address mockAddr = address(mockSafe);

        // Mock isEtherFiSafe at the factory level (0xF4e147Db...) to return true
        address safeFactory = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;
        vm.mockCall(
            safeFactory,
            abi.encodeWithSignature("isEtherFiSafe(address)", mockAddr),
            abi.encode(true)
        );

        return mockAddr;
    }
}

/// @dev Minimal mock that implements IEtherFiSafe for fork testing.
///      Executes calls directly (no multisig) and bypasses signature verification.
contract MockEtherFiSafe {
    address public module;
    uint256 public nonce;

    constructor(address _module) {
        module = _module;
    }

    function execTransactionFromModule(
        address[] calldata to,
        uint256[] calldata values,
        bytes[] calldata data
    ) external {
        require(msg.sender == module, "only module");
        for (uint256 i = 0; i < to.length; i++) {
            (bool ok, bytes memory ret) = to[i].call{value: values[i]}(data[i]);
            require(ok, string(abi.encodePacked("call failed: ", ret)));
        }
    }

    function useNonce() external returns (uint256) {
        return nonce++;
    }

    function getOwners() external view returns (address[] memory) {
        address[] memory owners = new address[](1);
        owners[0] = address(this);
        return owners;
    }

    function isAdmin(address) external pure returns (bool) {
        return true;
    }

    function checkSignatures(bytes32, address[] calldata, bytes[] calldata) external pure returns (bool) {
        return true;
    }

    receive() external payable {}
}
