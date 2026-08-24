// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessagingFee, OFTFeeDetail, OFTLimit, OFTReceipt, SendParam } from "../../src/interfaces/IOFT.sol";
import { IStargate } from "../../src/interfaces/IStargate.sol";
import { Test, console } from "forge-std/Test.sol";

interface IStargateAddressConfig {
    struct AddressConfig {
        address feeLib;
        address planner;
        address treasurer;
        address tokenMessaging;
        address creditMessaging;
        address lzToken;
    }

    function getAddressConfig() external view returns (AddressConfig memory);
}

interface IEnforcedOptions {
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

/// @notice Verifies Stargate taxi coverage for every destination the Cash contracts can be asked to bridge to.
///         Failures are collected across all routes so one run produces the complete gap list for LayerZero.
contract EnforcedOptionsTest is Test {
    // From Stargate's TokenMessagingOptions.sol (stargate-v2): MSG_TYPE_TAXI = 1, MSG_TYPE_BUS = 2.
    uint16 internal constant MSG_TYPE_TAXI = 1;
    uint16 internal constant MSG_TYPE_BUS = 2;

    address internal constant OPTIMISM_USDC_POOL = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;
    address internal constant OPTIMISM_ETH_POOL = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    address internal constant BASE_ETH_POOL = 0xdc181Bd607330aeeBEF6ea62e03e5e1Fb4B6F7C7;

    uint32 internal constant ETHEREUM_EID = 30_101;
    uint32 internal constant OPTIMISM_EID = 30_111;
    uint32 internal constant BASE_EID = 30_184;

    /// @notice Checks the live routes withdrawals have actually used on the Optimism USDC pool.
    function test_optimismUsdcPoolQuotesTaxiForUsedRoutes() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));

        uint32[] memory eids = new uint32[](2);
        eids[0] = ETHEREUM_EID;
        eids[1] = BASE_EID;
        _checkTaxiRoutes(OPTIMISM_USDC_POOL, eids, 1e6, true);
    }

    /// @notice Sweeps every withdrawal destination the cash-be chain registry accepts, since requestBridge
    ///         takes a caller supplied destEid with no on-chain allowlist. A destination with no Stargate
    ///         path is safe (the bridge reverts at quote time) and is only logged.
    function test_optimismUsdcPoolCoversEveryRegistryDestination() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        _checkTaxiRoutes(OPTIMISM_USDC_POOL, _withdrawalEids(), 1e6, false);
    }

    /// @notice Checks the live Optimism ETH pool settlement route.
    function test_optimismEthPoolQuotesTaxiForSettlementRoute() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));

        uint32[] memory eids = new uint32[](1);
        eids[0] = ETHEREUM_EID;
        _checkTaxiRoutes(OPTIMISM_ETH_POOL, eids, 1 ether, true);
    }

    /// @notice Checks the live Base ETH pool top-up route. Scroll is no longer a top-up destination.
    function test_baseEthPoolQuotesTaxiForTopUpRoute() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));

        uint32[] memory eids = new uint32[](1);
        eids[0] = OPTIMISM_EID;
        _checkTaxiRoutes(BASE_ETH_POOL, eids, 1 ether, true);
    }

    /// @dev Checks every route and fails once at the end, so the logs list every gap in a single run.
    function _checkTaxiRoutes(address pool, uint32[] memory eids, uint256 amount, bool mustBeLive) internal view {
        uint256 failureCount = 0;
        for (uint256 i = 0; i < eids.length; i++) {
            string memory failure = _checkTaxiRoute(pool, eids[i], amount, mustBeLive);
            if (bytes(failure).length > 0) {
                console.log("FAILURE:", failure);
                failureCount++;
            }
        }
        assertEq(failureCount, 0, "taxi coverage gaps found; see FAILURE logs");
    }

    /// @dev Returns an empty string when the route is safe, a reason when it is not.
    ///      The bus option length is logged to confirm the message type mapping from live data.
    function _checkTaxiRoute(address pool, uint32 destinationEid, uint256 amount, bool mustBeLive) internal view returns (string memory) {
        address tokenMessaging = IStargateAddressConfig(pool).getAddressConfig().tokenMessaging;
        bytes memory taxiOptions = IEnforcedOptions(tokenMessaging).enforcedOptions(destinationEid, MSG_TYPE_TAXI);
        bytes memory busOptions = IEnforcedOptions(tokenMessaging).enforcedOptions(destinationEid, MSG_TYPE_BUS);

        console.log("Stargate pool", pool);
        console.log("TokenMessaging", tokenMessaging);
        console.log("Destination EID", uint256(destinationEid));
        console.log("Taxi msgType and options length", uint256(MSG_TYPE_TAXI), taxiOptions.length);
        console.log("Bus msgType and options length", uint256(MSG_TYPE_BUS), busOptions.length);

        SendParam memory sendParam = SendParam({ dstEid: destinationEid, to: bytes32(uint256(uint160(address(this)))), amountLD: amount, minAmountLD: amount, extraOptions: new bytes(0), composeMsg: new bytes(0), oftCmd: new bytes(0) });

        try IStargate(pool).quoteOFT(sendParam) returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory receipt) {
            if (receipt.amountReceivedLD == 0) {
                // Dead route: quoteOFT quotes zero, so the slippage check rejects it before sending.
                if (mustBeLive) return _failure(pool, destinationEid, "no live Stargate path for a required route");
                console.log("No live Stargate path to EID (zero quote)", uint256(destinationEid));
                return "";
            }
            if (taxiOptions.length == 0) return _failure(pool, destinationEid, "missing taxi enforcedOptions on a live route");

            sendParam.minAmountLD = receipt.amountReceivedLD;
            try IStargate(pool).quoteSend(sendParam, false) returns (MessagingFee memory messagingFee) {
                console.log("Taxi amount received and native fee", receipt.amountReceivedLD, messagingFee.nativeFee);
                if (messagingFee.nativeFee == 0) return _failure(pool, destinationEid, "quoteSend returned no native fee");
            } catch {
                return _failure(pool, destinationEid, "quoteSend reverted on a live route");
            }
        } catch {
            // No Stargate path: the bridge reverts at quote time, so funds can never take this route.
            if (mustBeLive) return _failure(pool, destinationEid, "no Stargate path for a required route");
            console.log("No Stargate path to EID", uint256(destinationEid));
        }
        return "";
    }

    /// @dev Formats one failure line so the run's log doubles as the escalation list for LayerZero.
    function _failure(address pool, uint32 destinationEid, string memory reason) internal pure returns (string memory) {
        return string.concat("pool ", vm.toString(pool), " eid ", vm.toString(uint256(destinationEid)), ": ", reason);
    }

    /// @dev Every destination EID the withdrawal API accepts (cash-be src/chain-registry/configs, all chains except Optimism).
    function _withdrawalEids() internal pure returns (uint32[] memory) {
        uint32[] memory eids = new uint32[](19);
        eids[0] = 30_101; // Ethereum
        eids[1] = 30_102; // BNB Chain
        eids[2] = 30_106; // Avalanche
        eids[3] = 30_110; // Arbitrum
        eids[4] = 30_165; // zkSync Era
        eids[5] = 30_183; // Linea
        eids[6] = 30_184; // Base
        eids[7] = 30_214; // Scroll
        eids[8] = 30_243; // Blast
        eids[9] = 30_260; // Mode
        eids[10] = 30_320; // Unichain
        eids[11] = 30_322; // Morph
        eids[12] = 30_335; // Swellchain
        eids[13] = 30_339; // Ink
        eids[14] = 30_362; // Berachain
        eids[15] = 30_367; // Hyperliquid
        eids[16] = 30_383; // Plasma
        eids[17] = 30_390; // Monad
        eids[18] = 30_416; // Robinhood
        return eids;
    }
}
