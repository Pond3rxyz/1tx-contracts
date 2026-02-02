// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockAavePool
/// @notice Mock Aave V3 Pool for testing
contract MockAavePool is IAavePool {
    mapping(address asset => ReserveData) private _reserves;
    mapping(address asset => address aToken) private _aTokens;

    /// @notice Set reserve data for an asset
    function setReserveData(address asset, address aToken) external {
        _aTokens[asset] = aToken;
        _reserves[asset] = ReserveData({
            configuration: 0,
            liquidityIndex: 1e27,
            currentLiquidityRate: 0,
            variableBorrowIndex: 1e27,
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: uint40(block.timestamp),
            id: 0,
            aTokenAddress: aToken,
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    /// @notice Get reserve data for an asset
    function getReserveData(address asset) external view override returns (ReserveData memory) {
        return _reserves[asset];
    }

    /// @notice Supply assets to the pool
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        address aToken = _aTokens[asset];
        require(aToken != address(0), "Reserve not found");

        // Transfer underlying from caller
        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Mint aTokens 1:1 to onBehalfOf
        MockERC20(aToken).mint(onBehalfOf, amount);
    }

    /// @notice Withdraw assets from the pool
    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        address aToken = _aTokens[asset];
        require(aToken != address(0), "Reserve not found");

        // Burn aTokens from caller
        MockERC20(aToken).burn(msg.sender, amount);

        // Transfer underlying to recipient
        IERC20(asset).transfer(to, amount);

        return amount;
    }
}
