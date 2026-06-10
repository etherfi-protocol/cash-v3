// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { EtherFiOFTAdapter } from "../../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../../src/oft/EtherFiShadowOFT.sol";
import { MockERC20 } from "../OFTTestSetup.t.sol";

/// @dev Just the in-process delivery hook the handler needs from the TestHelperOz5-based setup.
interface IPacketVerifier {
    function verifyPackets(uint32 _dstEid, bytes32 _dstAddress) external;
}

/**
 * @title OFTConservationHandler
 * @notice Stateful-invariant handler that drives randomized bridgeOut / bridgeBack sequences over
 *         the live LZ harness. Each action performs the `send()` AND the in-process
 *         `verifyPackets()` delivery synchronously, so by the time control returns to the invariant
 *         runner the cross-chain hop has fully settled — locked underlying on mainnet must always
 *         equal the iTOKEN supply on OP.
 */
contract OFTConservationHandler is Test {
    using OptionsBuilder for bytes;

    IPacketVerifier internal immutable helper;
    // public so a multi-pair invariant can read this handler's pair and assert conservation per pair
    EtherFiOFTAdapter public immutable adapter;
    EtherFiShadowOFT public immutable shadow;
    MockERC20 public immutable underlying;
    uint32 internal immutable A_EID;
    uint32 internal immutable B_EID;

    address[] internal users;

    // ghost counters — let the invariant test assert real sequences ran (not 0 effective calls)
    uint256 public bridgeOutCount;
    uint256 public bridgeBackCount;
    uint256 public totalBridgedOut; // cumulative LD locked across all bridgeOut calls

    constructor(IPacketVerifier _helper, EtherFiOFTAdapter _adapter, EtherFiShadowOFT _shadow, MockERC20 _underlying, uint32 _aEid, uint32 _bEid, address[] memory _users) {
        helper = _helper;
        adapter = _adapter;
        shadow = _shadow;
        underlying = _underlying;
        A_EID = _aEid;
        B_EID = _bEid;
        users = _users;
        for (uint256 i; i < _users.length; ++i) {
            vm.deal(_users[i], 1000 ether); // native for LZ messaging fees
        }
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    /// @notice Lock a fresh amount on mainnet and deliver the mint on OP.
    function bridgeOut(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 rate = adapter.conversionRate();
        // at least one SD unit (sub-rate would dust-truncate to a zero send), capped to keep
        // the cumulative supply well under the uint64 SD ceiling.
        amount = bound(amount, rate, 1_000_000 * (10 ** uint256(underlying.decimals())));

        underlying.mint(user, amount);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(B_EID, _b32(user), amount, 0, options, "", "");
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        vm.startPrank(user);
        underlying.approve(address(adapter), amount);
        adapter.send{ value: fee.nativeFee }(sp, fee, payable(user));
        vm.stopPrank();

        helper.verifyPackets(B_EID, _b32(address(shadow)));

        bridgeOutCount += 1;
        totalBridgedOut += (amount / rate) * rate;
    }

    /// @notice Burn some of a user's iTOKEN on OP and deliver the unlock on mainnet.
    function bridgeBack(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 bal = shadow.balanceOf(user);
        if (bal == 0) return; // nothing to send back; not a meaningful action this round

        uint256 rate = shadow.conversionRate();
        amount = bound(amount, rate, bal);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(A_EID, _b32(user), amount, 0, options, "", "");
        MessagingFee memory fee = shadow.quoteSend(sp, false);

        vm.startPrank(user);
        shadow.send{ value: fee.nativeFee }(sp, fee, payable(user));
        vm.stopPrank();

        helper.verifyPackets(A_EID, _b32(address(adapter)));

        bridgeBackCount += 1;
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
