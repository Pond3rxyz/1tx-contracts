// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuardTransient
} from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
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
import {IPortfolioStrategy} from "../interfaces/IPortfolioStrategy.sol";

/// @title PortfolioVault
/// @notice Non-upgradeable ERC20 vault that holds diversified lending positions
/// @dev Fund custodian + accounting layer. Strategy logic (deploy, withdraw, rebalance)
///      is delegated to an upgradeable PortfolioStrategy contract shared across vaults.
///      Only the authorized hook can trigger capital deployment, withdrawal, and share minting.
contract PortfolioVault is ERC20, Ownable, ReentrancyGuardTransient, IUnlockCallback {
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
        IPortfolioStrategy strategy;
        Allocation[] allocations;
    }

    // ============ Constants ============

    uint16 public constant MAX_ALLOCATIONS = 10;
    uint16 public constant BPS_DENOMINATOR = 10000;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1e6;
    uint16 internal constant DEFAULT_MAX_SLIPPAGE_BPS = 100; // 1%

    // ============ Immutables ============

    Currency public immutable stable;
    IPoolManager public immutable poolManager;
    InstrumentRegistry public immutable instrumentRegistry;
    SwapPoolRegistry public immutable swapPoolRegistry;
    IPortfolioStrategy public immutable strategy;

    // ============ State ============

    Allocation[] public allocations;
    address public hook;
    uint16 public maxSlippageBps;

    // ============ Errors ============

    error OnlyHook();
    error OnlyStrategy();
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

    modifier onlyStrategy() {
        if (msg.sender != address(strategy)) revert OnlyStrategy();
        _;
    }

    // ============ Constructor ============

    constructor(InitParams memory params) ERC20(params.name, params.symbol) Ownable(params.initialOwner) {
        stable = params.stable;
        poolManager = params.poolManager;
        instrumentRegistry = params.instrumentRegistry;
        swapPoolRegistry = params.swapPoolRegistry;
        strategy = params.strategy;
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

    /// @notice Share token decimals match the stable token (6 for USDC)
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function asset() public view returns (address) {
        return Currency.unwrap(stable);
    }

    /// @notice Total NAV: lending positions + any undeployed stable in vault
    function totalAssets() public view returns (uint256 totalNav) {
        totalNav = IERC20(Currency.unwrap(stable)).balanceOf(address(this));
        totalNav += lendingPositionsValue();
    }

    /// @notice Sum of all lending position values (yield tokens only, excludes undeployed stable)
    function lendingPositionsValue() public view returns (uint256 value) {
        for (uint256 i = 0; i < allocations.length; i++) {
            value += getAllocationValue(i);
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return
            assets.mulDiv(_effectiveTotalSupply() + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 effectiveSupply = _effectiveTotalSupply();
        uint256 totalNav = totalAssets();

        // When the caller is redeeming the full live supply, return the full NAV.
        // Applying the virtual offsets here strands residual assets on the final exit.
        if (shares != 0 && shares == effectiveSupply) return totalNav;

        return shares.mulDiv(totalNav + VIRTUAL_ASSETS, effectiveSupply + VIRTUAL_SHARES, Math.Rounding.Floor);
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
        uint256 effectiveSupply = _effectiveTotalSupply();
        uint256 totalNav = totalAssets();

        if (assets != 0 && assets == totalNav) return effectiveSupply;

        uint256 sharesNum = assets * (effectiveSupply + VIRTUAL_SHARES);
        uint256 sharesDen = totalNav + VIRTUAL_ASSETS;
        return sharesNum == 0 ? 0 : (sharesNum - 1) / sharesDen + 1;
    }

    // ============ Hook-Only Functions ============

    /// @notice Deploy stable tokens to lending positions via strategy
    /// @dev Called by hook in beforeSwap NAV settlement to deploy USDC received from a buy swap.
    ///      Vault must already hold the stableAmount (hook takes from PM to vault).
    /// @param stableAmount Amount of stable to deploy across lending positions
    function deployCapital(uint256 stableAmount) external onlyHook nonReentrant {
        IERC20(Currency.unwrap(stable)).safeTransfer(address(strategy), stableAmount);
        strategy.executeDeployCapital(stableAmount);
        emit Allocated(stableAmount);
    }

    /// @notice Withdraw stable tokens from lending positions via strategy
    /// @dev Strategy withdraws from lending and sends stables back to vault.
    ///      Vault then transfers exactly stableNeeded to the hook.
    /// @param stableNeeded Exact amount of stable the hook needs for settlement
    /// @return stableOut Actual amount of stable sent to hook
    function withdrawCapital(uint256 stableNeeded) external onlyHook nonReentrant returns (uint256 stableOut) {
        strategy.executeWithdrawCapital(stableNeeded);

        address stableAddr = Currency.unwrap(stable);
        uint256 available = IERC20(stableAddr).balanceOf(address(this));
        stableOut = available < stableNeeded ? available : stableNeeded;
        if (stableOut > 0) {
            IERC20(stableAddr).safeTransfer(hook, stableOut);
        }

        emit Deallocated(stableOut);
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

    // ============ Strategy Callback ============

    /// @notice Transfer tokens from vault to a destination (only callable by strategy)
    /// @dev Used by strategy to pull yield tokens during withdraw/rebalance operations
    function strategyTransfer(address token, address to, uint256 amount) external onlyStrategy {
        IERC20(token).safeTransfer(to, amount);
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
        strategy.executeRebalance();
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

    /// @notice Get the value of a single allocation in stable terms
    function getAllocationValue(uint256 index) public view returns (uint256) {
        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[index].instrumentId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);
        uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
        if (yieldBalance == 0) return 0;

        uint256 underlyingValue = ILendingAdapter(adapter).convertToUnderlying(marketId, yieldBalance);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        return _convertToStable(marketCurrency, underlyingValue);
    }

    // ============ Internal ============

    function _setAllocations(Allocation[] memory newAllocations) internal {
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
}
