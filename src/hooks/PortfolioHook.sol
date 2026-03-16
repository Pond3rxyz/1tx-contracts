// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {PortfolioVault} from "./PortfolioVault.sol";

/// @title PortfolioHook
/// @notice Uniswap V4 hook settling swaps directly at vault NAV in beforeSwap
/// @dev Uses beforeSwap return-delta custom accounting to fully bypass AMM liquidity.
contract PortfolioHook is BaseHook {
    using CurrencyLibrary for Currency;

    PortfolioVault public immutable VAULT;
    Currency public immutable STABLE;

    /// @dev Tracks shares settled to PM during a buy (cleared in afterSwap).
    /// afterSwap must not burn these — the router still needs to take them.
    uint256 private _buySharesSettled;

    error ZeroAmount();
    error LiquidityNotAllowed();
    error InvalidPoolCurrencies();
    error NonZeroPoolFee();
    error DeltaOverflow();
    error InsufficientStableForSettlement(uint256 needed, uint256 available);
    error SellSettlementExceedsNav(uint256 needed, uint256 maxAvailable);

    event SharesBought(address indexed recipient, uint256 stableAmount, uint256 shares);
    event SharesSold(address indexed owner, uint256 shares, uint256 stableAmount);
    event SwapRouted(address indexed recipient, bool isBuy, bool usedAmm, uint256 amountSpecified);

    constructor(IPoolManager _poolManager, PortfolioVault _vault, Currency _stable) BaseHook(_poolManager) {
        VAULT = _vault;
        STABLE = _stable;
    }

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

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePoolCurrencies(key);
        if (key.fee != 0) revert NonZeroPoolFee();

        bool stableIsToken0 = Currency.unwrap(key.currency0) == Currency.unwrap(STABLE);
        bool isBuy = params.zeroForOne == stableIsToken0;
        bool isExactInput = params.amountSpecified < 0;
        uint256 amountSpecified = _absAmount(params.amountSpecified);
        if (amountSpecified == 0) revert ZeroAmount();

        Currency shareCurrency = stableIsToken0 ? key.currency1 : key.currency0;
        address recipient = _decodeRecipient(sender, hookData);
        int128 deltaSpecified = -_toInt128Signed(params.amountSpecified);

        if (isBuy) {
            int128 buyDeltaUnspecified = _handleBuy(shareCurrency, isExactInput, amountSpecified, recipient);
            return (this.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, buyDeltaUnspecified), 0);
        }

        int128 sellDeltaUnspecified = _handleSell(shareCurrency, isExactInput, amountSpecified, recipient);
        return (this.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, sellDeltaUnspecified), 0);
    }

    function _handleBuy(Currency shareCurrency, bool isExactInput, uint256 amountSpecified, address recipient)
        internal
        returns (int128 deltaUnspecified)
    {
        uint256 stableAmount = isExactInput ? amountSpecified : VAULT.previewMint(amountSpecified);
        uint256 shareAmount = isExactInput ? VAULT.convertToShares(amountSpecified) : amountSpecified;

        poolManager.take(STABLE, address(this), stableAmount);
        IERC20(Currency.unwrap(STABLE)).transfer(address(VAULT), stableAmount);
        VAULT.deployCapital(stableAmount);

        VAULT.mintShares(address(this), shareAmount);
        poolManager.sync(shareCurrency);
        IERC20(address(VAULT)).transfer(address(poolManager), shareAmount);
        poolManager.settle();

        _buySharesSettled = shareAmount; // solhint-disable-line reentrancy

        emit SharesBought(recipient, stableAmount, shareAmount);
        emit SwapRouted(recipient, true, false, amountSpecified);

        deltaUnspecified = isExactInput ? -_toInt128(shareAmount) : _toInt128(stableAmount);
    }

    function _handleSell(Currency shareCurrency, bool isExactInput, uint256 amountSpecified, address recipient)
        internal
        returns (int128 deltaUnspecified)
    {
        uint256 stableAmount;
        uint256 shareAmount;

        if (isExactInput) {
            shareAmount = amountSpecified;
            stableAmount = VAULT.convertToAssets(shareAmount);
        } else {
            stableAmount = amountSpecified;
            uint256 maxAvailable = VAULT.totalAssets();
            if (stableAmount > maxAvailable) revert SellSettlementExceedsNav(stableAmount, maxAvailable);
            shareAmount = VAULT.previewWithdraw(stableAmount);
        }

        uint256 stableOut = VAULT.withdrawCapital(stableAmount);
        if (stableOut < stableAmount) revert InsufficientStableForSettlement(stableAmount, stableOut);

        poolManager.sync(STABLE);
        IERC20(Currency.unwrap(STABLE)).transfer(address(poolManager), stableAmount);
        poolManager.settle();

        poolManager.mint(address(this), shareCurrency.toId(), shareAmount);

        emit SharesSold(recipient, shareAmount, stableAmount);
        emit SwapRouted(recipient, false, false, amountSpecified);

        deltaUnspecified = isExactInput ? -_toInt128(stableAmount) : _toInt128(shareAmount);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev Burn dead ERC-20 shares in PoolManager from previous sell settlements.
    /// On buys, PM holds shares that the router will deliver — those are protected via
    /// _buySharesSettled. Only the excess (from previous sells) is burned.
    /// The vault's conversion functions also use effective supply (excluding PM balance)
    /// so NAV is always accurate even before the burn.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 liveShares = _buySharesSettled;
        _buySharesSettled = 0;

        uint256 pmShares = IERC20(address(VAULT)).balanceOf(address(poolManager));
        if (pmShares > liveShares) {
            VAULT.burnShares(address(poolManager), pmShares - liveShares);
        }
        return (this.afterSwap.selector, 0);
    }

    function _validatePoolCurrencies(PoolKey calldata key) internal view {
        address stableAddr = Currency.unwrap(STABLE);
        address shareAddr = address(VAULT);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (!((c0 == stableAddr && c1 == shareAddr) || (c0 == shareAddr && c1 == stableAddr))) {
            revert InvalidPoolCurrencies();
        }
    }

    function _decodeRecipient(address sender, bytes calldata hookData) internal pure returns (address recipient) {
        if (hookData.length == 32) {
            recipient = abi.decode(hookData, (address));
            if (recipient != address(0)) return recipient;
        }
        return sender;
    }

    function _toInt128(uint256 value) internal pure returns (int128) {
        if (value > uint256(int256(type(int128).max))) revert DeltaOverflow();
        return int128(uint128(value));
    }

    function _toInt128Signed(int256 value) internal pure returns (int128) {
        if (value > int256(type(int128).max) || value < int256(type(int128).min)) revert DeltaOverflow();
        return int128(value);
    }

    function _absAmount(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
    }
}
