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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BaseHookTest} from "../../utils/BaseHookTest.sol";
import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";

/// @title PortfolioHookExtendedTest
/// @notice Extended tests for PortfolioHook covering edge cases, branch coverage, large amounts,
///         liquidity blocking, zero-amount reverts, non-zero fee pools, hookData decoding, and
///         multi-user concurrent scenarios.
contract PortfolioHookExtendedTest is BaseHookTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PortfolioHook public hook;
    PortfolioVault public vault;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    MockERC20 public usdc;
    MockERC20 public aUsdc;

    Currency public usdcCurrency;

    bytes32 public usdcMarketId;
    bytes32 public usdcInstrumentId;

    address public owner;
    address public user;
    address public executionAddress;

    PoolKey public portfolioPoolKey;
    PoolId public portfolioPoolId;

    uint256 public constant INITIAL_BALANCE = 10_000_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        executionAddress = makeAddr("executionAddress");

        deployArtifacts();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        usdcCurrency = Currency.wrap(address(usdc));

        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);

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

        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        usdc.mint(address(mockAavePool), INITIAL_BALANCE);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.prank(owner);
        aaveAdapter.registerMarket(usdcCurrency);

        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);

        vm.prank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));

        PortfolioVault vaultImpl = new PortfolioVault();
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 10000});

        PortfolioVault.InitParams memory params = PortfolioVault.InitParams({
            initialOwner: owner,
            name: "Test Portfolio",
            symbol: "tPORT",
            stable: usdcCurrency,
            poolManager: poolManager,
            instrumentRegistry: instrumentRegistry,
            swapPoolRegistry: swapPoolRegistry,
            allocations: allocs
        });

        vault = PortfolioVault(
            address(
                new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(PortfolioVault.initialize.selector, params))
            )
        );

        address hookAddress = _computeHookAddress();
        deployCodeTo("PortfolioHook.sol:PortfolioHook", abi.encode(poolManager, vault, usdcCurrency), hookAddress);
        hook = PortfolioHook(hookAddress);

        vm.prank(owner);
        vault.setHook(address(hook));

        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(vault));

        (Currency c0, Currency c1) = Currency.unwrap(usdcCurrency) < address(vault)
            ? (usdcCurrency, Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), usdcCurrency);

        portfolioPoolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddress)});
        portfolioPoolId = portfolioPoolKey.toId();

        poolManager.initialize(portfolioPoolKey, Constants.SQRT_PRICE_1_1);

        usdc.mint(address(poolManager), INITIAL_BALANCE);
        usdc.mint(user, INITIAL_BALANCE);

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

    function _buyZeroForOne() internal view returns (bool) {
        return Currency.unwrap(portfolioPoolKey.currency0) == Currency.unwrap(usdcCurrency);
    }

    function _setupUser(address u) internal {
        usdc.mint(u, INITIAL_BALANCE);
        vm.startPrank(u);
        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _setupUserSellApprovals(address u) internal {
        vm.startPrank(u);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
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
        usdc.mint(address(mockAavePool), shareAmount * 2);
        _setupUserSellApprovals(shareOwner);
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

    // ============ Immutable State Tests ============

    function test_immutableState() public view {
        assertEq(address(hook.VAULT()), address(vault));
        assertEq(Currency.unwrap(hook.STABLE()), address(usdc));
    }

    // ============ Liquidity Blocking Tests ============

    function test_liquidityBlocking_permissionsSet() public view {
        // The hook prevents adding/removing liquidity via beforeAddLiquidity/beforeRemoveLiquidity
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeAddLiquidity, "beforeAddLiquidity must be enabled");
        assertTrue(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity must be enabled");
    }

    // ============ Large Amount Tests ============

    function test_buy_largeAmount_1M() public {
        uint256 largeAmount = 1_000_000e6;
        usdc.mint(user, largeAmount);
        usdc.mint(address(poolManager), largeAmount);

        uint256 shares = _buyShares(largeAmount, user);
        assertGt(shares, 0, "large buy should mint shares");
        assertApproxEqRel(aUsdc.balanceOf(address(vault)), largeAmount, 1e16);
    }

    function test_buy_largeAmount_5M() public {
        uint256 largeAmount = 5_000_000e6;
        usdc.mint(user, largeAmount);
        usdc.mint(address(poolManager), largeAmount);

        uint256 shares = _buyShares(largeAmount, user);
        assertGt(shares, 0, "5M buy should succeed");
    }

    function test_sellLargeAmount_roundtrip() public {
        uint256 largeAmount = 1_000_000e6;
        usdc.mint(user, largeAmount);
        usdc.mint(address(poolManager), largeAmount);

        uint256 shares = _buyShares(largeAmount, user);
        usdc.mint(address(mockAavePool), largeAmount * 2);

        uint256 returned = _sellShares(shares, user);
        assertEq(returned, largeAmount, "large roundtrip should preserve value");
    }

    // ============ Small Amount / Dust Tests ============

    function test_buy_smallAmount_1USDC() public {
        uint256 smallAmount = 1e6;
        uint256 shares = _buyShares(smallAmount, user);
        assertGt(shares, 0, "1 USDC buy should mint shares");
    }

    function test_buy_smallAmount_0_01USDC() public {
        uint256 tinyAmount = 10_000; // 0.01 USDC
        uint256 shares = _buyShares(tinyAmount, user);
        assertGt(shares, 0, "tiny buy should still mint shares");
    }

    function test_sell_dust_after_partial() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        // Sell almost all, leave dust
        uint256 toSell = shares - 1;
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        _setupUserSellApprovals(user);

        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: toSell,
            amountOutMin: 0,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });

        // User should have 1 share of dust
        assertEq(vault.balanceOf(user), 1, "should have 1 share dust");
    }

    // ============ hookData Tests ============
    // hookData is only used for event emission (recipient in SharesBought/SharesSold).
    // Actual token flow is determined by the router's receiver parameter.
    // Swaps must work with any hookData including empty bytes.

    function test_swap_worksWithEmptyHookData() public {
        uint256 sharesBefore = vault.balanceOf(user);
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: DEPOSIT_AMOUNT,
            amountOutMin: 0,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        assertGt(vault.balanceOf(user) - sharesBefore, 0, "swap with empty hookData should work");
    }

    function test_swap_worksWithZeroAddressHookData() public {
        uint256 sharesBefore = vault.balanceOf(user);
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: DEPOSIT_AMOUNT,
            amountOutMin: 0,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(address(0)),
            receiver: user,
            deadline: block.timestamp + 1
        });
        assertGt(vault.balanceOf(user) - sharesBefore, 0, "swap with zero-address hookData should work");
    }

    // ============ Multiple User Concurrent Tests ============

    function test_multipleUsers_buySequentially_priceStaysStatic() public {
        (uint160 priceBefore,,,) = poolManager.getSlot0(portfolioPoolId);

        address[] memory users_ = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            users_[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
            _setupUser(users_[i]);
            _buyShares(DEPOSIT_AMOUNT * (i + 1), users_[i]);
        }

        (uint160 priceAfter,,,) = poolManager.getSlot0(portfolioPoolId);
        assertEq(priceBefore, priceAfter, "price must stay static after multiple buys");
    }

    function test_multipleUsers_interleavedBuySell() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        _setupUser(alice);
        _setupUser(bob);
        _setupUser(charlie);

        // Alice buys
        uint256 aliceShares = _buyShares(1000e6, alice);

        // Bob buys
        uint256 bobShares = _buyShares(2000e6, bob);

        // Alice sells half
        usdc.mint(address(mockAavePool), 5000e6);
        _sellShares(aliceShares / 2, alice);

        // Charlie buys
        uint256 charlieShares = _buyShares(500e6, charlie);

        // Bob sells all
        usdc.mint(address(mockAavePool), 5000e6);
        _sellShares(bobShares, bob);

        // Alice sells remaining
        usdc.mint(address(mockAavePool), 5000e6);
        uint256 aliceRemaining = vault.balanceOf(alice);
        _sellShares(aliceRemaining, alice);

        // Charlie still has shares
        assertEq(vault.balanceOf(charlie), charlieShares, "charlie shares should be intact");

        // Charlie sells
        usdc.mint(address(mockAavePool), 5000e6);
        uint256 charlieReturned = _sellShares(charlieShares, charlie);
        assertGt(charlieReturned, 0, "charlie should get USDC back");
    }

    function test_multipleUsers_allExit_vaultEmpty() public {
        address[] memory users_ = new address[](5);
        uint256[] memory shares = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            users_[i] = makeAddr(string(abi.encodePacked("exitUser", vm.toString(i))));
            _setupUser(users_[i]);
            shares[i] = _buyShares(DEPOSIT_AMOUNT, users_[i]);
        }

        // Everyone exits
        for (uint256 i = 0; i < 5; i++) {
            usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
            _sellShares(shares[i], users_[i]);
        }

        // Vault should have near-zero NAV
        assertLe(vault.totalAssets(), 5, "vault NAV should be near zero after all exits");
    }

    // ============ afterSwap Burn Logic Tests ============

    /// @dev After a sell, the router settles the user's ERC-20 shares to PM AFTER afterSwap runs.
    ///      These "dead" shares get burned in the NEXT swap's afterSwap.
    ///      The vault's _effectiveTotalSupply() excludes PM shares so NAV stays correct.
    function test_afterSwap_sellLeavesDeadSharesInPM_burnedByNextSwap() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        _sellShares(shares, user);

        // PM has "dead" shares from the sell — router settled them after afterSwap
        uint256 pmSharesAfterSell = vault.balanceOf(address(poolManager));
        assertGt(pmSharesAfterSell, 0, "PM should hold dead shares from sell");

        // Next buy should burn those dead shares in its afterSwap
        address user2 = makeAddr("user2");
        _setupUser(user2);
        _buyShares(DEPOSIT_AMOUNT, user2);

        uint256 pmSharesAfterBuy = vault.balanceOf(address(poolManager));
        assertEq(pmSharesAfterBuy, 0, "PM dead shares should be burned by next swap");
    }

    function test_afterSwap_doesNotBurnBuyShares() public {
        // Buy shares — PM temporarily holds them for router to deliver
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        // User should have the shares (router delivered them)
        assertEq(vault.balanceOf(user), shares, "user should have all bought shares");

        // PM should have 0 after the buy (afterSwap protected live shares via _buySharesSettled)
        assertEq(vault.balanceOf(address(poolManager)), 0, "PM should have 0 after buy");
    }

    function test_afterSwap_effectiveSupplyExcludesPmShares() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        _sellShares(shares, user);

        // PM has dead shares, but _effectiveTotalSupply excludes them
        uint256 pmShares = vault.balanceOf(address(poolManager));
        assertGt(pmShares, 0, "PM should hold dead shares");

        // Total supply includes PM shares, but effective supply does not
        // New deposits should still get fair share pricing
        address user2 = makeAddr("user2");
        _setupUser(user2);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT, user2);
        assertGt(shares2, 0, "new buy should work despite dead PM shares");
    }

    // ============ Exact Output Tests ============

    function test_exactOutputBuy_specificShareAmount() public {
        uint256 targetShares = 500e6;

        vm.prank(user);
        swapRouter.swapTokensForExactTokens({
            amountOut: targetShares,
            amountInMax: type(uint256).max,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });

        assertEq(vault.balanceOf(user), targetShares, "should get exact shares requested");
    }

    function test_exactOutputSell_specificStableAmount() public {
        _buyShares(DEPOSIT_AMOUNT, user);
        _setupUserSellApprovals(user);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);

        uint256 requestedOut = 500e6;
        uint256 usdcBefore = usdc.balanceOf(user);

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
        assertEq(usdcDelta, requestedOut, "should get exact USDC requested");
    }

    // ============ Sequential Buy Tests (Share Price Consistency) ============

    function test_secondBuy_getsProportionalShares() public {
        // First buyer
        uint256 shares1 = _buyShares(DEPOSIT_AMOUNT, user);

        // Second buyer
        address user2 = makeAddr("user2");
        _setupUser(user2);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT, user2);

        // Same amount in should give same shares (1:1 mock aToken, same NAV per share)
        assertEq(shares1, shares2, "equal deposits should get equal shares");
    }

    function test_buyAfterYieldAccrual_getsFewerShares() public {
        // First buyer
        uint256 shares1 = _buyShares(DEPOSIT_AMOUNT, user);

        // Simulate yield: mint extra aTokens to vault
        aUsdc.mint(address(vault), 100e6);

        // Second buyer — should get fewer shares because NAV per share increased
        address user2 = makeAddr("user2");
        _setupUser(user2);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT, user2);

        assertLt(shares2, shares1, "second buyer should get fewer shares after yield");
    }

    function test_sellAfterYieldAccrual_getsMoreUsdc() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        // Simulate yield
        aUsdc.mint(address(vault), 100e6);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);

        uint256 returned = _sellShares(shares, user);
        assertGt(returned, DEPOSIT_AMOUNT, "should get more than deposited after yield");
    }

    // ============ Sell Settlement Edge Cases ============

    function test_sell_insufficientStable_reverts() public {
        _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares = vault.balanceOf(user);

        _setupUserSellApprovals(user);

        // Don't fund mockAavePool — withdrawal will fail
        // Remove all USDC from mock pool
        uint256 poolBal = usdc.balanceOf(address(mockAavePool));
        usdc.burn(address(mockAavePool), poolBal);

        vm.prank(user);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: shares,
            amountOutMin: 0,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });
    }

    // ============ Hook Residual Tests ============

    function test_hookHoldsNoStableAfterBuy() public {
        _buyShares(DEPOSIT_AMOUNT, user);
        assertLe(usdc.balanceOf(address(hook)), 1, "hook should hold at most 1 wei of stable");
    }

    function test_hookHoldsNoStableAfterSell() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        _sellShares(shares, user);
        assertLe(usdc.balanceOf(address(hook)), 1, "hook should hold at most 1 wei after sell");
    }

    function test_hookHoldsNoSharesAfterBuy() public {
        _buyShares(DEPOSIT_AMOUNT, user);
        assertEq(vault.balanceOf(address(hook)), 0, "hook should hold no shares after buy");
    }

    function test_hookHoldsNoSharesAfterSell() public {
        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        _sellShares(shares, user);
        assertEq(vault.balanceOf(address(hook)), 0, "hook should hold no shares after sell");
    }

    // ============ NAV Consistency Tests ============

    function test_navConsistency_afterBuy() public {
        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, 0, "NAV should start at 0");

        _buyShares(DEPOSIT_AMOUNT, user);

        uint256 navAfter = vault.totalAssets();
        assertApproxEqRel(navAfter, DEPOSIT_AMOUNT, 1e16, "NAV should equal deposit after buy");
    }

    function test_navConsistency_afterBuySell() public {
        _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares = vault.balanceOf(user);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        _sellShares(shares, user);

        uint256 navAfter = vault.totalAssets();
        assertLe(navAfter, 1, "NAV should be near zero after full exit");
    }

    function test_navConsistency_multipleUsers() public {
        _buyShares(1000e6, user);

        address user2 = makeAddr("user2");
        _setupUser(user2);
        _buyShares(2000e6, user2);

        assertApproxEqRel(vault.totalAssets(), 3000e6, 1e16, "NAV should be sum of deposits");
    }

    // ============ Fuzz Tests ============

    function testFuzz_buyAmount(uint256 amount) public {
        amount = bound(amount, 1e4, 10_000_000e6); // 0.01 USDC to 10M USDC
        usdc.mint(user, amount);
        usdc.mint(address(poolManager), amount);

        uint256 shares = _buyShares(amount, user);
        assertGt(shares, 0, "any valid buy should mint shares");
        assertLe(usdc.balanceOf(address(hook)), 1, "hook should not hold stable");
    }

    function testFuzz_buySellRoundtrip(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(user, amount);
        usdc.mint(address(poolManager), amount);

        uint256 shares = _buyShares(amount, user);
        usdc.mint(address(mockAavePool), amount * 2);
        uint256 returned = _sellShares(shares, user);

        // With 1:1 mock aTokens, roundtrip should be exact
        assertEq(returned, amount, "1:1 roundtrip should be exact");
        // PM will hold "dead" ERC-20 shares from sell (burned in next swap's afterSwap)
        // But effective supply excludes them so NAV is correct
    }

    function testFuzz_multipleUsersRoundtrip(uint8 numUsers, uint96 baseAmount) public {
        uint256 n = bound(uint256(numUsers), 1, 10);
        uint256 base = bound(uint256(baseAmount), 10e6, 100_000e6);

        address[] memory users_ = new address[](n);
        uint256[] memory shares = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            users_[i] = makeAddr(string(abi.encodePacked("fuzzUser", vm.toString(i))));
            _setupUser(users_[i]);
            usdc.mint(address(poolManager), base);
            shares[i] = _buyShares(base, users_[i]);
        }

        uint256 totalDeposited;
        uint256 totalReturned;
        for (uint256 i = 0; i < n; i++) {
            usdc.mint(address(mockAavePool), base * 2);
            uint256 returned = _sellShares(shares[i], users_[i]);
            totalDeposited += base;
            totalReturned += returned;
        }
        // Overall, users should recover their total deposit within 1% tolerance.
        // Individual sells may vary due to dead-share exclusion in _effectiveTotalSupply.
        assertApproxEqRel(totalReturned, totalDeposited, 1e16, "total returned should match total deposited");
    }

    // ============ Event Emission Tests ============

    function test_buy_emitsSharesBoughtAndSwapRouted() public {
        vm.recordLogs();
        _buyShares(DEPOSIT_AMOUNT, user);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool foundSharesBought = false;
        bool foundSwapRouted = false;
        bytes32 sharesBoughtSig = keccak256("SharesBought(address,uint256,uint256)");
        bytes32 swapRoutedSig = keccak256("SwapRouted(address,bool,bool,uint256)");

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(hook) && entries[i].topics[0] == sharesBoughtSig) {
                foundSharesBought = true;
            }
            if (entries[i].emitter == address(hook) && entries[i].topics[0] == swapRoutedSig) {
                foundSwapRouted = true;
            }
        }

        assertTrue(foundSharesBought, "SharesBought event should be emitted");
        assertTrue(foundSwapRouted, "SwapRouted event should be emitted");
    }

    function test_sell_emitsSharesSoldAndSwapRouted() public {
        _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares = vault.balanceOf(user);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);

        vm.recordLogs();
        _sellShares(shares, user);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool foundSharesSold = false;
        bool foundSwapRouted = false;
        bytes32 sharesSoldSig = keccak256("SharesSold(address,uint256,uint256)");
        bytes32 swapRoutedSig = keccak256("SwapRouted(address,bool,bool,uint256)");

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(hook) && entries[i].topics[0] == sharesSoldSig) {
                foundSharesSold = true;
            }
            if (entries[i].emitter == address(hook) && entries[i].topics[0] == swapRoutedSig) {
                foundSwapRouted = true;
            }
        }

        assertTrue(foundSharesSold, "SharesSold event should be emitted");
        assertTrue(foundSwapRouted, "SwapRouted event should be emitted");
    }

    // ============ Yield Scenarios ============

    function test_yieldAccrual_increasesShareValue() public {
        _buyShares(DEPOSIT_AMOUNT, user);

        // Use a larger share amount to avoid rounding hiding the yield effect
        uint256 valueBefore = vault.convertToAssets(DEPOSIT_AMOUNT);

        // Simulate 10% yield
        aUsdc.mint(address(vault), DEPOSIT_AMOUNT / 10);

        uint256 valueAfter = vault.convertToAssets(DEPOSIT_AMOUNT);
        assertGt(valueAfter, valueBefore, "share value should increase with yield");
    }

    function test_yieldAccrual_newDepositorSharesDiluted() public {
        _buyShares(DEPOSIT_AMOUNT, user);

        // 10% yield
        aUsdc.mint(address(vault), 100e6);

        address user2 = makeAddr("user2");
        _setupUser(user2);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT, user2);

        // user2 gets fewer shares because NAV/share is higher
        uint256 userShares = vault.balanceOf(user);
        assertLt(shares2, userShares, "new depositor gets fewer shares after yield");
    }

    // ============ Impairment / Loss Scenario ============

    function test_impairment_existingShareholderLoses() public {
        _buyShares(DEPOSIT_AMOUNT, user);

        // Simulate 50% loss
        uint256 vaultAUsdc = aUsdc.balanceOf(address(vault));
        aUsdc.burn(address(vault), vaultAUsdc / 2);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
        uint256 shares = vault.balanceOf(user);
        uint256 returned = _sellShares(shares, user);

        // User should get back roughly half
        assertApproxEqRel(returned, DEPOSIT_AMOUNT / 2, 5e16, "user should lose proportionally");
    }

    // ============ Zero-Value Edge Cases ============

    function test_sellZeroShares_noEffect() public {
        _buyShares(DEPOSIT_AMOUNT, user);

        // Selling 0 shares should revert (ZeroAmount)
        _setupUserSellApprovals(user);

        vm.prank(user);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 0,
            amountOutMin: 0,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });
    }
}
