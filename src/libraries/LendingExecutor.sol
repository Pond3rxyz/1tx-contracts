// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";

/// @title LendingExecutor
/// @notice Library for depositing/withdrawing via lending adapters
/// @dev Wraps adapter interactions: approve + deposit, transferFrom yield token + withdraw
library LendingExecutor {
    using SafeERC20 for IERC20;

    /// @notice Deposit into a lending protocol via an adapter
    /// @param adapter The lending adapter address
    /// @param marketId The protocol-specific market identifier
    /// @param marketCurrency The underlying currency of the market
    /// @param amount The amount to deposit
    /// @param onBehalfOf The address that will receive the yield-bearing tokens
    function deposit(address adapter, bytes32 marketId, Currency marketCurrency, uint256 amount, address onBehalfOf)
        internal
    {
        IERC20(Currency.unwrap(marketCurrency)).forceApprove(adapter, amount);
        ILendingAdapter(adapter).deposit(marketId, amount, onBehalfOf);
    }

    /// @notice Withdraw from a lending protocol via an adapter
    /// @param adapter The lending adapter address
    /// @param marketId The protocol-specific market identifier
    /// @param yieldToken The yield-bearing token address
    /// @param yieldTokenAmount The amount of yield tokens to redeem
    /// @param from The address holding the yield tokens
    /// @param to The address that will receive the underlying tokens
    /// @return withdrawnAmount The actual amount of underlying tokens withdrawn
    function withdraw(
        address adapter,
        bytes32 marketId,
        address yieldToken,
        uint256 yieldTokenAmount,
        address from,
        address to
    ) internal returns (uint256 withdrawnAmount) {
        if (from == address(this)) {
            IERC20(yieldToken).safeTransfer(adapter, yieldTokenAmount);
        } else {
            IERC20(yieldToken).safeTransferFrom(from, adapter, yieldTokenAmount);
        }
        withdrawnAmount = ILendingAdapter(adapter).withdraw(marketId, yieldTokenAmount, to);
    }
}
