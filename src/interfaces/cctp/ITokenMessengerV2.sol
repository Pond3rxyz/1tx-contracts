// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ITokenMessengerV2
/// @notice Minimal interface for Circle CCTP v2 TokenMessenger on EVM chains
interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}
