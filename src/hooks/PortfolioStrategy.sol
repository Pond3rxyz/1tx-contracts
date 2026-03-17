// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {InstrumentRegistry} from "../registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../registries/SwapPoolRegistry.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {SwapExecutor} from "../libraries/SwapExecutor.sol";
import {LendingExecutor} from "../libraries/LendingExecutor.sol";
import {PortfolioVault} from "./PortfolioVault.sol";

/// @title PortfolioStrategy
/// @notice Upgradeable strategy logic for deploying, withdrawing, and rebalancing capital
/// @dev Shared across all PortfolioVault instances. Upgrading the implementation benefits
///      all vaults that reference this strategy. Contains no fund custody — tokens flow
///      through temporarily during operations and are always returned to the vault.
contract PortfolioStrategy is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using Math for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============

    uint16 public constant BPS_DENOMINATOR = 10000;
    uint256 internal constant DUST_THRESHOLD = 100; // min deposit amount — Aave reverts on tiny supplies

    // ============ Types ============

    /// @dev Packed vault context to avoid stack-too-deep in loop bodies
    struct VaultCtx {
        PortfolioVault vault;
        Currency stable;
        IPoolManager pm;
        InstrumentRegistry ir;
        SwapPoolRegistry spr;
        uint16 maxSlippage;
    }

    // ============ Constructor / Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    // ============ Strategy Functions ============

    /// @notice Deploy stable tokens across lending positions per allocation weights
    /// @dev Called by vault.deployCapital(). Vault transfers stables to this contract first.
    ///      Yield tokens are deposited to the vault via onBehalfOf parameter.
    /// @param stableAmount Amount of stable tokens already transferred to this contract
    function executeDeployCapital(uint256 stableAmount) external {
        VaultCtx memory ctx = _loadCtx();
        PortfolioVault.Allocation[] memory allocs = ctx.vault.getAllocations();

        for (uint256 i = 0; i < allocs.length; i++) {
            uint256 amount = (stableAmount * allocs[i].weightBps) / BPS_DENOMINATOR;
            if (amount < DUST_THRESHOLD) continue;
            _deployOneAllocation(ctx, allocs[i].instrumentId, amount);
        }

        // Return any remaining dust to vault
        _returnStableToVault(ctx);
    }

    /// @notice Withdraw stable tokens from lending positions proportionally
    /// @dev Called by vault.withdrawCapital(). Strategy pulls yield tokens from vault
    ///      via vault.strategyTransfer(), withdraws from lending, and sends stables to vault.
    /// @param stableNeeded Amount of stable the vault needs for settlement
    function executeWithdrawCapital(uint256 stableNeeded) external {
        VaultCtx memory ctx = _loadCtx();
        PortfolioVault.Allocation[] memory allocs = ctx.vault.getAllocations();

        uint256 lendingNav = ctx.vault.lendingPositionsValue();
        if (lendingNav > 0) {
            for (uint256 i = 0; i < allocs.length; i++) {
                _withdrawOneAllocation(ctx, allocs[i].instrumentId, stableNeeded, lendingNav);
            }
        }

        _returnStableToVault(ctx);
    }

    /// @notice Rebalance portfolio to match target allocation weights
    /// @dev Called by vault.unlockCallback() inside PoolManager unlock context.
    ///      Two-pass algorithm: first withdraw from over-allocated, then deposit to under-allocated.
    function executeRebalance() external {
        VaultCtx memory ctx = _loadCtx();
        PortfolioVault.Allocation[] memory allocs = ctx.vault.getAllocations();

        uint256 nav = ctx.vault.totalAssets();
        if (nav == 0) return;

        // Pull any undeployed stable from vault
        address stableAddr = Currency.unwrap(ctx.stable);
        uint256 vaultStable = IERC20(stableAddr).balanceOf(address(ctx.vault));
        if (vaultStable > 0) {
            ctx.vault.strategyTransfer(stableAddr, address(this), vaultStable);
        }
        uint256 stableAccumulated = IERC20(stableAddr).balanceOf(address(this));

        // First pass: withdraw from over-allocated positions, accumulate stable
        for (uint256 i = 0; i < allocs.length; i++) {
            uint256 currentValue = ctx.vault.getAllocationValue(i);
            uint256 targetValue = (nav * allocs[i].weightBps) / BPS_DENOMINATOR;

            if (currentValue > targetValue) {
                stableAccumulated +=
                    _rebalanceWithdraw(ctx, allocs[i].instrumentId, currentValue, currentValue - targetValue);
            }
        }

        // Second pass: deposit into under-allocated positions
        for (uint256 i = 0; i < allocs.length; i++) {
            uint256 currentValue = ctx.vault.getAllocationValue(i);
            uint256 targetValue = (nav * allocs[i].weightBps) / BPS_DENOMINATOR;

            if (currentValue < targetValue) {
                uint256 deficit = targetValue - currentValue;
                uint256 depositAmount = deficit < stableAccumulated ? deficit : stableAccumulated;
                if (depositAmount < DUST_THRESHOLD) continue;

                _deployOneAllocation(ctx, allocs[i].instrumentId, depositAmount);
                stableAccumulated -= depositAmount;
            }
        }

        // Return any remaining stables to vault
        _returnStableToVault(ctx);
    }

    // ============ Internal: Context ============

    function _loadCtx() internal view returns (VaultCtx memory ctx) {
        ctx.vault = PortfolioVault(msg.sender);
        ctx.stable = ctx.vault.stable();
        ctx.pm = ctx.vault.poolManager();
        ctx.ir = ctx.vault.instrumentRegistry();
        ctx.spr = ctx.vault.swapPoolRegistry();
        ctx.maxSlippage = ctx.vault.maxSlippageBps();
    }

    function _returnStableToVault(VaultCtx memory ctx) internal {
        address stableAddr = Currency.unwrap(ctx.stable);
        uint256 balance = IERC20(stableAddr).balanceOf(address(this));
        if (balance > 0) {
            IERC20(stableAddr).safeTransfer(address(ctx.vault), balance);
        }
    }

    // ============ Internal: Deploy ============

    function _deployOneAllocation(VaultCtx memory ctx, bytes32 instrumentId, uint256 amount) internal {
        (address adapter, bytes32 marketId) = ctx.ir.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

        uint256 depositAmount = amount;
        if (Currency.unwrap(ctx.stable) != Currency.unwrap(marketCurrency)) {
            depositAmount = _swapToMarket(ctx, marketCurrency, amount);
        }

        LendingExecutor.deposit(adapter, marketId, marketCurrency, depositAmount, address(ctx.vault));
    }

    // ============ Internal: Withdraw ============

    function _withdrawOneAllocation(
        VaultCtx memory ctx,
        bytes32 instrumentId,
        uint256 stableNeeded,
        uint256 lendingNav
    ) internal {
        (address adapter, bytes32 marketId) = ctx.ir.getInstrumentDirect(instrumentId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

        uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(ctx.vault));
        uint256 yieldAmount = (yieldBalance * stableNeeded + lendingNav - 1) / lendingNav;
        if (yieldAmount > yieldBalance) yieldAmount = yieldBalance;
        if (yieldAmount == 0) return;

        ctx.vault.strategyTransfer(yieldToken, address(this), yieldAmount);

        uint256 withdrawn =
            LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldAmount, address(this), address(this));

        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        if (Currency.unwrap(marketCurrency) != Currency.unwrap(ctx.stable)) {
            _swapToStable(ctx, marketCurrency, withdrawn);
        }
    }

    // ============ Internal: Rebalance Withdraw ============

    function _rebalanceWithdraw(VaultCtx memory ctx, bytes32 instrumentId, uint256 currentValue, uint256 excess)
        internal
        returns (uint256 withdrawn)
    {
        (address adapter, bytes32 marketId) = ctx.ir.getInstrumentDirect(instrumentId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

        uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(ctx.vault));
        uint256 yieldToWithdraw = currentValue > 0 ? (yieldBalance * excess) / currentValue : 0;
        if (yieldToWithdraw == 0) return 0;

        ctx.vault.strategyTransfer(yieldToken, address(this), yieldToWithdraw);

        withdrawn =
            LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldToWithdraw, address(this), address(this));

        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        if (Currency.unwrap(marketCurrency) != Currency.unwrap(ctx.stable)) {
            withdrawn = _swapToStable(ctx, marketCurrency, withdrawn);
        }
    }

    // ============ Internal: Swap Helpers ============

    function _swapToMarket(VaultCtx memory ctx, Currency marketCurrency, uint256 amount)
        internal
        returns (uint256 output)
    {
        PoolKey memory swapPool = ctx.spr.getDefaultSwapPool(ctx.stable, marketCurrency);
        uint256 minOutput = _getMinSwapOutput(ctx.pm, swapPool, ctx.stable, amount, ctx.maxSlippage);
        output = SwapExecutor.executeSwap(ctx.pm, swapPool, ctx.stable, marketCurrency, amount, minOutput);
    }

    function _swapToStable(VaultCtx memory ctx, Currency marketCurrency, uint256 amount)
        internal
        returns (uint256 output)
    {
        PoolKey memory swapPool = ctx.spr.getDefaultSwapPool(marketCurrency, ctx.stable);
        uint256 minOutput = _getMinSwapOutput(ctx.pm, swapPool, marketCurrency, amount, ctx.maxSlippage);
        output = SwapExecutor.executeSwap(ctx.pm, swapPool, marketCurrency, ctx.stable, amount, minOutput);
    }

    /// @notice Compute minimum acceptable output for a swap based on pool spot price and slippage tolerance
    function _getMinSwapOutput(
        IPoolManager pm,
        PoolKey memory swapPool,
        Currency inputCurrency,
        uint256 inputAmount,
        uint16 maxSlippageBps
    ) internal view returns (uint256) {
        if (maxSlippageBps == 0) return 0;

        PoolId poolId = swapPool.toId();
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(poolId);

        bool zeroForOne = Currency.unwrap(swapPool.currency0) == Currency.unwrap(inputCurrency);
        uint256 expectedOutput;
        if (zeroForOne) {
            expectedOutput = Math.mulDiv(Math.mulDiv(inputAmount, sqrtPriceX96, 2 ** 96), sqrtPriceX96, 2 ** 96);
        } else {
            expectedOutput = Math.mulDiv(Math.mulDiv(inputAmount, 2 ** 96, sqrtPriceX96), 2 ** 96, sqrtPriceX96);
        }
        return (expectedOutput * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============

    uint256[50] private __gap;
}
