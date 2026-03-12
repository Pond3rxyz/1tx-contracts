// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapExecutor
/// @notice Library for executing swaps on Uniswap V4 pools
/// @dev Assumes caller is already in PoolManager unlock context. Never calls unlock() itself.
library SwapExecutor {
    using SafeERC20 for IERC20;
    error InvalidSwapDelta();

    /// @notice Execute a swap on a Uniswap V4 pool
    /// @param poolManager The Uniswap V4 PoolManager
    /// @param swapPool The pool to swap on
    /// @param inputCurrency The currency being sold
    /// @param outputCurrency The currency being bought
    /// @param inputAmount The amount of input currency to swap
    /// @return outputAmount The amount of output currency received
    function executeSwap(
        IPoolManager poolManager,
        PoolKey memory swapPool,
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 inputAmount
    ) internal returns (uint256 outputAmount) {
        bool zeroForOne = Currency.unwrap(swapPool.currency0) == Currency.unwrap(inputCurrency);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = poolManager.swap(
            swapPool,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(inputAmount), sqrtPriceLimitX96: priceLimit}),
            ""
        );

        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();

        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwapDelta();

        uint256 settleAmount = uint256(-int256(inputDelta));
        outputAmount = uint256(int256(outputDelta));

        // Settle input tokens (caller owes PM)
        poolManager.sync(inputCurrency);
        IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(poolManager), settleAmount);
        poolManager.settle();

        // Take output tokens (PM owes caller)
        poolManager.take(outputCurrency, address(this), outputAmount);
    }

    /// @notice Execute a swap with minimum output amount enforcement
    /// @param poolManager The Uniswap V4 PoolManager
    /// @param swapPool The pool to swap on
    /// @param inputCurrency The currency being sold
    /// @param outputCurrency The currency being bought
    /// @param inputAmount The amount of input currency to swap
    /// @param minOutputAmount The minimum acceptable output amount
    /// @return outputAmount The amount of output currency received
    function executeSwap(
        IPoolManager poolManager,
        PoolKey memory swapPool,
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 inputAmount,
        uint256 minOutputAmount
    ) internal returns (uint256 outputAmount) {
        outputAmount = executeSwap(poolManager, swapPool, inputCurrency, outputCurrency, inputAmount);
        if (outputAmount < minOutputAmount) revert InsufficientOutputAmount(outputAmount, minOutputAmount);
    }

    error InsufficientOutputAmount(uint256 actual, uint256 minimum);
}
