// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract SwapPoolRegistryTest is Test {
    using CurrencyLibrary for Currency;

    SwapPoolRegistry public registry;

    MockERC20 public usdc;
    MockERC20 public usdt;

    Currency public usdcCurrency;
    Currency public usdtCurrency;

    address public owner;
    address public user;

    PoolKey public validPoolKey;

    event DefaultSwapPoolRegistered(Currency indexed currencyIn, Currency indexed currencyOut, PoolKey poolKey);
    event DefaultSwapPoolUpdated(
        Currency indexed currencyIn, Currency indexed currencyOut, PoolKey oldPoolKey, PoolKey newPoolKey
    );
    event DefaultSwapPoolRemoved(Currency indexed currencyIn, Currency indexed currencyOut);

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        usdcCurrency = Currency.wrap(address(usdc));
        usdtCurrency = Currency.wrap(address(usdt));

        // Ensure proper currency ordering for PoolKey (currency0 < currency1)
        Currency currency0;
        Currency currency1;
        if (Currency.unwrap(usdcCurrency) < Currency.unwrap(usdtCurrency)) {
            currency0 = usdcCurrency;
            currency1 = usdtCurrency;
        } else {
            currency0 = usdtCurrency;
            currency1 = usdcCurrency;
        }

        validPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        // Deploy registry via proxy
        SwapPoolRegistry impl = new SwapPoolRegistry();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner));
        registry = SwapPoolRegistry(address(proxy));
    }

    // ============ Initialize Tests ============

    function test_initialize_setsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        registry.initialize(user);
    }

    // ============ registerDefaultSwapPool Tests ============

    function test_registerDefaultSwapPool_success() public {
        vm.expectEmit(true, true, false, true);
        emit DefaultSwapPoolRegistered(usdcCurrency, usdtCurrency, validPoolKey);

        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
    }

    function test_registerDefaultSwapPool_storesCorrectPoolKey() public {
        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        PoolKey memory retrieved = registry.getDefaultSwapPool(usdcCurrency, usdtCurrency);
        assertEq(Currency.unwrap(retrieved.currency0), Currency.unwrap(validPoolKey.currency0));
        assertEq(Currency.unwrap(retrieved.currency1), Currency.unwrap(validPoolKey.currency1));
        assertEq(retrieved.fee, validPoolKey.fee);
        assertEq(retrieved.tickSpacing, validPoolKey.tickSpacing);
        assertEq(address(retrieved.hooks), address(validPoolKey.hooks));
    }

    function test_registerDefaultSwapPool_directional() public {
        // Register USDC→USDT
        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        // USDC→USDT should exist
        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));

        // USDT→USDC should NOT exist (directional)
        assertFalse(registry.hasDefaultSwapPool(usdtCurrency, usdcCurrency));
    }

    function test_registerDefaultSwapPool_bidirectionalRegistration() public {
        // Register both directions
        vm.startPrank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
        registry.registerDefaultSwapPool(usdtCurrency, usdcCurrency, validPoolKey);
        vm.stopPrank();

        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
        assertTrue(registry.hasDefaultSwapPool(usdtCurrency, usdcCurrency));
    }

    function test_registerDefaultSwapPool_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
    }

    function test_registerDefaultSwapPool_revertsOnZeroInputCurrency() public {
        Currency zeroCurrency = CurrencyLibrary.ADDRESS_ZERO;

        vm.prank(owner);
        vm.expectRevert(SwapPoolRegistry.InvalidInputCurrency.selector);
        registry.registerDefaultSwapPool(zeroCurrency, usdtCurrency, validPoolKey);
    }

    function test_registerDefaultSwapPool_revertsOnZeroOutputCurrency() public {
        Currency zeroCurrency = CurrencyLibrary.ADDRESS_ZERO;

        vm.prank(owner);
        vm.expectRevert(SwapPoolRegistry.InvalidOutputCurrency.selector);
        registry.registerDefaultSwapPool(usdcCurrency, zeroCurrency, validPoolKey);
    }

    function test_registerDefaultSwapPool_revertsOnSameCurrencies() public {
        vm.prank(owner);
        vm.expectRevert(SwapPoolRegistry.CurrenciesMustBeDifferent.selector);
        registry.registerDefaultSwapPool(usdcCurrency, usdcCurrency, validPoolKey);
    }

    function test_registerDefaultSwapPool_revertsOnZeroFee() public {
        PoolKey memory zeroFeePool = PoolKey({
            currency0: validPoolKey.currency0,
            currency1: validPoolKey.currency1,
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        vm.prank(owner);
        vm.expectRevert(SwapPoolRegistry.InvalidPoolKey.selector);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, zeroFeePool);
    }

    function test_registerDefaultSwapPool_revertsOnCurrencyMismatch() public {
        // Create a pool with different currencies than the pair
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        Currency daiCurrency = Currency.wrap(address(dai));

        Currency c0;
        Currency c1;
        if (Currency.unwrap(usdcCurrency) < Currency.unwrap(daiCurrency)) {
            c0 = usdcCurrency;
            c1 = daiCurrency;
        } else {
            c0 = daiCurrency;
            c1 = usdcCurrency;
        }

        PoolKey memory wrongPool = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        vm.prank(owner);
        vm.expectRevert(SwapPoolRegistry.PoolCurrenciesDontMatch.selector);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, wrongPool);
    }

    // ============ Update Tests ============

    function test_registerDefaultSwapPool_updatesExistingPool() public {
        // Register initial pool
        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        // Create updated pool with different fee
        PoolKey memory updatedPoolKey = PoolKey({
            currency0: validPoolKey.currency0,
            currency1: validPoolKey.currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectEmit(true, true, false, true);
        emit DefaultSwapPoolUpdated(usdcCurrency, usdtCurrency, validPoolKey, updatedPoolKey);

        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, updatedPoolKey);

        PoolKey memory retrieved = registry.getDefaultSwapPool(usdcCurrency, usdtCurrency);
        assertEq(retrieved.fee, 3000);
        assertEq(retrieved.tickSpacing, 60);
    }

    // ============ removeDefaultSwapPool Tests ============

    function test_removeDefaultSwapPool_success() public {
        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        vm.expectEmit(true, true, false, false);
        emit DefaultSwapPoolRemoved(usdcCurrency, usdtCurrency);

        vm.prank(owner);
        registry.removeDefaultSwapPool(usdcCurrency, usdtCurrency);

        assertFalse(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
    }

    function test_removeDefaultSwapPool_revertsOnNonOwner() public {
        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        registry.removeDefaultSwapPool(usdcCurrency, usdtCurrency);
    }

    function test_removeDefaultSwapPool_revertsIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(SwapPoolRegistry.PoolNotRegistered.selector);
        registry.removeDefaultSwapPool(usdcCurrency, usdtCurrency);
    }

    function test_removeDefaultSwapPool_doesNotAffectReverseDirection() public {
        // Register both directions
        vm.startPrank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
        registry.registerDefaultSwapPool(usdtCurrency, usdcCurrency, validPoolKey);

        // Remove only one direction
        registry.removeDefaultSwapPool(usdcCurrency, usdtCurrency);
        vm.stopPrank();

        assertFalse(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
        assertTrue(registry.hasDefaultSwapPool(usdtCurrency, usdcCurrency));
    }

    function test_removeDefaultSwapPool_canReRegisterAfterRemoval() public {
        vm.startPrank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
        registry.removeDefaultSwapPool(usdcCurrency, usdtCurrency);

        // Re-register should succeed and emit Registered (not Updated)
        vm.expectEmit(true, true, false, true);
        emit DefaultSwapPoolRegistered(usdcCurrency, usdtCurrency, validPoolKey);

        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
        vm.stopPrank();

        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
    }

    // ============ getDefaultSwapPool Tests ============

    function test_getDefaultSwapPool_revertsIfNotRegistered() public {
        vm.expectRevert(SwapPoolRegistry.NoDefaultPoolRegistered.selector);
        registry.getDefaultSwapPool(usdcCurrency, usdtCurrency);
    }

    function test_getDefaultSwapPool_revertsAfterRemoval() public {
        vm.startPrank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
        registry.removeDefaultSwapPool(usdcCurrency, usdtCurrency);
        vm.stopPrank();

        vm.expectRevert(SwapPoolRegistry.NoDefaultPoolRegistered.selector);
        registry.getDefaultSwapPool(usdcCurrency, usdtCurrency);
    }

    // ============ hasDefaultSwapPool Tests ============

    function test_hasDefaultSwapPool_returnsTrueWhenRegistered() public {
        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);

        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
    }

    function test_hasDefaultSwapPool_returnsFalseWhenNotRegistered() public view {
        assertFalse(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
    }

    // ============ Multiple Pools Tests ============

    function test_multiplePoolPairs() public {
        // Deploy a third token
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        Currency daiCurrency = Currency.wrap(address(dai));

        // Create USDC/DAI pool
        Currency c0;
        Currency c1;
        if (Currency.unwrap(usdcCurrency) < Currency.unwrap(daiCurrency)) {
            c0 = usdcCurrency;
            c1 = daiCurrency;
        } else {
            c0 = daiCurrency;
            c1 = usdcCurrency;
        }

        PoolKey memory usdcDaiPool = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        vm.startPrank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, validPoolKey);
        registry.registerDefaultSwapPool(usdcCurrency, daiCurrency, usdcDaiPool);
        vm.stopPrank();

        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, usdtCurrency));
        assertTrue(registry.hasDefaultSwapPool(usdcCurrency, daiCurrency));
        assertFalse(registry.hasDefaultSwapPool(usdtCurrency, daiCurrency));

        // Verify they return different pools
        PoolKey memory pool1 = registry.getDefaultSwapPool(usdcCurrency, usdtCurrency);
        PoolKey memory pool2 = registry.getDefaultSwapPool(usdcCurrency, daiCurrency);
        assertTrue(pool1.fee != pool2.fee || pool1.tickSpacing != pool2.tickSpacing);
    }

    // ============ Pool Key with Hook Tests ============

    function test_registerDefaultSwapPool_acceptsPoolWithHook() public {
        address hookAddr = makeAddr("hook");
        PoolKey memory poolWithHook = PoolKey({
            currency0: validPoolKey.currency0,
            currency1: validPoolKey.currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(hookAddr)
        });

        vm.prank(owner);
        registry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, poolWithHook);

        PoolKey memory retrieved = registry.getDefaultSwapPool(usdcCurrency, usdtCurrency);
        assertEq(address(retrieved.hooks), hookAddr);
    }
}
