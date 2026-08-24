// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessagingFee, OFTReceipt, SendParam } from "../../src/interfaces/IOFT.sol";
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

/// @notice Verifies that Stargate can quote taxi transfers for routes that Cash previously used in bus mode.
contract EnforcedOptionsTest is Test {
    uint16 internal constant MSG_TYPE_TAXI = 1;
    uint16 internal constant MSG_TYPE_BUS = 2;

    address internal constant OPTIMISM_USDC_POOL = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;
    address internal constant OPTIMISM_ETH_POOL = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    address internal constant BASE_ETH_POOL = 0xdc181Bd607330aeeBEF6ea62e03e5e1Fb4B6F7C7;

    uint32 internal constant ETHEREUM_EID = 30_101;
    uint32 internal constant OPTIMISM_EID = 30_111;
    uint32 internal constant BASE_EID = 30_184;
    uint32 internal constant SCROLL_EID = 30_214;

    /// @notice Checks the live Optimism USDC and ETH pools for every Cash route that previously used bus mode.
    function test_optimismPoolsQuoteTaxiForExistingRoutes() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));

        _assertTaxiRoute(OPTIMISM_USDC_POOL, ETHEREUM_EID, 1e6);
        _assertTaxiRoute(OPTIMISM_USDC_POOL, BASE_EID, 1e6);
        _assertTaxiRoute(OPTIMISM_ETH_POOL, ETHEREUM_EID, 1 ether);
    }

    /// @notice Checks the live Base ETH pool for every Cash route that previously used bus mode.
    function test_baseEthPoolQuotesTaxiForExistingRoutes() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));

        _assertTaxiRoute(BASE_ETH_POOL, SCROLL_EID, 1 ether);
        _assertTaxiRoute(BASE_ETH_POOL, OPTIMISM_EID, 1 ether);
    }

    /// @dev Confirms taxi gas options exist, then obtains a live taxi quote without caller supplied extra options.
    ///      The bus option length is logged only to confirm the message type mapping.
    function _assertTaxiRoute(address pool, uint32 destinationEid, uint256 amount) internal view {
        address tokenMessaging = IStargateAddressConfig(pool).getAddressConfig().tokenMessaging;
        bytes memory taxiOptions = IEnforcedOptions(tokenMessaging).enforcedOptions(destinationEid, MSG_TYPE_TAXI);
        bytes memory busOptions = IEnforcedOptions(tokenMessaging).enforcedOptions(destinationEid, MSG_TYPE_BUS);

        console.log("Stargate pool", pool);
        console.log("TokenMessaging", tokenMessaging);
        console.log("Destination EID", uint256(destinationEid));
        console.log("Taxi msgType and options length", uint256(MSG_TYPE_TAXI), taxiOptions.length);
        console.log("Bus msgType and options length", uint256(MSG_TYPE_BUS), busOptions.length);

        assertGt(taxiOptions.length, 0, "Missing taxi enforcedOptions for an existing Stargate route");

        SendParam memory sendParam = SendParam({ dstEid: destinationEid, to: bytes32(uint256(uint160(address(this)))), amountLD: amount, minAmountLD: amount, extraOptions: new bytes(0), composeMsg: new bytes(0), oftCmd: new bytes(0) });

        (,, OFTReceipt memory receipt) = IStargate(pool).quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;
        MessagingFee memory messagingFee = IStargate(pool).quoteSend(sendParam, false);

        console.log("Taxi amount sent", receipt.amountSentLD);
        console.log("Taxi amount received", receipt.amountReceivedLD);
        console.log("Taxi native fee", messagingFee.nativeFee);

        assertGt(receipt.amountReceivedLD, 0, "Stargate taxi quote returned no destination tokens");
        assertGt(messagingFee.nativeFee, 0, "Stargate taxi quote returned no native fee");
    }
}
