// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "../../lib/forge-std/src/StdJson.sol";
import {StdCheats} from "../../lib/forge-std/src/StdCheats.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { IEtherFiSafeFactory } from "../../src/interfaces/IEtherFiSafeFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Generates a Gnosis bundle (and simulates execution on the current fork) for the
 *         cash controller safe to:
 *           - whitelist the BeHYPEStakeModule as a default module on EtherFiDataProvider
 *           - grant BEHYPE_STAKE_MODULE_ADMIN_ROLE to the cash controller safe
 *
 *         After executing the bundle, simulates a test stake to verify the full flow.
 *
 *         wHYPE and beHYPE are already whitelisted as withdraw assets on CashModule
 *         (both dev and mainnet, verified on-chain).
 *
 *         Reads module/registry addresses from
 *         `deployments/{ENV}/{chainId}/deployments.json`.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/ConfigureBeHYPEStakeModuleAndWithdraws.s.sol:ConfigureBeHYPEStakeModuleAndWithdraws \
 *       --rpc-url $RPC
 */
contract ConfigureBeHYPEStakeModuleAndWithdraws is GnosisHelpers, Utils, StdCheats {
    using MessageHashUtils for bytes32;

    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        address beHypeStakeModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "BeHYPEStakeModule")
        );

        address[] memory modules = new address[](1);
        modules[0] = beHypeStakeModule;

        bool[] memory whitelistModule = new bool[](1);
        whitelistModule[0] = true;

        bytes32 adminRole = BeHYPEStakeModule(beHypeStakeModule).BEHYPE_STAKE_MODULE_ADMIN_ROLE();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory configureDefaultModule = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, whitelistModule));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModule, "0", false)));

        string memory grantAdminRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, adminRole, cashControllerSafe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantAdminRole, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureBeHYPEStakeModuleAndWithdraws.json";
        vm.writeFile(path, txs);
        executeGnosisTransactionBundle(path);

        _simulateTestStake(dataProvider, beHypeStakeModule);
    }

    function _simulateTestStake(address dataProvider, address beHypeStakeModule) internal {
        console2.log("\n=== Simulating Test Stake ===");

        BeHYPEStakeModule module = BeHYPEStakeModule(beHypeStakeModule);
        address whypeToken = module.whype();
        uint256 stakeAmount = 1e18;

        uint256 adminPk = 0xBEEF;
        address admin = vm.addr(adminPk);

        address testSafe = _deployTestSafe(dataProvider, beHypeStakeModule, admin);

        deal(whypeToken, testSafe, stakeAmount);
        console2.log("Dealt wHYPE to test safe:", stakeAmount);

        uint256 quotedFee = module.staker().quoteStake(stakeAmount, testSafe);
        console2.log("Quoted LZ fee:", quotedFee);

        bytes32 digestHash = keccak256(
            abi.encodePacked(module.STAKE_SIG(), block.chainid, beHypeStakeModule, uint256(0), testSafe, abi.encode(stakeAmount))
        ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 whypeBefore = IERC20(whypeToken).balanceOf(testSafe);

        vm.deal(admin, quotedFee + 1 ether);
        vm.prank(admin);
        module.stake{value: quotedFee}(testSafe, stakeAmount, admin, signature);

        uint256 whypeAfter = IERC20(whypeToken).balanceOf(testSafe);
        require(whypeBefore - whypeAfter == stakeAmount, "wHYPE balance mismatch");

        console2.log("Stake successful! wHYPE spent:", whypeBefore - whypeAfter);
        console2.log("=== Test Stake Complete ===");
    }

    function _deployTestSafe(
        address dataProvider, address beHypeStakeModule, address admin
    ) internal returns (address safe) {
        EtherFiDataProvider dp = EtherFiDataProvider(dataProvider);
        IEtherFiSafeFactory factory = IEtherFiSafeFactory(dp.getEtherFiSafeFactory());
        IRoleRegistry registry = dp.roleRegistry();

        bytes32 factoryAdminRole = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");
        vm.prank(registry.owner());
        registry.grantRole(factoryAdminRole, cashControllerSafe);

        address[] memory owners = new address[](1);
        owners[0] = admin;

        address[] memory modules = new address[](1);
        modules[0] = beHypeStakeModule;

        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";

        vm.prank(cashControllerSafe);
        factory.deployEtherFiSafe(keccak256("test-behype-stake"), owners, modules, setupData, 1);

        safe = factory.getDeterministicAddress(keccak256("test-behype-stake"));
        console2.log("Deployed test safe:", safe);
    }
}
