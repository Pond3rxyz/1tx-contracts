// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PortfolioVault} from "./PortfolioVault.sol";

/// @title PortfolioHook
/// @notice Uniswap V4 hook that acts as an on-chain index fund distribution layer
/// @dev Uses "flash liquidity" pattern: provides phantom concentrated liquidity at NAV price
///      in beforeSwap, lets the AMM execute the swap (moving sqrtPrice), then removes liquidity
///      in afterSwap and settles only the net delta. V4's deferred settlement means no actual
///      capital is needed for the liquidity — only the net swap amount is settled.
contract PortfolioHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ============ State ============

    PortfolioVault public immutable vault;
    Currency public immutable stable;

    /// @dev Flash liquidity state passed from beforeSwap to afterSwap (transient-like)
    int24 private _flashTickLower;
    int24 private _flashTickUpper;
    int128 private _flashLiquidityDelta;
    BalanceDelta private _flashAddDelta;

    /// @dev Persistent minimal seed liquidity kept in-pool across swaps.
    bool private _seedInitialized;

    /// @dev Depth multiplier for flash liquidity (how much virtual depth relative to totalAssets)
    /// Higher = less price impact per swap. 1e18 = 1x totalAssets as depth.
    uint256 public constant DEPTH_MULTIPLIER = 10e18; // 10x totalAssets
    uint256 public constant MIN_SEED_STABLE = 10e6; // 10 USDC (6 decimals)

    // ============ Errors ============

    error ZeroAmount();
    error LiquidityNotAllowed();
    error InsufficientStableForSettlement(uint256 needed, uint256 available);
    error SellSettlementExceedsNav(uint256 needed, uint256 maxAvailable);
    // ============ Events ============

    event SharesBought(address indexed recipient, uint256 stableAmount, uint256 shares);
    event SharesSold(address indexed owner, uint256 shares, uint256 stableAmount);
    event SwapRouted(address indexed recipient, bool isBuy, bool usedAmm, uint256 amountSpecified);

    // ============ Constructor ============

    constructor(IPoolManager _poolManager, PortfolioVault _vault, Currency _stable)
        BaseHook(_poolManager)
    {
        vault = _vault;
        stable = _stable;
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook Implementation ============

    /// @dev Add flash liquidity at NAV price before each swap
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 amount = _absAmount(params.amountSpecified);
        if (amount == 0) revert ZeroAmount();

        bool stableIsToken0 = Currency.unwrap(key.currency0) == Currency.unwrap(stable);
        bool isBuy = params.zeroForOne == stableIsToken0;
        address recipient = msg.sender;

        // For exact-output sells (shares -> stable), reject requests that exceed current NAV.
        // This provides a clear early revert instead of failing later during settlement.
        if (!isBuy && params.amountSpecified > 0) {
            uint256 requestedStableOut = uint256(params.amountSpecified);
            uint256 maxAvailable = vault.totalAssets();
            if (requestedStableOut > maxAvailable) revert SellSettlementExceedsNav(requestedStableOut, maxAvailable);
        }

        uint128 liquidity = _calculateFlashLiquidity(key, amount);

        if (liquidity == 0) {
            emit SwapRouted(recipient, isBuy, true, amount);
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Add phantom liquidity — delta tracked, no tokens move (V4 deferred settlement)
        (BalanceDelta addDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: _flashTickLower,
                tickUpper: _flashTickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        _flashAddDelta = addDelta;

        emit SwapRouted(recipient, isBuy, true, amount);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Calculate flash liquidity params and store tick range for afterSwap
    function _calculateFlashLiquidity(PoolKey calldata key, uint256 swapAmount)
        internal
        returns (uint128 liquidity)
    {
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = ((currentTick - 5 * tickSpacing) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 5 * tickSpacing) / tickSpacing) * tickSpacing;

        // Clamp to valid range
        if (tickLower < TickMath.MIN_TICK) tickLower = (TickMath.MIN_TICK / tickSpacing + 1) * tickSpacing;
        if (tickUpper > TickMath.MAX_TICK) tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        if (tickLower >= tickUpper) tickUpper = tickLower + tickSpacing;

        // Calculate depth: totalAssets * multiplier, or swap amount for first deposit
        uint256 depth = vault.totalAssets();
        if (depth == 0) depth = swapAmount;
        depth = (depth * DEPTH_MULTIPLIER) / 1e18;

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            depth,
            depth
        );

        // Store for afterSwap
        _flashTickLower = tickLower;
        _flashTickUpper = tickUpper;
        _flashLiquidityDelta = int128(uint128(liquidity));
    }

    /// @dev Remove flash liquidity and settle net delta after swap
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        int128 liquidityDelta = _flashLiquidityDelta;
        if (liquidityDelta == 0) return (this.afterSwap.selector, 0);

        // Read add delta before clearing
        BalanceDelta addDelta = _flashAddDelta;

        // Remove the flash liquidity and get the remove-side delta
        BalanceDelta removeDelta = _removeFlashLiquidity(key, liquidityDelta);

        // Settle the net delta from add+remove
        _settleNetDelta(key, params, addDelta, removeDelta);

        // Keep tiny persistent liquidity to improve bootstrap UX.
        _initializeSeedLiquidity(key);

        return (this.afterSwap.selector, 0);
    }

    function _absAmount(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
    }

    function _initializeSeedLiquidity(PoolKey calldata key) internal {
        if (_seedInitialized) return;

        uint256 stableBal = IERC20(Currency.unwrap(stable)).balanceOf(address(vault));
        if (stableBal == 0) return;

        uint256 stableToSeed = stableBal < MIN_SEED_STABLE ? stableBal : MIN_SEED_STABLE;
        if (stableToSeed == 0) return;

        (bool stableIsToken0, uint256 shareToSeed) = _prepareSeedShares(key, stableToSeed);
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            _computeSeedLiquidity(key, stableIsToken0, stableToSeed, shareToSeed);
        if (liquidity == 0) return;

        (BalanceDelta seedDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(uint256(1))
            }),
            ""
        );

        _settleCurrencyDebt(key.currency0, seedDelta.amount0());
        _settleCurrencyDebt(key.currency1, seedDelta.amount1());

        _seedInitialized = true;
    }

    function _prepareSeedShares(PoolKey calldata key, uint256 stableToSeed)
        internal
        returns (bool stableIsToken0, uint256 shareToSeed)
    {
        stableIsToken0 = Currency.unwrap(key.currency0) == Currency.unwrap(stable);
        // Pull seed stable from vault to hook before adding seed liquidity.
        IERC20(Currency.unwrap(stable)).transferFrom(address(vault), address(this), stableToSeed);
        shareToSeed = vault.previewDeposit(stableToSeed);
        if (shareToSeed == 0) shareToSeed = stableToSeed;
        vault.mintShares(address(this), shareToSeed);
    }

    function _computeSeedLiquidity(PoolKey calldata key, bool stableIsToken0, uint256 stableToSeed, uint256 shareToSeed)
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 tickSpacing = key.tickSpacing;

        tickLower = ((currentTick - tickSpacing) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + tickSpacing) / tickSpacing) * tickSpacing;
        if (tickLower >= tickUpper) tickUpper = tickLower + tickSpacing;

        uint256 amount0 = stableIsToken0 ? stableToSeed : shareToSeed;
        uint256 amount1 = stableIsToken0 ? shareToSeed : stableToSeed;

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function _settleCurrencyDebt(Currency currency, int128 delta) internal {
        if (delta >= 0) return;

        uint256 settleAmount = uint256(int256(-delta));
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(poolManager), settleAmount);
        poolManager.settle();
    }

    function _removeFlashLiquidity(PoolKey calldata key, int128 liquidityDelta)
        internal
        returns (BalanceDelta removeDelta)
    {
        (removeDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: _flashTickLower,
                tickUpper: _flashTickUpper,
                liquidityDelta: -int256(uint256(uint128(liquidityDelta))),
                salt: bytes32(0)
            }),
            ""
        );

        // Clear flash state
        _flashTickLower = 0;
        _flashTickUpper = 0;
        _flashLiquidityDelta = 0;
        _flashAddDelta = BalanceDeltaLibrary.ZERO_DELTA;
    }

    function _settleNetDelta(PoolKey calldata key, SwapParams calldata params, BalanceDelta addDelta, BalanceDelta removeDelta)
        internal
    {
        // Net delta = addDelta + removeDelta
        // addDelta is negative (hook owes PM), removeDelta is positive (PM owes hook)
        // The difference is the swap amount flowing through the position
        int128 net0 = addDelta.amount0() + removeDelta.amount0();
        int128 net1 = addDelta.amount1() + removeDelta.amount1();

        bool stableIsToken0 = Currency.unwrap(key.currency0) == Currency.unwrap(stable);
        Currency shareCurrency = stableIsToken0 ? key.currency1 : key.currency0;

        int128 netStable = stableIsToken0 ? net0 : net1;
        int128 netShares = stableIsToken0 ? net1 : net0;

        bool isBuy = params.zeroForOne == stableIsToken0;
        address recipient = msg.sender;

        if (isBuy) {
            _settleBuy(key, shareCurrency, netStable, netShares, recipient);
        } else {
            _settleSell(key, shareCurrency, netStable, netShares, recipient);
        }
    }

    /// @notice Prevents adding liquidity — only hook manages LP via flash liquidity
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @notice Prevents removing liquidity — only hook manages LP via flash liquidity
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    // ============ Internal Settlement ============

    /// @notice Settle a buy swap: user sent stable, received shares
    /// @dev Hook's net delta after flash liquidity: +stable (PM owes hook), -shares (hook owes PM)
    ///      Take stable from PM → vault deploys to lending.
    ///      Vault mints shares to hook → hook settles to PM.
    function _settleBuy(
        PoolKey calldata,
        Currency shareCurrency,
        int128 netStable,
        int128 netShares,
        address recipient
    ) internal {
        // netStable > 0: PM owes us stable. Take it and deploy to lending.
        if (netStable > 0) {
            uint256 stableAmount = uint256(int256(netStable));
            poolManager.take(stable, address(this), stableAmount);

            IERC20(Currency.unwrap(stable)).transfer(address(vault), stableAmount);
            vault.deployCapital(stableAmount);

            // netShares < 0: we owe PM shares. Mint and settle.
            uint256 shareAmount = uint256(int256(-netShares));
            vault.mintShares(address(this), shareAmount);

            // Transfer shares to PM to settle our negative delta
            poolManager.sync(shareCurrency);
            IERC20(address(vault)).transfer(address(poolManager), shareAmount);
            poolManager.settle();

            emit SharesBought(recipient, stableAmount, shareAmount);
        }
        // If netStable <= 0, no meaningful swap occurred (edge case)
    }

    /// @notice Settle a sell swap: user sent shares, received stable
    /// @dev Hook's net delta after flash liquidity: -stable (hook owes PM), +shares (PM owes hook)
    ///      Vault withdraws from lending → hook settles stable to PM.
    ///      For shares: zero hook's positive share delta via ERC6909 mint.
    function _settleSell(
        PoolKey calldata,
        Currency shareCurrency,
        int128 netStable,
        int128 netShares,
        address recipient
    ) internal {
        // netStable < 0: we owe PM stable. Withdraw from lending and settle.
        if (netStable < 0) {
            uint256 stableNeeded = uint256(int256(-netStable));
            uint256 maxAvailable = vault.totalAssets();
            if (stableNeeded > maxAvailable) revert SellSettlementExceedsNav(stableNeeded, maxAvailable);
            uint256 bufferedNeeded = stableNeeded + (stableNeeded / 10_000) + 1;
            vault.withdrawCapital(bufferedNeeded);
            uint256 stableBal = IERC20(Currency.unwrap(stable)).balanceOf(address(this));
            if (stableBal < stableNeeded) revert InsufficientStableForSettlement(stableNeeded, stableBal);

            // Settle stable to PM
            poolManager.sync(stable);
            IERC20(Currency.unwrap(stable)).transfer(address(poolManager), stableNeeded);
            poolManager.settle();

            // netShares > 0: PM owes us shares. Zero this with ERC6909 mint.
            if (netShares > 0) {
                uint256 shareAmount = uint256(int256(netShares));
                poolManager.mint(address(this), shareCurrency.toId(), shareAmount);
            }

            emit SharesSold(recipient, netShares > 0 ? uint256(int256(netShares)) : 0, stableNeeded);
        }
    }
}
