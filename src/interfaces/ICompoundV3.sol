// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICompoundV3
/// @notice Minimal interface for Compound V3 (Comet)
/// @dev Only includes the methods needed for depositing and withdrawing
interface ICompoundV3 {
    /// @notice Supply an amount of asset to the protocol
    /// @param asset The address of the asset to supply
    /// @param amount The amount to be supplied
    function supply(address asset, uint256 amount) external;

    /// @notice Supply an amount of asset to the protocol on behalf of another address
    /// @param to The address that will receive the supply balance
    /// @param asset The address of the asset to supply
    /// @param amount The amount to be supplied
    function supplyTo(address to, address asset, uint256 amount) external;

    /// @notice Withdraw an amount of asset from the protocol
    /// @param asset The address of the asset to withdraw
    /// @param amount The amount to be withdrawn
    function withdraw(address asset, uint256 amount) external;

    /// @notice Withdraw an amount of asset from the protocol on behalf of another address
    /// @param from The address whose balance will be withdrawn
    /// @param to The address that will receive the withdrawn asset
    /// @param asset The address of the asset to withdraw
    /// @param amount The amount to be withdrawn
    function withdrawFrom(address from, address to, address asset, uint256 amount) external;

    /// @notice Get the balance of a user's supply
    /// @param account The address to check the balance of
    /// @return The balance of the account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Allow or disallow a manager to withdraw on behalf of the sender
    /// @param manager The address of the manager
    /// @param isAllowed Whether the manager is allowed to withdraw
    function allow(address manager, bool isAllowed) external;
}
