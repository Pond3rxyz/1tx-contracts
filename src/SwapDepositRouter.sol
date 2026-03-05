// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {InstrumentRegistry} from "./registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "./registries/SwapPoolRegistry.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";

/// @title SwapDepositRouter
/// @notice Router for buying/selling lending protocol instruments with automatic token swapping
/// @dev Uses Uniswap V4 PoolManager for swaps and lending adapters via InstrumentRegistry for deposits/withdrawals.
///      Always operates in the configured stable currency (e.g. USDC). Yield tokens go to / come from msg.sender.
contract SwapDepositRouter is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // ============ State ============

    IPoolManager public poolManager;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    Currency public stable;

    // ============ Errors ============

    error CallerNotPoolManager();
    error InvalidAmount();
    error InvalidSwapDelta();

    // ============ Events ============

    event Buy(bytes32 indexed instrumentId, address indexed sender, uint256 inputAmount, uint256 depositedAmount);
    event Sell(bytes32 indexed instrumentId, address indexed sender, uint256 yieldTokenAmount, uint256 outputAmount);

    // ============ Types ============

    struct SwapCallbackData {
        PoolKey swapPool;
        Currency inputCurrency;
        Currency outputCurrency;
        uint256 inputAmount;
    }

    // ============ Constructor / Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        IPoolManager _poolManager,
        InstrumentRegistry _instrumentRegistry,
        SwapPoolRegistry _swapPoolRegistry,
        Currency _stable
    ) external initializer {
        __Ownable_init(initialOwner);
        poolManager = _poolManager;
        instrumentRegistry = _instrumentRegistry;
        swapPoolRegistry = _swapPoolRegistry;
        stable = _stable;
    }

    // ============ External Functions ============

    /// @notice Buy an instrument: swap USDC to market currency (if needed) and deposit
    /// @param instrumentId The globally unique instrument identifier
    /// @param amount The amount of stable currency to spend
    /// @return depositedAmount The actual amount deposited to the lending protocol
    function buy(bytes32 instrumentId, uint256 amount) external returns (uint256 depositedAmount) {
        if (amount == 0) revert InvalidAmount();

        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

        // Pull stable tokens from user
        IERC20(Currency.unwrap(stable)).safeTransferFrom(msg.sender, address(this), amount);

        // Swap if stable differs from the market's underlying currency
        if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
            PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
            depositedAmount = _executeSwap(swapPool, stable, marketCurrency, amount);
        } else {
            depositedAmount = amount;
        }

        // Deposit to lending protocol — yield tokens go to msg.sender
        IERC20(Currency.unwrap(marketCurrency)).forceApprove(adapter, depositedAmount);
        ILendingAdapter(adapter).deposit(marketId, depositedAmount, msg.sender);

        emit Buy(instrumentId, msg.sender, amount, depositedAmount);
    }

    /// @notice Sell an instrument: withdraw from lending and swap to USDC (if needed)
    /// @param instrumentId The globally unique instrument identifier
    /// @param yieldTokenAmount The amount of yield-bearing tokens to redeem
    /// @return outputAmount The actual amount of stable currency returned to the caller
    function sell(bytes32 instrumentId, uint256 yieldTokenAmount) external returns (uint256 outputAmount) {
        if (yieldTokenAmount == 0) revert InvalidAmount();

        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

        // Transfer yield tokens from user directly to adapter
        IERC20(yieldToken).safeTransferFrom(msg.sender, adapter, yieldTokenAmount);

        // Withdraw underlying from lending protocol
        uint256 withdrawnAmount = ILendingAdapter(adapter).withdraw(marketId, yieldTokenAmount, address(this));

        // Swap if market currency differs from stable
        if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
            PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
            outputAmount = _executeSwap(swapPool, marketCurrency, stable, withdrawnAmount);
        } else {
            outputAmount = withdrawnAmount;
        }

        // Send stable tokens to caller
        IERC20(Currency.unwrap(stable)).safeTransfer(msg.sender, outputAmount);

        emit Sell(instrumentId, msg.sender, yieldTokenAmount, outputAmount);
    }

    // ============ Callback ============

    /// @notice Called by PoolManager during unlock to execute the swap
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();

        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        bool zeroForOne = Currency.unwrap(data.swapPool.currency0) == Currency.unwrap(data.inputCurrency);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = poolManager.swap(
            data.swapPool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(data.inputAmount),
                sqrtPriceLimitX96: priceLimit
            }),
            ""
        );

        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();

        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwapDelta();

        uint256 settleAmount = uint256(-int256(inputDelta));
        uint256 outputAmount = uint256(int256(outputDelta));

        // Settle input tokens (router owes PM)
        poolManager.sync(data.inputCurrency);
        IERC20(Currency.unwrap(data.inputCurrency)).transfer(address(poolManager), settleAmount);
        poolManager.settle();

        // Take output tokens (PM owes router)
        poolManager.take(data.outputCurrency, address(this), outputAmount);

        return abi.encode(outputAmount);
    }

    // ============ Internal ============

    function _executeSwap(PoolKey memory swapPool, Currency inputCurrency, Currency outputCurrency, uint256 inputAmount)
        internal
        returns (uint256 outputAmount)
    {
        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    swapPool: swapPool,
                    inputCurrency: inputCurrency,
                    outputCurrency: outputCurrency,
                    inputAmount: inputAmount
                })
            )
        );
        outputAmount = abi.decode(result, (uint256));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============

    uint256[46] private __gap;
}
