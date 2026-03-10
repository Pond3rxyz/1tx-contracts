// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../registries/SwapPoolRegistry.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {SwapExecutor} from "../libraries/SwapExecutor.sol";
import {LendingExecutor} from "../libraries/LendingExecutor.sol";

/// @title PortfolioVault
/// @notice ERC-4626-like vault that holds diversified lending positions
/// @dev Upgradeable strategy layer. Only the authorized hook can trigger capital deployment,
///      withdrawal, and share minting. Uses flash liquidity pattern — the hook provides
///      phantom liquidity at NAV price via V4's deferred settlement, and calls these
///      functions to settle the net delta after each swap.
contract PortfolioVault is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using Math for uint256;

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

    // ============ State ============

    Currency public stable;
    Allocation[] public allocations;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    IPoolManager public poolManager;
    address public hook;

    // ============ Errors ============

    error OnlyHook();
    error CallerNotPoolManager();
    error InvalidAllocationsLength();
    error WeightsMustSumTo10000();
    error InstrumentNotRegistered();
    error TooManyAllocations();
    error HookAlreadySet();
    error InvalidHookAddress();

    // ============ Events ============

    event Allocated(uint256 stableAmount);
    event Deallocated(uint256 stableReturned);
    event AllocationsUpdated(uint256 count);
    event Rebalanced();
    event HookSet(address indexed hook);
    event SharesBurned(address indexed from, uint256 amount);

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

    // ============ ERC-4626 View Functions ============

    function asset() public view returns (address) {
        return Currency.unwrap(stable);
    }

    /// @notice Total NAV of all underlying positions denominated in stable
    function totalAssets() public view returns (uint256 totalNav) {
        for (uint256 i = 0; i < allocations.length; i++) {
            totalNav += _getAllocationValue(i);
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(totalSupply() + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(totalAssets() + VIRTUAL_ASSETS, totalSupply() + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    // ============ Hook-Only Functions ============

    /// @notice Deploy stable tokens to lending positions according to allocation weights
    /// @dev Called by hook in afterSwap to deploy USDC received from a buy swap.
    ///      Vault must already hold the stableAmount (hook takes from PM to vault).
    /// @param stableAmount Amount of stable to deploy across lending positions
    function deployCapital(uint256 stableAmount) external onlyHook {
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 amount = (stableAmount * allocations[i].weightBps) / BPS_DENOMINATOR;
            if (amount == 0) continue;

            (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
            Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

            uint256 depositAmount = amount;

            // Swap stable -> marketCurrency if needed
            if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
                PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
                depositAmount = SwapExecutor.executeSwap(poolManager, swapPool, stable, marketCurrency, amount);
            }

            // Deposit into lending protocol — yield tokens stay in this vault
            LendingExecutor.deposit(adapter, marketId, marketCurrency, depositAmount, address(this));
        }

        emit Allocated(stableAmount);
    }

    /// @notice Withdraw stable tokens from lending positions proportionally
    /// @dev Called by hook in afterSwap to cover USDC owed from a sell swap.
    ///      Sends withdrawn stable to the hook for PM settlement.
    /// @param stableNeeded Approximate amount of stable needed
    /// @return stableOut Actual amount of stable sent to hook
    function withdrawCapital(uint256 stableNeeded) external onlyHook returns (uint256 stableOut) {
        uint256 nav = totalAssets();
        if (nav == 0) return 0;

        for (uint256 i = 0; i < allocations.length; i++) {
            (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
            Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
            address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

            uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
            // Withdraw proportionally: yieldBalance * stableNeeded / totalAssets
            uint256 yieldAmount = (yieldBalance * stableNeeded) / nav;
            if (yieldAmount > yieldBalance) yieldAmount = yieldBalance;
            if (yieldAmount == 0) continue;

            uint256 withdrawn =
                LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldAmount, address(this), address(this));

            // Swap marketCurrency -> stable if needed
            if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
                PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
                withdrawn = SwapExecutor.executeSwap(poolManager, swapPool, marketCurrency, stable, withdrawn);
            }

            stableOut += withdrawn;
        }

        // Transfer stable to hook for PM settlement
        IERC20(Currency.unwrap(stable)).safeTransfer(hook, stableOut);

        emit Deallocated(stableOut);
    }

    /// @notice Mint shares to an address (for hook delta settlement)
    /// @dev Only callable by hook. Used in afterSwap to mint shares that settle the hook's
    ///      negative share delta from flash liquidity removal.
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
        uint256 stableAccumulated;
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 currentValue = _getAllocationValue(i);
            uint256 targetValue = (nav * allocations[i].weightBps) / BPS_DENOMINATOR;

            if (currentValue > targetValue) {
                uint256 excess = currentValue - targetValue;
                (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
                Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
                address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

                uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
                uint256 allocationValue = currentValue;
                uint256 yieldToWithdraw = allocationValue > 0 ? (yieldBalance * excess) / allocationValue : 0;
                if (yieldToWithdraw == 0) continue;

                uint256 withdrawn =
                    LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldToWithdraw, address(this), address(this));

                if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
                    PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
                    withdrawn = SwapExecutor.executeSwap(poolManager, swapPool, marketCurrency, stable, withdrawn);
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
                if (depositAmount == 0) continue;

                (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[i].instrumentId);
                Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

                uint256 actualDeposit = depositAmount;
                if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
                    PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
                    actualDeposit = SwapExecutor.executeSwap(poolManager, swapPool, stable, marketCurrency, depositAmount);
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

    /// @notice Get the value of a single allocation in stable terms
    function _getAllocationValue(uint256 index) internal view returns (uint256) {
        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(allocations[index].instrumentId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);
        uint256 yieldBalance = IERC20(yieldToken).balanceOf(address(this));
        if (yieldBalance == 0) return 0;
        return _getUnderlyingValue(adapter, yieldToken, yieldBalance);
    }

    /// @notice Convert yield token balance to underlying value
    function _getUnderlyingValue(address, address yieldToken, uint256 yieldBalance)
        internal
        view
        returns (uint256)
    {
        try IERC4626Minimal(yieldToken).convertToAssets(yieldBalance) returns (uint256 assets) {
            return assets;
        } catch {
            return yieldBalance;
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============

    uint256[43] private __gap;
}

/// @dev Minimal interface for ERC4626 convertToAssets
interface IERC4626Minimal {
    function convertToAssets(uint256 shares) external view returns (uint256);
}
