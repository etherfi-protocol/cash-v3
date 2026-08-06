// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

/**
 * @notice Deploys the Ethereum-side StockUnwrapper (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init). Run AFTER DeployStockWithdrawModule on OP, so SRC_MODULE is known.
 *
 * Env: PRIVATE_KEY,
 *      ROLE_REGISTRY          (mainnet trading-account registry,
 *                              0xBdAe3A2EfDFf4f27Dc1D89E0BEdb88F3e9A62Bd0 per
 *                              deployments/mainnet/1/trading-account.json),
 *      LZ_ENDPOINT            (0x1a44076050125825900e736c501f859c50fE728c on Ethereum),
 *      SRC_EID                (30111 = OP mainnet),
 *      SRC_MODULE             (OP StockWithdrawModule proxy),
 *      TRADING_SAFE_FACTORY   (0xE54e00b0e72F8FC8Cb7e124C378bAd2E7371d2b8)
 *
 * Run with --verify. After broadcast, run VerifyStockUnwrapper.s.sol against the live chain.
 */
contract DeployStockUnwrapper is Script {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 public constant SALT_STOCK_UNWRAPPER_IMPL = keccak256("DeployStockUnwrapper.StockUnwrapperImpl");
    bytes32 public constant SALT_STOCK_UNWRAPPER_PROXY = keccak256("DeployStockUnwrapper.StockUnwrapperProxy");

    // --- CREATE3 deploy helper (idempotent — skips if already deployed) ---
    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        address roleRegistry = vm.envAddress("ROLE_REGISTRY");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        uint32 srcEid = uint32(vm.envUint("SRC_EID"));
        address srcModule = vm.envAddress("SRC_MODULE");
        address tradingSafeFactory = vm.envAddress("TRADING_SAFE_FACTORY");

        address ownerBefore = IRoleRegistry(roleRegistry).owner();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address impl = deployCreate3(
            abi.encodePacked(type(StockUnwrapper).creationCode),
            SALT_STOCK_UNWRAPPER_IMPL
        );

        address proxy = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(impl, abi.encodeWithSelector(StockUnwrapper.initialize.selector, roleRegistry, lzEndpoint, srcEid, srcModule, tradingSafeFactory))
            ),
            SALT_STOCK_UNWRAPPER_PROXY
        );

        vm.stopBroadcast();

        // Post-operation hook: the timelock/registry owner must be unchanged.
        require(IRoleRegistry(roleRegistry).owner() == ownerBefore, "CRITICAL: role registry owner changed!");

        console.log("StockUnwrapper impl:", impl);
        console.log("StockUnwrapper proxy:", proxy);
    }
}
