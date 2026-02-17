// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {SettlementDispatcher} from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import {Utils} from "./utils/Utils.sol";

contract ReadSettlementDispatcherV1Configs is Utils {

    address constant USDC_SCROLL  = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant USDT_SCROLL  = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address constant LIQUID_USD   = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;

    function run() public view {
        string memory deployments = readDeploymentFile();

        address reap = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap");
        address rain = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain");
        address pix  = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix");

        _logDispatcher("Reap", reap);
        _logDispatcher("Rain", rain);
        _logDispatcher("Pix", pix);
    }

    function _logDispatcher(string memory name, address proxy) internal view {
        SettlementDispatcher sd = SettlementDispatcher(payable(proxy));

        console.log("========================================");
        console.log(string.concat("Settlement Dispatcher: ", name));
        console.log("  proxy:", proxy);

        _logDestData(name, "USDC", sd.destinationData(USDC_SCROLL));
        _logDestData(name, "USDT", sd.destinationData(USDT_SCROLL));
        _logDestData(name, "LIQUID_USD", sd.destinationData(LIQUID_USD));

        address liquidQueue = sd.getLiquidAssetWithdrawQueue(LIQUID_USD);
        console.log(string.concat("  [", name, "] LIQUID_USD withdrawQueue:"), liquidQueue);
    }

    function _logDestData(
        string memory dispatcher,
        string memory token,
        SettlementDispatcher.DestinationData memory d
    ) internal pure {
        string memory prefix = string.concat("  [", dispatcher, "] ", token);
        console.log(string.concat(prefix, " destRecipient:"), d.destRecipient);
        console.log(string.concat(prefix, " destEid:"), uint256(d.destEid));
        console.log(string.concat(prefix, " stargate:"), d.stargate);
        console.log(string.concat(prefix, " useCanonicalBridge:"), d.useCanonicalBridge);
        console.log(string.concat(prefix, " minGasLimit:"), uint256(d.minGasLimit));
    }
}
