// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @notice Upgrades the live OP PriceProviderV2 and enables its sequencer guard atomically.
contract UpgradePriceProviderV2SequencerGuard is GnosisHelpers, Utils {
    address internal constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant SEQUENCER_UPTIME_FEED = 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 1 hours;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory deployments = readDeploymentFile();
        address priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address implementation = address(new PriceProviderV2());

        bytes memory configureGuard = abi.encodeCall(PriceProviderV2.setSequencerConfig, (SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD));
        bytes memory upgrade = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, configureGuard));

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(CASH_CONTROLLER_SAFE));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), iToHex(upgrade), "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradePriceProviderV2SequencerGuard.json";
        vm.writeFile(path, txs);
        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
        require(PriceProviderV2(priceProvider).sequencerUptimeFeed() == SEQUENCER_UPTIME_FEED, "sequencer feed not set");
        require(PriceProviderV2(priceProvider).sequencerGracePeriod() == SEQUENCER_GRACE_PERIOD, "grace period not set");
    }
}
