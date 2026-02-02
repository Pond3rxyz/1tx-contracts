// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAavePool
/// @notice Minimal interface for Aave v3 Pool
/// @dev Only includes the methods needed for depositing and withdrawing
interface IAavePool {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    /// @notice Supplies an amount of underlying asset into the reserve, receiving in return overlying aTokens
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to be supplied
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Code used to register the integrator originating the operation, for potential rewards
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws an amount of underlying asset from the reserve, burning the equivalent aTokens owned
    /// @param asset The address of the underlying asset to withdraw
    /// @param amount The amount to be withdrawn
    /// @param to The address that will receive the underlying asset
    /// @return The final amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Returns the state and configuration of the reserve
    /// @param asset The address of the underlying asset
    /// @return The state and configuration data of the reserve
    function getReserveData(address asset) external view returns (ReserveData memory);
}
