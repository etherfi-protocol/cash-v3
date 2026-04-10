// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { console } from "forge-std/console.sol";

import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title SetEurcOftDestinationOP
/// @notice Generates a Gnosis Safe transaction bundle to set EURC OFT destination data
///         on all OP settlement dispatchers for bridging to Ethereum mainnet
///
/// Usage:
///   source .env && ENV=mainnet forge script scripts/gnosis-txs/BridgeEurcSettlementOP.s.sol --rpc-url optimism -vvv
contract SetEurcOftDestinationOP is GnosisHelpers, Utils, StdCheats {
    address constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    uint32 constant ETHEREUM_EID = 30101;
    address constant EURC_RECIPIENT = 0x4358f4940283E6357128941a5c508e5F314D79CB;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address settlementDispatcherReap = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap");
        address settlementDispatcherRain = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain");
        address settlementDispatcherPix = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix");
        address settlementDispatcherCardOrder = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder");

        address[] memory tokens = new address[](1);
        tokens[0] = EURC;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: ETHEREUM_EID,
            destRecipient: EURC_RECIPIENT,
            stargate: address(EURC),
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: true,
            remoteToken: address(0),
            useCCTP: false
        });

        string memory setDestData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setDestinationData.selector, tokens, destDatas));

        string memory txs = _getGnosisHeader(chainId, addressToHex(SAFE));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), setDestData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), setDestData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherPix), setDestData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherCardOrder), setDestData, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/SetEurcOftDestinationOP-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        _smokeTest(settlementDispatcherReap, settlementDispatcherRain, settlementDispatcherPix, settlementDispatcherCardOrder);
    }

    function _smokeTest(address reap, address rain, address pix, address cardOrder) internal {
        console.log("=== Smoke Test ===");

        // 1. Verify destination data is set correctly on all dispatchers
        _verifyDestinationData("Reap", reap);
        _verifyDestinationData("Rain", rain);
        _verifyDestinationData("Pix", pix);
        _verifyDestinationData("CardOrder", cardOrder);

        // 2. Test an actual OFT bridge call on the Reap dispatcher
        SettlementDispatcherV2 dispatcher = SettlementDispatcherV2(payable(reap));
        IRoleRegistry roleReg = dispatcher.roleRegistry();
        bytes32 bridgerRole = dispatcher.SETTLEMENT_DISPATCHER_BRIDGER_ROLE();

        address bridger = address(0xBEEF);
        vm.prank(roleReg.owner());
        roleReg.grantRole(bridgerRole, bridger);

        uint256 amount = 100e6;
        deal(EURC, reap, amount);

        (, uint256 valueToSend, , , ) = dispatcher.prepareOftSend(EURC, amount);
        vm.deal(reap, valueToSend);

        uint256 balBefore = IERC20(EURC).balanceOf(reap);

        vm.prank(bridger);
        dispatcher.bridge{ value: 0 }(EURC, amount, amount);

        require(IERC20(EURC).balanceOf(reap) == balBefore - amount, "EURC balance did not decrease");
        console.log("  [OK] Reap bridge call succeeded, EURC debited");

        console.log("=== All Smoke Tests Passed ===");
    }

    function _verifyDestinationData(string memory name, address dispatcher) internal view {
        SettlementDispatcherV2.DestinationData memory dest = SettlementDispatcherV2(payable(dispatcher)).destinationData(EURC);

        require(dest.destEid == ETHEREUM_EID, string.concat(name, ": destEid mismatch"));
        require(dest.destRecipient == EURC_RECIPIENT, string.concat(name, ": destRecipient mismatch"));
        require(dest.stargate == EURC, string.concat(name, ": stargate mismatch"));
        require(dest.isOFT == true, string.concat(name, ": isOFT should be true"));
        require(dest.useCanonicalBridge == false, string.concat(name, ": useCanonicalBridge should be false"));
        require(dest.useCCTP == false, string.concat(name, ": useCCTP should be false"));

        console.log(string.concat("  [OK] ", name, " destination data verified"));
    }
}
