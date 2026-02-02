// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMToken
/// @notice Interface for Moonwell mTokens (Compound V2 style)
/// @dev mTokens are ERC20 tokens that represent a claim on underlying assets
interface IMToken {
    /// @notice Sender supplies assets into the market and receives mTokens in exchange
    /// @param mintAmount The amount of the underlying asset to supply
    /// @return 0 on success, otherwise an error code
    function mint(uint256 mintAmount) external returns (uint256);

    /// @notice Sender redeems mTokens in exchange for the underlying asset
    /// @param redeemTokens The number of mTokens to redeem into underlying
    /// @return 0 on success, otherwise an error code
    function redeem(uint256 redeemTokens) external returns (uint256);

    /// @notice Sender redeems mTokens in exchange for a specified amount of underlying asset
    /// @param redeemAmount The amount of underlying to redeem
    /// @return 0 on success, otherwise an error code
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    /// @notice Accrue interest then return the up-to-date exchange rate
    /// @return Calculated exchange rate scaled by 1e18
    function exchangeRateCurrent() external returns (uint256);

    /// @notice Calculates the exchange rate from the underlying to the mToken
    /// @return Calculated exchange rate scaled by 1e18
    function exchangeRateStored() external view returns (uint256);

    /// @notice Get the underlying balance of the `owner`
    /// @param owner The address of the account to query
    /// @return The amount of underlying owned by `owner`
    function balanceOfUnderlying(address owner) external returns (uint256);

    /// @notice Get the token balance of the `owner`
    /// @param owner The address of the account to query
    /// @return The number of tokens owned by `owner`
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Underlying asset for this mToken
    /// @return The address of the underlying asset
    function underlying() external view returns (address);

    /// @notice ERC20 symbol for this token
    /// @return The symbol string
    function symbol() external view returns (string memory);

    /// @notice ERC20 decimals for this token
    /// @return The number of decimals
    function decimals() external view returns (uint8);
}
