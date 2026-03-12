// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ILendingAdapter
/// @notice Interface for lending protocol adapters
/// @dev All lending adapters must implement this interface to standardize lending operations across protocols
interface ILendingAdapter {
    /// @notice Metadata for the lending adapter
    /// @param name The protocol name (e.g., "Aave V3", "Morpho Blue", "Compound V3")
    /// @param chainId The chain ID where this adapter is deployed
    struct AdapterMetadata {
        string name;
        uint256 chainId;
    }

    /// @notice Returns the metadata for this lending adapter
    /// @dev This should be used to identify the protocol and validate registrations
    /// @return metadata The adapter metadata containing name and chainId
    function getAdapterMetadata() external view returns (AdapterMetadata memory metadata);

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

    /// @notice Converts yield token amount to underlying asset value
    /// @dev Each adapter handles its own conversion logic (1:1 for Aave/Compound, ERC-4626 for others)
    /// @param marketId The protocol-specific market identifier
    /// @param yieldTokenAmount The amount of yield tokens to convert
    /// @return The equivalent amount of underlying assets
    function convertToUnderlying(bytes32 marketId, uint256 yieldTokenAmount) external view returns (uint256);

    /// @notice Check if the yield token requires allow() instead of approve()
    /// @dev Compound V3 comet tokens use allow() instead of standard ERC20 approve()
    /// @return True if the yield token requires allow() for transfers
    function requiresAllow() external view returns (bool);
}
