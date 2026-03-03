// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title SwapPoolRegistry
/// @notice Registry for managing default Uniswap V4 swap pools used by the SwapDepositor hook
/// @dev Maps directional currency pairs to PoolKeys for swapping before deposits / after withdrawals
contract SwapPoolRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using CurrencyLibrary for Currency;

    // ============ Errors ============

    error InvalidInputCurrency();
    error InvalidOutputCurrency();
    error CurrenciesMustBeDifferent();
    error InvalidPoolKey();
    error PoolCurrenciesDontMatch();
    error PoolNotRegistered();
    error NoDefaultPoolRegistered();

    // ============ Events ============

    event DefaultSwapPoolRegistered(Currency indexed currencyIn, Currency indexed currencyOut, PoolKey poolKey);
    event DefaultSwapPoolUpdated(
        Currency indexed currencyIn, Currency indexed currencyOut, PoolKey oldPoolKey, PoolKey newPoolKey
    );
    event DefaultSwapPoolRemoved(Currency indexed currencyIn, Currency indexed currencyOut);

    // ============ State ============

    /// @notice Maps (currencyIn, currencyOut) hash to default PoolKey
    mapping(bytes32 => PoolKey) public defaultSwapPools;

    // ============ Constructor / Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract (replaces constructor for proxy pattern)
    /// @param initialOwner The initial owner of the registry
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    // ============ Admin Functions ============

    /// @notice Register a default swap pool for a currency pair
    /// @dev The pool must contain both currencies. Direction matters (USDC→USDT ≠ USDT→USDC).
    /// @param currencyIn The input currency
    /// @param currencyOut The output currency
    /// @param poolKey The PoolKey to use for swaps between these currencies
    function registerDefaultSwapPool(Currency currencyIn, Currency currencyOut, PoolKey memory poolKey)
        external
        onlyOwner
    {
        if (Currency.unwrap(currencyIn) == address(0)) revert InvalidInputCurrency();
        if (Currency.unwrap(currencyOut) == address(0)) revert InvalidOutputCurrency();
        if (Currency.unwrap(currencyIn) == Currency.unwrap(currencyOut)) revert CurrenciesMustBeDifferent();
        if (poolKey.fee == 0) revert InvalidPoolKey();

        // Validate that the pool contains both currencies (order-agnostic)
        address c0 = Currency.unwrap(poolKey.currency0);
        address c1 = Currency.unwrap(poolKey.currency1);
        address cIn = Currency.unwrap(currencyIn);
        address cOut = Currency.unwrap(currencyOut);

        if (!((c0 == cIn && c1 == cOut) || (c0 == cOut && c1 == cIn))) {
            revert PoolCurrenciesDontMatch();
        }

        bytes32 key = _getSwapKey(currencyIn, currencyOut);
        PoolKey memory existingPool = defaultSwapPools[key];
        bool isUpdate = existingPool.fee != 0;

        defaultSwapPools[key] = poolKey;

        if (isUpdate) {
            emit DefaultSwapPoolUpdated(currencyIn, currencyOut, existingPool, poolKey);
        } else {
            emit DefaultSwapPoolRegistered(currencyIn, currencyOut, poolKey);
        }
    }

    /// @notice Remove a default swap pool for a currency pair
    /// @param currencyIn The input currency
    /// @param currencyOut The output currency
    function removeDefaultSwapPool(Currency currencyIn, Currency currencyOut) external onlyOwner {
        bytes32 key = _getSwapKey(currencyIn, currencyOut);
        if (defaultSwapPools[key].fee == 0) revert PoolNotRegistered();

        delete defaultSwapPools[key];

        emit DefaultSwapPoolRemoved(currencyIn, currencyOut);
    }

    // ============ View Functions ============

    /// @notice Get the default swap pool for a currency pair
    /// @param currencyIn The input currency
    /// @param currencyOut The output currency
    /// @return The PoolKey to use for swaps (reverts if not registered)
    function getDefaultSwapPool(Currency currencyIn, Currency currencyOut) external view returns (PoolKey memory) {
        bytes32 key = _getSwapKey(currencyIn, currencyOut);
        PoolKey memory pool = defaultSwapPools[key];
        if (pool.fee == 0) revert NoDefaultPoolRegistered();
        return pool;
    }

    /// @notice Check if a default swap pool exists for a currency pair
    /// @param currencyIn The input currency
    /// @param currencyOut The output currency
    /// @return True if a default pool is registered
    function hasDefaultSwapPool(Currency currencyIn, Currency currencyOut) external view returns (bool) {
        bytes32 key = _getSwapKey(currencyIn, currencyOut);
        return defaultSwapPools[key].fee != 0;
    }

    // ============ Internal ============

    /// @notice Generate unique key for a directional currency pair
    function _getSwapKey(Currency currencyIn, Currency currencyOut) internal pure returns (bytes32) {
        return keccak256(abi.encode(currencyIn, currencyOut));
    }

    /// @notice Authorizes an upgrade to a new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============

    uint256[49] private __gap;
}
