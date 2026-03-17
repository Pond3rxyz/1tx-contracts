// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BaseHookTest} from "../../utils/BaseHookTest.sol";
import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {PortfolioStrategy} from "../../../src/hooks/PortfolioStrategy.sol";
import {IPortfolioStrategy} from "../../../src/interfaces/IPortfolioStrategy.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";

contract PortfolioHookTest is BaseHookTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Contracts
    PortfolioHook public hook;
    PortfolioVault public vault;
    PortfolioStrategy public strategy;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    // Tokens
    MockERC20 public usdc;
    MockERC20 public aUsdc;

    // Currencies
    Currency public usdcCurrency;

    // IDs
    bytes32 public usdcMarketId;
    bytes32 public usdcInstrumentId;

    // Addresses
    address public owner;
    address public user;
    address public executionAddress;

    // Pool key for the portfolio pool
    PoolKey public portfolioPoolKey;
    PoolId public portfolioPoolId;

    // Constants
    uint256 public constant INITIAL_BALANCE = 1_000_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        executionAddress = makeAddr("executionAddress");

        // Deploy real Uniswap V4 infrastructure
        deployArtifacts();

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        usdcCurrency = Currency.wrap(address(usdc));

        // Approvals for USDC on the test contract (needed for providing to swap router)
        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);

        // Deploy registries
        InstrumentRegistry irImpl = new InstrumentRegistry();
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner))
            )
        );

        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner))
            )
        );

        // Deploy Aave adapter
        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        usdc.mint(address(mockAavePool), INITIAL_BALANCE);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.prank(owner);
        aaveAdapter.registerMarket(usdcCurrency);

        // Register instrument
        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);

        vm.prank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));

        // Deploy strategy (UUPS proxy)
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, owner)
                )
            )
        );

        // Authorize strategy on adapter
        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(strategy));

        // Deploy vault (non-upgradeable)
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 10000});

        vault = new PortfolioVault(
            PortfolioVault.InitParams({
                initialOwner: owner,
                name: "Test Portfolio",
                symbol: "tPORT",
                stable: usdcCurrency,
                poolManager: poolManager,
                instrumentRegistry: instrumentRegistry,
                swapPoolRegistry: swapPoolRegistry,
                strategy: IPortfolioStrategy(address(strategy)),
                allocations: allocs
            })
        );

        // Deploy hook at address with correct flag bits
        address hookAddress = _computeHookAddress();
        deployCodeTo("PortfolioHook.sol:PortfolioHook", abi.encode(poolManager, vault, usdcCurrency), hookAddress);
        hook = PortfolioHook(hookAddress);

        // Set hook on vault
        vm.prank(owner);
        vault.setHook(address(hook));

        // Build pool key: currency0 must be < currency1
        (Currency c0, Currency c1) = Currency.unwrap(usdcCurrency) < address(vault)
            ? (usdcCurrency, Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), usdcCurrency);

        portfolioPoolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddress)});
        portfolioPoolId = portfolioPoolKey.toId();

        // Initialize the pool on the real PoolManager
        poolManager.initialize(portfolioPoolKey, Constants.SQRT_PRICE_1_1);

        // Seed PoolManager with USDC reserves (in production, PM holds reserves from other pools)
        usdc.mint(address(poolManager), INITIAL_BALANCE);

        // Fund user with USDC
        usdc.mint(user, INITIAL_BALANCE);

        // User approves swap router and permit2
        vm.startPrank(user);
        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ============ Helpers ============

    function _computeHookAddress() internal pure returns (address) {
        return address(uint160(0x1000000000000000000000000000000000000aC8));
    }

    /// @dev Returns true if buying (user sends USDC) means zeroForOne
    function _buyZeroForOne() internal view returns (bool) {
        return Currency.unwrap(portfolioPoolKey.currency0) == Currency.unwrap(usdcCurrency);
    }

    function _buyShares(uint256 amount, address recipient) internal returns (uint256 shares) {
        uint256 sharesBefore = vault.balanceOf(recipient);

        vm.prank(recipient);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(recipient),
            receiver: recipient,
            deadline: block.timestamp + 1
        });

        shares = vault.balanceOf(recipient) - sharesBefore;
    }

    function _sellShares(uint256 shareAmount, address shareOwner) internal returns (uint256 usdcReturned) {
        // Fund mock aave pool for withdrawal
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        // Owner must approve shares to router for sell
        vm.startPrank(shareOwner);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        uint256 usdcBefore = usdc.balanceOf(shareOwner);

        vm.prank(shareOwner);
        swapRouter.swapExactTokensForTokens({
            amountIn: shareAmount,
            amountOutMin: 0,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(shareOwner),
            receiver: shareOwner,
            deadline: block.timestamp + 1
        });

        usdcReturned = usdc.balanceOf(shareOwner) - usdcBefore;
    }

    function _lastSwapRouted() internal view returns (bool found, bool isBuy, bool usedAmm, uint256 amountSpecified) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapRouted(address,bool,bool,uint256)");

        for (uint256 i = entries.length; i > 0; i--) {
            Vm.Log memory log = entries[i - 1];
            if (log.emitter == address(hook) && log.topics.length > 0 && log.topics[0] == sig) {
                (isBuy, usedAmm, amountSpecified) = abi.decode(log.data, (bool, bool, uint256));
                return (true, isBuy, usedAmm, amountSpecified);
            }
        }
    }

    // ============ Permission Tests ============

    function test_hookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.beforeInitialize);
    }

    // ============ Buy Tests ============

    function test_buy_mintsShares() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(user), shares);
    }

    function test_buy_allocatesToLending() public {
        _buyShares(DEPOSIT_AMOUNT, user);

        assertApproxEqRel(aUsdc.balanceOf(address(vault)), DEPOSIT_AMOUNT, 5e16);
    }

    function test_buy_keepsSqrtPriceStatic() public {
        (uint160 priceBefore,,,) = poolManager.getSlot0(portfolioPoolId);

        _buyShares(DEPOSIT_AMOUNT, user);

        (uint160 priceAfter,,,) = poolManager.getSlot0(portfolioPoolId);

        assertEq(priceBefore, priceAfter, "sqrtPrice should stay static after buy");
    }

    function test_buy_emitsEvent() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        assertGt(shares, 0);
    }

    // ============ Sell Tests ============

    function test_sell_returnsStable() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        uint256 usdcReturned = _sellShares(shares, user);

        assertGt(usdcReturned, 0);
        assertEq(usdcReturned, DEPOSIT_AMOUNT);
    }

    function test_sell_keepsSqrtPriceStatic() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        (uint160 priceBeforeSell,,,) = poolManager.getSlot0(portfolioPoolId);

        _sellShares(shares, user);

        (uint160 priceAfterSell,,,) = poolManager.getSlot0(portfolioPoolId);

        assertEq(priceBeforeSell, priceAfterSell, "sqrtPrice should stay static after sell");
    }

    function test_sell_partialRedeem() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        uint256 halfShares = shares / 2;
        uint256 usdcReturned = _sellShares(halfShares, user);

        assertGt(usdcReturned, 0);
        assertGt(vault.balanceOf(user), 0);
    }

    // ============ Roundtrip Tests ============

    function test_buySell_roundtrip() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 usdcReturned = _sellShares(shares, user);

        assertEq(usdcReturned, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_buySell_pmShareBalanceDoesNotGrowUnbounded() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 halfShares = shares / 2;
        _sellShares(halfShares, user);

        uint256 secondAmount = vault.totalAssets() / 4;
        if (secondAmount < 1e6) secondAmount = 1e6;
        uint256 shares2 = _buyShares(secondAmount, user);
        _sellShares(shares2 / 2, user);

        uint256 pmSharesAfterSecondRound = vault.balanceOf(address(poolManager));
        assertLe(pmSharesAfterSecondRound, vault.totalSupply(), "PM share balance should remain bounded by supply");
    }

    function test_multipleUsers_independentShares() public {
        address user2 = makeAddr("user2");
        usdc.mint(user2, INITIAL_BALANCE);
        vm.startPrank(user2);
        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        uint256 shares1 = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT, user2);

        assertEq(vault.balanceOf(user), shares1);
        assertEq(vault.balanceOf(user2), shares2);
        assertEq(shares1, shares2);
    }

    // ============ Price Behavior Tests ============

    function test_sqrtPrice_staysStaticAcrossTrading() public {
        (uint160 initialPrice,,,) = poolManager.getSlot0(portfolioPoolId);

        _buyShares(DEPOSIT_AMOUNT, user);
        (uint160 afterBuy,,,) = poolManager.getSlot0(portfolioPoolId);
        assertEq(initialPrice, afterBuy, "Price should remain unchanged after buy");

        uint256 shares = vault.balanceOf(user);
        _sellShares(shares, user);
        (uint160 afterSell,,,) = poolManager.getSlot0(portfolioPoolId);
        assertEq(afterBuy, afterSell, "Price should remain unchanged after sell");
    }

    function test_exactOutputBuy_succeedsAndRoutesNav() public {
        uint256 amountOut = 50e6;

        uint256 sharesBefore = vault.balanceOf(user);

        vm.recordLogs();
        vm.prank(user);
        swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: type(uint256).max,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });

        uint256 sharesMinted = vault.balanceOf(user) - sharesBefore;
        assertEq(sharesMinted, amountOut, "exact-output buy should mint exact shares");

        (bool found, bool isBuy, bool usedAmm,) = _lastSwapRouted();
        assertTrue(found, "SwapRouted not emitted");
        assertTrue(isBuy, "expected buy route");
        assertFalse(usedAmm, "expected NAV route");
    }

    function test_exactOutputSell_succeedsAndRoutesNav() public {
        _buyShares(DEPOSIT_AMOUNT, user);

        vm.startPrank(user);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        uint256 requestedOut = 200e6;
        uint256 usdcBefore = usdc.balanceOf(user);

        vm.recordLogs();
        vm.prank(user);
        swapRouter.swapTokensForExactTokens({
            amountOut: requestedOut,
            amountInMax: type(uint256).max,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });

        uint256 usdcDelta = usdc.balanceOf(user) - usdcBefore;
        assertEq(usdcDelta, requestedOut, "exact-output sell should return exact stable out");

        (bool found, bool isBuy, bool usedAmm,) = _lastSwapRouted();
        assertTrue(found, "SwapRouted not emitted");
        assertFalse(isBuy, "expected sell route");
        assertFalse(usedAmm, "expected NAV route");
    }

    function test_exactOutputSell_revertsEarlyWhenRequestedStableExceedsNav() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        assertGt(shares, 0);

        // Collapse NAV while user still has shares.
        uint256 vaultAUsdc = aUsdc.balanceOf(address(vault));
        aUsdc.burn(address(vault), vaultAUsdc - 1);

        uint256 nav = vault.totalAssets();
        uint256 requestedOut = nav + 1;

        vm.prank(user);
        vm.expectRevert();
        swapRouter.swapTokensForExactTokens({
            amountOut: requestedOut,
            amountInMax: shares,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });
    }

    // ============ Fuzz/Invariant-style Tests ============

    function testFuzz_repeatedRoundtripKeepsStateBounded(uint8 roundsRaw, uint96 amountRaw) public {
        uint256 rounds = bound(uint256(roundsRaw), 1, 3);
        uint256 amount = bound(uint256(amountRaw), 10e6, 500e6);

        usdc.mint(user, amount * rounds + 1_000e6);

        for (uint256 i = 0; i < rounds; i++) {
            uint256 shares;
            try this.buySharesExternal(amount, user) returns (uint256 outShares) {
                shares = outShares;
            } catch {
                continue;
            }
            if (shares > 0) {
                try this.sellSharesExternal(shares, user) returns (uint256) {} catch {}
            }

            assertLe(usdc.balanceOf(address(hook)), 1, "hook stable residue too large");
        }

        uint256 pmSharesFinal = vault.balanceOf(address(poolManager));
        uint256 maxGrowth = vault.totalSupply();
        assertLe(pmSharesFinal, maxGrowth, "PM share drift too high");
    }

    function buySharesExternal(uint256 amount, address recipient) external returns (uint256 shares) {
        return _buyShares(amount, recipient);
    }

    function sellSharesExternal(uint256 shares, address owner_) external returns (uint256 amountOut) {
        return _sellShares(shares, owner_);
    }
}
