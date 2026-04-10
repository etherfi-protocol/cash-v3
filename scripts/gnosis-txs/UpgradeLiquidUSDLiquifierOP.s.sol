// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title UpgradeLiquidUSDLiquifierOP
/// @notice Deploys LiquidUSDLiquifierOPModule impl via CREATE3 and generates a Gnosis Safe
///         upgrade bundle for the LiquidUSD Liquifier proxy on Optimism.
///
/// Usage:
///   source .env && ENV=mainnet forge script scripts/gnosis-txs/UpgradeLiquidUSDLiquifierOP.s.sol \
///     --rpc-url $OPTIMISM_RPC --broadcast --account deployer
contract UpgradeLiquidUSDLiquifierOP is Utils, GnosisHelpers, Test {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant SALT_IMPL = keccak256("UpgradeLiquidUSDLiquifierOP.Impl");

    address constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address constant DATA_PROVIDER  = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant DEBT_MANAGER   = 0x0078C5a459132e279056B2371fE8A8eC973A9553;
    address constant LIQUIFIER_PROXY = 0x39161A44588ec2327a18D4707EA5216C721ba539;

    function run() public {
        string memory chainId = vm.toString(block.chainid);

        // ── 1. Deploy implementation via CREATE3 ──
        console.log("");
        console.log("=== Deploying LiquidUSDLiquifierOPModule Impl ===");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address impl = deployCreate3(
            abi.encodePacked(type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(DEBT_MANAGER, DATA_PROVIDER)),
            SALT_IMPL
        );

        vm.stopBroadcast();

        console.log("  Impl:", impl);
        require(impl == CREATE3.predictDeterministicAddress(SALT_IMPL, NICKS_FACTORY), "Impl address mismatch");

        // ── 2. Build Gnosis Safe upgrade bundle ──
        console.log("");
        console.log("=== Building Gnosis Upgrade Bundle ===");

        string memory txs = _getGnosisHeader(chainId, addressToHex(SAFE));

        string memory upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, impl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(LIQUIFIER_PROXY), upgradeData, "0", true)));

        string memory path = string.concat("./output/UpgradeLiquidUSDLiquifierOP-", chainId, ".json");
        vm.writeFile(path, txs);
        console.log("  Bundle written to:", path);

        // ── 3. Simulate the bundle ──
        console.log("");
        console.log("=== Simulating Gnosis Bundle ===");
        executeGnosisTransactionBundle(path);
        console.log("  Simulation OK");

        address safe = 0x3f07a5603665033B04AD0eD4ebc0419F982d9F94;
        address liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
        address usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        address etherfiWallet = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;

        deal(usdc, LIQUIFIER_PROXY, 1000e6);
        deal(liquidUsd, safe, 1000e6);

        vm.prank(etherfiWallet);
        LiquidUSDLiquifierOPModule(LIQUIFIER_PROXY).repayUsingLiquidUSD(safe, 100e6);
    }

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
}
