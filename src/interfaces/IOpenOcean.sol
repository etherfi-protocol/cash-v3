// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev 10-field struct used by IOpenOceanRouter.swap (selector 0x90411a32)
struct OpenOceanSwapDescription {
    IERC20 srcToken;
    IERC20 dstToken;
    address srcReceiver;
    address dstReceiver;
    uint256 amount;
    uint256 minReturnAmount;
    uint256 guaranteedAmount;
    uint256 flags;
    address referrer;
    bytes permit;
}

/// @dev 9-field struct used by IOpenOceanRouter.simpleSwap (selector 0x0a9704d5)
///      Same as OpenOceanSwapDescription but without the `guaranteedAmount` field.
struct OpenOceanSimpleSwapDescription {
    IERC20 srcToken;
    IERC20 dstToken;
    address srcReceiver;
    address dstReceiver;
    uint256 amount;
    uint256 minReturnAmount;
    uint256 flags;
    address referrer;
    bytes permit;
}

/// @title Interface for making arbitrary calls during swap
interface IOpenOceanCaller {
    struct CallDescription {
        uint256 target;
        uint256 gasLimit;
        uint256 value;
        bytes data;
    }

    function makeCall(CallDescription memory desc) external;

    function makeCalls(CallDescription[] memory desc) external payable;
}

interface IOpenOceanRouter {
    /// @notice Performs a swap, delegating all calls encoded in `data` to `executor`.
    function swap(
        IOpenOceanCaller caller,
        OpenOceanSwapDescription calldata desc,
        IOpenOceanCaller.CallDescription[] calldata calls
    ) external returns (uint256 returnAmount);

    /// @notice Performs a simple swap with a lighter description struct.
    function simpleSwap(
        IOpenOceanCaller caller,
        OpenOceanSimpleSwapDescription calldata desc,
        IOpenOceanCaller.CallDescription[] calldata calls
    ) external returns (uint256 returnAmount);
}