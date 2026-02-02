// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMoonwellComptroller
/// @notice Interface for Moonwell Comptroller (Compound V2 style)
/// @dev The comptroller manages markets and implements policy for the protocol
interface IMoonwellComptroller {
    /// @notice Returns whether the given account is entered in the given asset
    /// @param account The address of the account to check
    /// @param mToken The mToken to check
    /// @return True if the account is in the asset, otherwise false
    function checkMembership(address account, address mToken) external view returns (bool);

    /// @notice Add assets to be included in account liquidity calculation
    /// @param mTokens The list of addresses of the mToken markets to be enabled
    /// @return Success indicator for whether each corresponding market was entered
    function enterMarkets(address[] memory mTokens) external returns (uint256[] memory);

    /// @notice Removes asset from sender's account liquidity calculation
    /// @param mTokenAddress The address of the asset to be removed
    /// @return Whether or not the account successfully exited the market
    function exitMarket(address mTokenAddress) external returns (uint256);

    /// @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
    /// @param mTokenModify The market to hypothetically redeem/borrow in
    /// @param account The account to determine liquidity for
    /// @param redeemTokens The number of tokens to hypothetically redeem
    /// @param borrowAmount The amount of underlying to hypothetically borrow
    /// @return (possible error code, hypothetical account liquidity in excess of collateral requirements, hypothetical account shortfall below collateral requirements)
    function getHypotheticalAccountLiquidity(
        address account,
        address mTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256, uint256);

    /// @notice Returns the assets an account has entered
    /// @param account The address of the account to pull assets for
    /// @return A dynamic list with the assets the account has entered
    function getAssetsIn(address account) external view returns (address[] memory);

    /// @notice Return all of the markets
    /// @return The list of market addresses
    function getAllMarkets() external view returns (address[] memory);
}
