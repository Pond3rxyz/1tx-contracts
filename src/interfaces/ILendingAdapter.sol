// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ILendingAdapter
/// @notice Interface for lending protocol adapters
/// @dev All lending adapters must implement this interface to standardize lending operations across protocols
interface ILendingAdapter {
    /// @notice Checks if the adapter has registered a specific market
    /// @dev Used by InstrumentRegistry to validate market existence before registration
    /// @param marketId The protocol-specific market identifier
    /// @return True if the market is registered and active in this adapter
    function hasMarket(bytes32 marketId) external view returns (bool);

    /// @notice Deposits tokens into the lending protocol
    /// @param marketId The protocol-specific market identifier
    /// @param amount The amount to deposit
    /// @param onBehalfOf The address that will receive the yield-bearing tokens
    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf) external;

    /// @notice Withdraws tokens from the lending protocol
    /// @param marketId The protocol-specific market identifier
    /// @param amount The amount of underlying tokens to withdraw
    /// @param to The address that will receive the withdrawn tokens
    /// @dev The adapter should handle transferFrom of yield tokens from msg.sender
    /// @return withdrawnAmount The actual amount of underlying tokens withdrawn
    function withdraw(bytes32 marketId, uint256 amount, address to) external returns (uint256 withdrawnAmount);

    /// @notice Returns the yield-bearing token address for a given market
    /// @dev Generic name supports aTokens, cTokens, vault shares, etc.
    /// @param marketId The protocol-specific market identifier
    /// @return The address of the corresponding yield-bearing token
    function getYieldToken(bytes32 marketId) external view returns (address);

    /// @notice Returns the underlying currency for a given market
    /// @dev Used by SwapDepositor to determine if a swap is needed before deposit/after withdrawal
    /// @param marketId The protocol-specific market identifier
    /// @return The underlying currency of the market
    function getMarketCurrency(bytes32 marketId) external view returns (Currency);
}
