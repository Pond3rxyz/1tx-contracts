// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICCTPBridge
/// @notice Interface for CCTP bridge adapter used by SwapDepositRouter
interface ICCTPBridge {
    /// @notice Bridges `stableToken` already transferred to this contract
    /// @return destinationDomain The configured CCTP domain used
    /// @return resolvedMintRecipient The resolved mint recipient
    /// @return minFinalityThreshold The finality threshold used for the burn
    function bridge(
        address stableToken,
        address sender,
        uint256 amount,
        uint32 targetChain,
        bool fastTransfer,
        uint256 maxFee,
        bytes32 destinationCaller,
        bytes32 mintRecipient,
        bytes calldata hookData
    ) external returns (uint32 destinationDomain, bytes32 resolvedMintRecipient, uint32 minFinalityThreshold);
}
