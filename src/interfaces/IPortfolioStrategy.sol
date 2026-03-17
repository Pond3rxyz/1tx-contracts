// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPortfolioStrategy
/// @notice Interface for the upgradeable strategy logic used by PortfolioVault
interface IPortfolioStrategy {
    function executeDeployCapital(uint256 stableAmount) external;
    function executeWithdrawCapital(uint256 stableNeeded) external;
    function executeRebalance() external;
}
