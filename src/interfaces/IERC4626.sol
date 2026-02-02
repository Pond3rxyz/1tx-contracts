// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC4626
/// @notice Interface for ERC-4626 tokenized vaults (Morpho Vaults V2)
/// @dev Standard interface for tokenized vaults as defined in EIP-4626
interface IERC4626 is IERC20 {
    /// @notice Emitted when tokens are deposited into the vault
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when shares are withdrawn from the vault
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Returns the address of the underlying token used for the vault
    /// @return assetTokenAddress Address of the underlying token
    function asset() external view returns (address assetTokenAddress);

    /// @notice Returns the total amount of underlying assets held by the vault
    /// @return totalManagedAssets Total amount of underlying assets
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Converts a given amount of assets to shares
    /// @param assets Amount of assets to convert
    /// @return shares Amount of shares
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts a given amount of shares to assets
    /// @param shares Amount of shares to convert
    /// @return assets Amount of assets
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the maximum amount of assets that can be deposited
    /// @param receiver Address of the receiver
    /// @return maxAssets Maximum amount of assets
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Simulates the amount of shares that would be minted for a deposit
    /// @param assets Amount of assets to deposit
    /// @return shares Amount of shares that would be minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Deposits assets and mints shares to receiver
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Returns the maximum amount of shares that can be minted
    /// @param receiver Address of the receiver
    /// @return maxShares Maximum amount of shares
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Simulates the amount of assets needed to mint shares
    /// @param shares Amount of shares to mint
    /// @return assets Amount of assets needed
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Mints exact shares to receiver by depositing assets
    /// @param shares Amount of shares to mint
    /// @param receiver Address to receive the shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Returns the maximum amount of assets that can be withdrawn
    /// @param owner Address of the owner
    /// @return maxAssets Maximum amount of assets
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Simulates the amount of shares that would be burned for a withdrawal
    /// @param assets Amount of assets to withdraw
    /// @return shares Amount of shares that would be burned
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Withdraws assets from the vault and burns shares
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive the assets
    /// @param owner Address of the owner of the shares
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Returns the maximum amount of shares that can be redeemed
    /// @param owner Address of the owner
    /// @return maxShares Maximum amount of shares
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Simulates the amount of assets that would be received for redeeming shares
    /// @param shares Amount of shares to redeem
    /// @return assets Amount of assets that would be received
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Redeems shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the assets
    /// @param owner Address of the owner of the shares
    /// @return assets Amount of assets received
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
