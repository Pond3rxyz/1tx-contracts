// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {SwapDepositRouter} from "../../src/SwapDepositRouter.sol";
import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SwapDepositRouterTest is Test {
    using CurrencyLibrary for Currency;

    // Contracts
    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    MockPoolManager public mockPM;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    // Tokens
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20 public aUsdc;
    MockERC20 public aUsdt;

    // Currencies
    Currency public usdcCurrency;
    Currency public usdtCurrency;

    // IDs
    bytes32 public usdcMarketId;
    bytes32 public usdtMarketId;
    bytes32 public usdcInstrumentId;
    bytes32 public usdtInstrumentId;

    // Addresses
    address public owner;
    address public user;
    address public executionAddress;

    // Swap pool for USDC<>USDT
    PoolKey public swapPoolKey;

    // Constants
    uint256 public constant INITIAL_BALANCE = 1_000_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;

    // Events
    event Buy(bytes32 indexed instrumentId, address indexed sender, uint256 inputAmount, uint256 depositedAmount);
    event Sell(bytes32 indexed instrumentId, address indexed sender, uint256 yieldTokenAmount, uint256 outputAmount);

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        executionAddress = makeAddr("executionAddress");

        // Deploy tokens (ensure USDT address < USDC address for pool ordering, or handle dynamically)
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);

        usdcCurrency = Currency.wrap(address(usdc));
        usdtCurrency = Currency.wrap(address(usdt));

        // Deploy mock PoolManager
        mockPM = new MockPoolManager();

        // Deploy registries via proxies
        InstrumentRegistry irImpl = new InstrumentRegistry();
        ERC1967Proxy irProxy =
            new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner));
        instrumentRegistry = InstrumentRegistry(address(irProxy));

        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        ERC1967Proxy sprProxy =
            new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner));
        swapPoolRegistry = SwapPoolRegistry(address(sprProxy));

        // Deploy Aave adapter
        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        mockAavePool.setReserveData(address(usdt), address(aUsdt));
        usdc.mint(address(mockAavePool), INITIAL_BALANCE);
        usdt.mint(address(mockAavePool), INITIAL_BALANCE);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.startPrank(owner);
        aaveAdapter.registerMarket(usdcCurrency);
        aaveAdapter.registerMarket(usdtCurrency);
        vm.stopPrank();

        // Deploy router via proxy
        SwapDepositRouter routerImpl = new SwapDepositRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeWithSelector(
                SwapDepositRouter.initialize.selector,
                owner,
                IPoolManager(address(mockPM)),
                instrumentRegistry,
                swapPoolRegistry,
                usdcCurrency
            )
        );
        router = SwapDepositRouter(address(routerProxy));

        // Register adapter as authorized caller (for sell/withdraw)
        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(router));

        // Compute market IDs
        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdtMarketId = keccak256(abi.encode(usdtCurrency));

        // Register instruments
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        usdtInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdtMarketId);

        vm.startPrank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));
        instrumentRegistry.registerInstrument(executionAddress, usdtMarketId, address(aaveAdapter));
        vm.stopPrank();

        // Register swap pool for USDC<>USDT
        (Currency currency0, Currency currency1) = _orderCurrencies(usdcCurrency, usdtCurrency);
        swapPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        vm.startPrank(owner);
        swapPoolRegistry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, swapPoolKey);
        swapPoolRegistry.registerDefaultSwapPool(usdtCurrency, usdcCurrency, swapPoolKey);
        vm.stopPrank();

        // Fund mock PM with output tokens for swaps
        usdt.mint(address(mockPM), INITIAL_BALANCE);
        usdc.mint(address(mockPM), INITIAL_BALANCE);

        // Fund user
        usdc.mint(user, INITIAL_BALANCE);
        usdt.mint(user, INITIAL_BALANCE);
    }

    // ============ Helpers ============

    function _orderCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    // ============ Initialize Tests ============

    function test_initialize_setsOwner() public view {
        assertEq(router.owner(), owner);
    }

    function test_initialize_setsState() public view {
        assertEq(address(router.poolManager()), address(mockPM));
        assertEq(address(router.instrumentRegistry()), address(instrumentRegistry));
        assertEq(address(router.swapPoolRegistry()), address(swapPoolRegistry));
        assertEq(Currency.unwrap(router.stable()), address(usdc));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        router.initialize(
            user, IPoolManager(address(mockPM)), instrumentRegistry, swapPoolRegistry, usdcCurrency
        );
    }

    // ============ Buy Tests — No Swap (USDC market) ============

    function test_buy_noSwap_success() public {
        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);

        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(user), DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(user), INITIAL_BALANCE - DEPOSIT_AMOUNT);
    }

    function test_buy_noSwap_emitsEvent() public {
        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Buy(usdcInstrumentId, user, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
    }

    function test_buy_noSwap_multipleDeposits() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT * 3);

        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(aUsdc.balanceOf(user), DEPOSIT_AMOUNT * 3);
    }

    // ============ Buy Tests — With Swap (USDT market, pay USDC) ============

    function test_buy_withSwap_success() public {
        // Buy USDT instrument paying USDC → requires USDC→USDT swap
        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(usdtInstrumentId, DEPOSIT_AMOUNT);

        // Mock PM does 1:1 swap
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(aUsdt.balanceOf(user), DEPOSIT_AMOUNT);
    }

    function test_buy_withSwap_emitsEvent() public {
        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Buy(usdtInstrumentId, user, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(usdtInstrumentId, DEPOSIT_AMOUNT);
    }

    // ============ Buy Tests — Revert Cases ============

    function test_buy_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.InvalidAmount.selector);
        router.buy(usdcInstrumentId, 0);
    }

    function test_buy_revertsOnUnregisteredInstrument() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        router.buy(fakeId, DEPOSIT_AMOUNT);
    }

    function test_buy_revertsOnInsufficientBalance() public {
        address poorUser = makeAddr("poor");

        vm.prank(poorUser);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(poorUser);
        vm.expectRevert();
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
    }

    function test_buy_revertsOnNoApproval() public {
        vm.prank(user);
        vm.expectRevert();
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
    }

    // ============ Sell Tests — No Swap (USDC market) ============

    function test_sell_noSwap_success() public {
        // First buy to get aTokens
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);

        // Now sell
        aUsdc.approve(address(router), DEPOSIT_AMOUNT);
        uint256 output = router.sell(usdcInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(output, DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(user), 0);
        // User gets USDC back
        assertEq(usdc.balanceOf(user), INITIAL_BALANCE);
    }

    function test_sell_noSwap_emitsEvent() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);

        aUsdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Sell(usdcInstrumentId, user, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_sell_noSwap_partialSell() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);

        uint256 halfAmount = DEPOSIT_AMOUNT / 2;
        aUsdc.approve(address(router), halfAmount);
        uint256 output = router.sell(usdcInstrumentId, halfAmount);
        vm.stopPrank();

        assertEq(output, halfAmount);
        assertEq(aUsdc.balanceOf(user), halfAmount);
    }

    // ============ Sell Tests — With Swap (USDT market, receive USDC) ============

    function test_sell_withSwap_success() public {
        // Buy USDT instrument first
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdtInstrumentId, DEPOSIT_AMOUNT);

        // Sell USDT instrument → withdraw USDT → swap to USDC
        aUsdt.approve(address(router), DEPOSIT_AMOUNT);
        uint256 output = router.sell(usdtInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Mock PM does 1:1 swap
        assertEq(output, DEPOSIT_AMOUNT);
        assertEq(aUsdt.balanceOf(user), 0);
    }

    // ============ Sell Tests — Revert Cases ============

    function test_sell_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.InvalidAmount.selector);
        router.sell(usdcInstrumentId, 0);
    }

    function test_sell_revertsOnUnregisteredInstrument() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(user);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        router.sell(fakeId, DEPOSIT_AMOUNT);
    }

    function test_sell_revertsOnNoApproval() public {
        // Buy first
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Try sell without approving aTokens
        vm.prank(user);
        vm.expectRevert();
        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT);
    }

    // ============ Callback Tests ============

    function test_unlockCallback_revertsOnNonPoolManager() public {
        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.CallerNotPoolManager.selector);
        router.unlockCallback(new bytes(0));
    }

    // ============ Buy + Sell Roundtrip ============

    function test_buySell_roundtrip_noSwap() public {
        uint256 balanceBefore = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT);

        aUsdc.approve(address(router), DEPOSIT_AMOUNT);
        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), balanceBefore);
        assertEq(aUsdc.balanceOf(user), 0);
    }

    function test_buySell_roundtrip_withSwap() public {
        uint256 balanceBefore = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdtInstrumentId, DEPOSIT_AMOUNT);

        aUsdt.approve(address(router), DEPOSIT_AMOUNT);
        router.sell(usdtInstrumentId, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // With 1:1 mock swap, should get exact amount back
        assertEq(usdc.balanceOf(user), balanceBefore);
        assertEq(aUsdt.balanceOf(user), 0);
    }

    // ============ Upgrade Tests ============

    function test_upgrade_onlyOwner() public {
        SwapDepositRouter newImpl = new SwapDepositRouter();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_success() public {
        SwapDepositRouter newImpl = new SwapDepositRouter();

        vm.prank(owner);
        router.upgradeToAndCall(address(newImpl), "");

        // State should be preserved
        assertEq(router.owner(), owner);
        assertEq(Currency.unwrap(router.stable()), address(usdc));
    }
}
