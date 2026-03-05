// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @title MockPoolManager
/// @notice Minimal mock of Uniswap V4 PoolManager for testing SwapDepositRouter
/// @dev Simulates unlock/callback, swap with configurable rate, sync/settle/take
contract MockPoolManager {
    uint256 public swapRate = 990; // 99% output (simulates 1% fee/slippage)
    uint256 public constant RATE_DENOMINATOR = 1000;

    /// @notice Set the swap output rate (numerator / 1000)
    function setSwapRate(uint256 _rate) external {
        swapRate = _rate;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory params, bytes calldata) external pure returns (BalanceDelta) {
        // Only exact-input supported (amountSpecified < 0)
        require(params.amountSpecified < 0, "only exact input");
        uint256 inputAmount = uint256(-params.amountSpecified);
        // Mock: 1:1 swap (no rate applied here — rate is applied by having less output tokens funded)
        // In tests, we control the output by funding the mock PM appropriately
        uint256 outputAmount = inputAmount;

        if (params.zeroForOne) {
            return toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)));
        } else {
            return toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
        }
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}
