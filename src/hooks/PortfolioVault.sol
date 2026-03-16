// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardTransient
} from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {InstrumentRegistry} from "../registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../registries/SwapPoolRegistry.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {SwapExecutor} from "../libraries/SwapExecutor.sol";
import {LendingExecutor} from "../libraries/LendingExecutor.sol";

/// @title PortfolioVault
/// @notice ERC-4626-like vault that holds diversified lending positions
/// @dev Upgradeable strategy layer. Only the authorized hook can trigger capital deployment,
///      withdrawal, and share minting. The hook settles swaps at NAV price via V4's
///      beforeSwapReturnDelta custom curve pattern and calls these functions to deploy
///      or withdraw capital during each swap.
contract PortfolioVault is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IUnlockCallback
{
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using Math for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ============ Types ============

    struct Allocation {
        bytes32 instrumentId;
        uint16 weightBps; // basis points (e.g., 5000 = 50%)
    }

    struct InitParams {
        address initialOwner;
        string name;
        string symbol;
        Currency stable;
        IPoolManager poolManager;
        InstrumentRegistry instrumentRegistry;
        SwapPoolRegistry swapPoolRegistry;
        Allocation[] allocations;
    }

    // ============ Constants ============

    uint16 public constant MAX_ALLOCATIONS = 10;
    uint16 public constant BPS_DENOMINATOR = 10000;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint16 internal constant DEFAULT_MAX_SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant DUST_THRESHOLD = 100; // skip deposits below this (avoids protocol min-amount reverts)

    // ============ State ============

    Currency public stable;
    Allocation[] public allocations;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    IPoolManager public poolManager;
    address public hook;
    uint16 public maxSlippageBps;

    // ============ Errors ============

    error OnlyHook();
    error CallerNotPoolManager();
    error InvalidAllocationsLength();
    error WeightsMustSumTo10000();
    error InstrumentNotRegistered();
    error TooManyAllocations();
    error HookAlreadySet();
    error InvalidHookAddress();
    error InvalidSlippageBps();

    // ============ Events ============

    event Allocated(uint256 stableAmount);
    event Deallocated(uint256 stableReturned);
    event AllocationsUpdated(uint256 count);
    event Rebalanced();
    event HookSet(address indexed hook);
    event SharesBurned(address indexed from, uint256 amount);
    event MaxSlippageUpdated(uint16 newSlippageBps);
    event HookApprovalRevoked();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    // ============ Constructor / Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external initializer {
        __ERC20_init(params.name, params.symbol);
        __Ownable_init(params.initialOwner);
        stable = params.stable;
        poolManager = params.poolManager;
        instrumentRegistry = params.instrumentRegistry;
        swapPoolRegistry = params.swapPoolRegistry;
        maxSlippageBps = DEFAULT_MAX_SLIPPAGE_BPS;
        _setAllocations(params.allocations);
    }

    /// @notice Set the hook address (can only be set once)
    function setHook(address _hook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (_hook == address(0)) revert InvalidHookAddress();
        hook = _hook;
        IERC20(Currency.unwrap(stable)).approve(_hook, type(uint256).max);
        emit HookSet(_hook);
    }

    /// @notice Revoke the unlimited stable approval granted to the hook
    /// @dev Emergency function in case the hook contract is compromised
    function revokeHookApproval() external onlyOwner {
        IERC20(Currency.unwrap(stable)).approve(hook, 0);
        emit HookApprovalRevoked();
    }

    /// @notice Set maximum slippage tolerance for internal swaps
    /// @param _maxSlippageBps Slippage in basis points (e.g., 100 = 1%)
    function setMaxSlippageBps(uint16 _maxSlippageBps) external onlyOwner {
        if (_maxSlippageBps > BPS_DENOMINATOR) revert InvalidSlippageBps();
        maxSlippageBps = _maxSlippageBps;
        emit MaxSlippageUpdated(_maxSlippageBps);
    }

    // ============ ERC-4626 View Functions ============

    function asset() public view returns (address) {
        return Currency.unwrap(stable);
    }

    /// @notice Total NAV of all underlying positions + idle stable, denominated in stable
    function totalAssets() public view returns (uint256 totalNav) {
        totalNav = IERC20(Currency.unwrap(stable)).balanceOf(address(this));
        totalNav += _lendingPositionsValue();
    }

    /// @notice Sum of all lending position values (yield tokens only, excludes idle stable)
    function _lendingPositionsValue() internal view returns (uint256 value) {
        for (uint256 i = 0; i < allocations.length; i++) {
            value += _getAllocationValue(i);
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return
            assets.mulDiv(_effectiveTotalSupply() + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return
            shares.mulDiv(totalAssets() + VIRTUAL_ASSETS, _effectiveTotalSupply() + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 assetsNum = shares * (totalAssets() + VIRTUAL_ASSETS);
        uint256 assetsDen = _effectiveTotalSupply() + VIRTUAL_SHARES;
        return assetsNum == 0 ? 0 : (assetsNum - 1) / assetsDen + 1;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 sharesNum = assets * (_effectiveTotalSupply() + VIRTUAL_SHARES);
        uint256 sharesDen = totalAssets() + VIRTUAL_ASSETS;
        return sharesNum == 0 ? 0 : (sharesNum - 1) / sharesDen + 1;
    }

    // ============ Hook-Only Functions ============

    /// @notice Deploy stable tokens to lending positions according to allocation weights
    /// @dev Called by hook in beforeSwap NAV settlement to deploy USDC received from a buy swap.
    ///      Vault must already hold the stableAmount (hook takes from PM to vault).
    /// @param stableAmount Amount of stable to deploy across lending positions
    function deployCapital(uint256 stableAmount) external onlyHook nonReentrant {
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 amount = (stableAmount * allocations[i].weightBps) / BPS_DENOMINATOR;
            if (amount < DUST_THRESHOLD) continue;

            (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
            Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

            uint256 depositAmount = amount;

            // Swap stable -> marketCurrency if needed
            if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
                PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
                uint256 minOutput = _getMinSwapOutput(swapPool, stable, amount);
                depositAmount =
                    SwapExecutor.executeSwap(poolManager, swapPool, stable, marketCurrency, amount, minOutput);
            }

            // Deposit into lending protocol — yield tokens stay in this vault
            LendingExecutor.deposit(adapter, marketId, marketCurrency, depositAmount, address(this));
        }

        emit Allocated(stableAmount);
    }

    /// @notice Withdraw stable tokens from lending positions to cover a sell
    /// @dev Uses idle stable first, then withdraws proportionally from lending (rounded up).
    ///      Guarantees returning at least stableNeeded if sufficient NAV exists.
    /// @param stableNeeded Exact amount of stable the hook needs for settlement
    /// @return stableOut Actual amount of stable sent to hook (>= stableNeeded if NAV sufficient)
    function withdrawCapital(uint256 stableNeeded) external onlyHook nonReentrant returns (uint256 stableOut) {
        address stableAddr = Currency.unwrap(stable);

        // Use idle stable held in vault first (e.g. excess from previous buffered withdrawals)
        uint256 idleStable = IERC20(stableAddr).balanceOf(address(this));
        if (idleStable >= stableNeeded) {
            IERC20(stableAddr).safeTransfer(hook, stableNeeded);
            emit Deallocated(stableNeeded);
            return stableNeeded;
        }

        uint256 remaining = stableNeeded - idleStable;

        // Withdraw proportionally from lending positions for the remainder
        uint256 lendingNav = _lendingPositionsValue();
        if (lendingNav > 0) {
            for (uint256 i = 0; i < allocations.length; i++) {
                (address adapter, bytes32 marketId) =
                    instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
                Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
                address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

                uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
                // Round up so withdrawal covers rounding dust
                uint256 yieldAmount = (yieldBalance * remaining + lendingNav - 1) / lendingNav;
                if (yieldAmount > yieldBalance) yieldAmount = yieldBalance;
                if (yieldAmount == 0) continue;

                uint256 withdrawn =
                    LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldAmount, address(this), address(this));

                // Swap marketCurrency -> stable if needed
                if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
                    PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
                    uint256 minOutput = _getMinSwapOutput(swapPool, marketCurrency, withdrawn);
                    withdrawn = SwapExecutor.executeSwap(
                        poolManager, swapPool, marketCurrency, stable, withdrawn, minOutput
                    );
                }

                stableOut += withdrawn;
            }
        }

        // Total output includes idle stable + lending withdrawals
        stableOut += idleStable;

        // Transfer to hook — use actual balance in case of rounding
        uint256 toTransfer = stableOut < stableNeeded ? stableOut : stableNeeded;
        if (toTransfer > 0) {
            IERC20(stableAddr).safeTransfer(hook, toTransfer);
        }

        emit Deallocated(toTransfer);
        return toTransfer;
    }

    /// @notice Mint shares to an address (for hook delta settlement)
    /// @dev Only callable by hook. Used in beforeSwap NAV settlement.
    function mintShares(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }

    function burnShares(address from, uint256 amount) external onlyHook {
        _burn(from, amount);
        emit SharesBurned(from, amount);
    }

    // ============ Admin Functions ============

    /// @notice Set portfolio allocation weights
    /// @param newAllocations Array of instrument IDs and weights (must sum to 10000 bps)
    function setAllocations(Allocation[] calldata newAllocations) external onlyOwner {
        _setAllocations(newAllocations);
    }

    /// @notice Rebalance portfolio to match target weights
    /// @dev Triggers poolManager.unlock() since this is called outside of swap context
    function rebalance() external onlyOwner {
        poolManager.unlock(abi.encode(true));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();

        uint256 nav = totalAssets();
        if (nav == 0) return "";

        // First pass: withdraw from over-allocated positions, accumulate stable
        // Start with any idle stable already in vault (e.g. from buffered withdrawal excess)
        uint256 stableAccumulated = IERC20(Currency.unwrap(stable)).balanceOf(address(this));
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 currentValue = _getAllocationValue(i);
            uint256 targetValue = (nav * allocations[i].weightBps) / BPS_DENOMINATOR;

            if (currentValue > targetValue) {
                uint256 excess = currentValue - targetValue;
                (address adapter, bytes32 marketId) =
                    instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
                Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
                address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

                uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
                uint256 allocationValue = currentValue;
                uint256 yieldToWithdraw = allocationValue > 0 ? (yieldBalance * excess) / allocationValue : 0;
                if (yieldToWithdraw == 0) continue;

                uint256 withdrawn = LendingExecutor.withdraw(
                    adapter, marketId, yieldToken, yieldToWithdraw, address(this), address(this)
                );

                if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
                    PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
                    uint256 minOutput = _getMinSwapOutput(swapPool, marketCurrency, withdrawn);
                    withdrawn =
                        SwapExecutor.executeSwap(poolManager, swapPool, marketCurrency, stable, withdrawn, minOutput);
                }

                stableAccumulated += withdrawn;
            }
        }

        // Second pass: deposit into under-allocated positions
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 currentValue = _getAllocationValue(i);
            uint256 targetValue = (nav * allocations[i].weightBps) / BPS_DENOMINATOR;

            if (currentValue < targetValue) {
                uint256 deficit = targetValue - currentValue;
                uint256 depositAmount = deficit < stableAccumulated ? deficit : stableAccumulated;
                if (depositAmount < DUST_THRESHOLD) continue;

                (address adapter, bytes32 marketId) =
                    instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
                Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

                uint256 actualDeposit = depositAmount;
                if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
                    PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
                    uint256 minOutput = _getMinSwapOutput(swapPool, stable, depositAmount);
                    actualDeposit = SwapExecutor.executeSwap(
                        poolManager, swapPool, stable, marketCurrency, depositAmount, minOutput
                    );
                }

                LendingExecutor.deposit(adapter, marketId, marketCurrency, actualDeposit, address(this));
                stableAccumulated -= depositAmount;
            }
        }

        emit Rebalanced();
        return "";
    }

    // ============ View Functions ============

    function getAllocations() external view returns (Allocation[] memory) {
        return allocations;
    }

    function getAllocationsLength() external view returns (uint256) {
        return allocations.length;
    }

    // ============ Internal ============

    function _setAllocations(Allocation[] calldata newAllocations) internal {
        if (newAllocations.length == 0) revert InvalidAllocationsLength();
        if (newAllocations.length > MAX_ALLOCATIONS) revert TooManyAllocations();

        uint256 totalWeight;
        for (uint256 i = 0; i < newAllocations.length; i++) {
            instrumentRegistry.getInstrumentDirect(newAllocations[i].instrumentId);
            totalWeight += newAllocations[i].weightBps;
        }
        if (totalWeight != BPS_DENOMINATOR) revert WeightsMustSumTo10000();

        delete allocations;
        for (uint256 i = 0; i < newAllocations.length; i++) {
            allocations.push(newAllocations[i]);
        }

        emit AllocationsUpdated(newAllocations.length);
    }

    /// @notice Effective total supply excluding shares held in transit by PoolManager.
    /// @dev During sells, the swap router settles the user's shares to PM after the hook
    ///      runs. These shares are "dead" (pending burn in afterSwap) and must be excluded
    ///      from NAV calculations to prevent dilution.
    function _effectiveTotalSupply() internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 pmBalance = balanceOf(address(poolManager));
        return pmBalance >= supply ? 0 : supply - pmBalance;
    }

    /// @notice Get the value of a single allocation in stable terms
    function _getAllocationValue(uint256 index) internal view returns (uint256) {
        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[index].instrumentId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);
        uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
        if (yieldBalance == 0) return 0;

        uint256 underlyingValue = ILendingAdapter(adapter).convertToUnderlying(marketId, yieldBalance);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        return _convertToStable(marketCurrency, underlyingValue);
    }

    /// @notice Convert an amount denominated in marketCurrency to stable terms using pool spot price
    /// @dev Uses Uniswap V4 pool's sqrtPriceX96 for conversion. No-op if currencies match.
    function _convertToStable(Currency marketCurrency, uint256 amount) internal view returns (uint256) {
        if (Currency.unwrap(marketCurrency) == Currency.unwrap(stable)) return amount;

        PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
        PoolId poolId = swapPool.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        bool stableIsToken0 = Currency.unwrap(swapPool.currency0) == Currency.unwrap(stable);

        if (stableIsToken0) {
            // price = token1/token0 = sqrtPriceX96^2 / 2^192
            // We have marketCurrency (token1), want stable (token0)
            // stableAmount = marketAmount / price = marketAmount * 2^192 / sqrtPriceX96^2
            return Math.mulDiv(Math.mulDiv(amount, 2 ** 96, sqrtPriceX96), 2 ** 96, sqrtPriceX96);
        } else {
            // price = token1/token0 = sqrtPriceX96^2 / 2^192
            // We have marketCurrency (token0), want stable (token1)
            // stableAmount = marketAmount * price = marketAmount * sqrtPriceX96^2 / 2^192
            return Math.mulDiv(Math.mulDiv(amount, sqrtPriceX96, 2 ** 96), sqrtPriceX96, 2 ** 96);
        }
    }

    /// @notice Compute minimum acceptable output for a swap based on pool spot price and slippage tolerance
    function _getMinSwapOutput(PoolKey memory swapPool, Currency inputCurrency, uint256 inputAmount)
        internal
        view
        returns (uint256)
    {
        if (maxSlippageBps == 0) return 0;

        PoolId poolId = swapPool.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        bool zeroForOne = Currency.unwrap(swapPool.currency0) == Currency.unwrap(inputCurrency);
        uint256 expectedOutput;
        if (zeroForOne) {
            // Selling token0 for token1: output = input * price
            expectedOutput = Math.mulDiv(Math.mulDiv(inputAmount, sqrtPriceX96, 2 ** 96), sqrtPriceX96, 2 ** 96);
        } else {
            // Selling token1 for token0: output = input / price
            expectedOutput = Math.mulDiv(Math.mulDiv(inputAmount, 2 ** 96, sqrtPriceX96), 2 ** 96, sqrtPriceX96);
        }
        return (expectedOutput * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============
    // Direct state variables: stable, allocations, instrumentRegistry, swapPoolRegistry, poolManager, hook, maxSlippageBps = 7
    // ReentrancyGuardTransient uses transient storage (no slot here).
    // Gap: 50 - 7 = 43. Verify with: forge inspect PortfolioVault storage-layout

    uint256[43] private __gap;
}
