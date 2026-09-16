// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { MidasLiquifierModule } from "../src/modules/etherfi/MidasLiquifierModule.sol";
import { LendGateway } from "../src/modules/lend-gateway/LendGateway.sol";
import { Utils } from "./utils/Utils.sol";

/// @notice Deploys MidasLiquifierModule on dev, registers it as a default module and gateway driver, and sets the
///         liquidRWA -> USDC pair. The broadcaster must be the dev RoleRegistry owner.
///
/// Usage:
///   ENV=dev forge script scripts/DeployMidasLiquifierModuleDev.s.sol --rpc-url $OPTIMISM_RPC --account dev-admin --broadcast -vvvv
contract DeployMidasLiquifierModuleDev is Utils {
    using stdJson for string;

    address constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
    address constant LIQUID_RWA_REDEMPTION_VAULT = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    bytes32 constant SALT_IMPL = keccak256("MidasLiquifierModule.Impl.v1");
    bytes32 constant SALT_PROXY = keccak256("MidasLiquifierModule.Proxy");

    function run() public {
        string memory deployments = readDeploymentFile();
        address debtManager = deployments.readAddress(".addresses.DebtManager");
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");
        address lendGateway = deployments.readAddress(".addresses.LendGateway");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address impl = deployWithCreate3(abi.encodePacked(type(MidasLiquifierModule).creationCode, abi.encode(debtManager, dataProvider)), SALT_IMPL);
        bytes memory init = abi.encodeWithSelector(MidasLiquifierModule.initialize.selector, roleRegistry);
        MidasLiquifierModule liquifier = MidasLiquifierModule(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(impl, init)), SALT_PROXY));

        liquifier.setPair(LIQUID_RWA, USDC, LIQUID_RWA_REDEMPTION_VAULT, 0, 0);

        address[] memory modules = new address[](1);
        modules[0] = address(liquifier);
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, whitelist);

        LendGateway(lendGateway).setDriver(address(liquifier), true);

        vm.stopBroadcast();

        require(address(liquifier.roleRegistry()) == roleRegistry, "role registry mismatch");
        require(liquifier.pairs(LIQUID_RWA).debtToken == USDC, "pair not set");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(address(liquifier)), "not a default module");
        require(LendGateway(lendGateway).isDriver(address(liquifier)), "not a gateway driver");

        console.log("MidasLiquifierModule impl:", impl);
        console.log("MidasLiquifierModule proxy:", address(liquifier));

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(string.concat('"', vm.toString(address(liquifier)), '"'), path, ".addresses.MidasLiquifierModule");
    }
}
