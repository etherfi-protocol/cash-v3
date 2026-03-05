// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";   
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SafeTestSimulationHelper } from "../utils/SafeTestSimulationHelper.sol";

contract SupportEurcCrosschainWithdrawals is GnosisHelpers, Utils, Test {
    using MessageHashUtils for bytes32;

    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 public constant STARGATE_MODULE_ADMIN_ROLE = keccak256("STARGATE_MODULE_ADMIN_ROLE");

    address eurc = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    
    address stargateModule;
    SafeTestSimulationHelper safeTestSimulationHelper;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        stargateModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "StargateModule")
        );

        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        StargateModule.AssetConfig memory eurcStargateConfig = StargateModule.AssetConfig({
            isOFT: true,
            pool: address(eurc)
        });

        address[] memory assets = new address[](1);
        assets[0] = address(eurc);

        StargateModule.AssetConfig[] memory eurcStargateConfigs = new StargateModule.AssetConfig[](1);
        eurcStargateConfigs[0] = eurcStargateConfig;

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory grantRole = iToHex(abi.encodeWithSelector(RoleRegistry.grantRole.selector, STARGATE_MODULE_ADMIN_ROLE, cashControllerSafe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantRole, "0", false)));

        string memory setEurcStargateConfig = iToHex(abi.encodeWithSelector(StargateModule.setAssetConfig.selector, assets, eurcStargateConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(stargateModule), setEurcStargateConfig, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = "./output/SupportEurcCrosschainWithdrawals.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        path = "./output/SupportEurc.json";
        executeGnosisTransactionBundle(path);

        assert(StargateModule(payable(stargateModule)).getAssetConfig(eurc).isOFT == true);
        assert(StargateModule(payable(stargateModule)).getAssetConfig(eurc).pool == address(eurc));

        test();
    }

    function test() public {
        safeTestSimulationHelper = new SafeTestSimulationHelper();
        (address etherfiWallet, address owner, uint256 ownerPk, address safe) = safeTestSimulationHelper.deploySafe();

        uint256 amount = 100e6;
        deal(address(eurc), safe, amount);

        uint32 destEid = 30101;

        (, uint256 fee) = StargateModule(payable(stargateModule)).getBridgeFee(destEid, address(eurc), amount, owner, 1);

        vm.deal(etherfiWallet, fee);

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(ownerPk, owner, safe, owner, destEid, amount);

        StargateModule(payable(stargateModule)).requestBridge(safe, destEid, address(eurc), amount, owner, 1, signers, signatures);

        vm.warp(block.timestamp + 100);

        vm.prank(etherfiWallet);
        StargateModule(payable(stargateModule)).executeBridge{value: fee}(safe);
    }

    function _getSignatures(uint256 ownerPk, address owner, address safe, address destRecipient, uint32 destEid, uint256 amount) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            StargateModule(payable(stargateModule)).REQUEST_BRIDGE_SIG(), 
            block.chainid, 
            address(stargateModule), 
            EtherFiSafe(payable(safe)).nonce(), 
            address(safe), 
            abi.encode(destEid, eurc, amount, destRecipient, 1)
        )).toEthSignedMessageHash();

        return safeTestSimulationHelper.getSignatures(digestHash, owner, ownerPk);
    }
}