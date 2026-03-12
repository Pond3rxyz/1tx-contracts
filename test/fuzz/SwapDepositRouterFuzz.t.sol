// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SwapDepositRouter} from "../../src/SwapDepositRouter.sol";
import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SwapDepositRouterFuzzTest is Test {
    using CurrencyLibrary for Currency;

    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    MockPoolManager public mockPM;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20 public aUsdc;
    MockERC20 public aUsdt;

    Currency public usdcCurrency;
    Currency public usdtCurrency;

    bytes32 public usdcInstrumentId;
    bytes32 public usdtInstrumentId;
    bytes32 public usdcMarketId;
    bytes32 public usdtMarketId;

    address public owner;
    address public executionAddress;

    uint256 constant DEPOSIT_AMOUNT = 1000e6;
    uint256 constant MAX_DEPOSIT = 1_000_000_000e6; // 1B tokens
    uint256 constant PM_BALANCE = 10_000_000_000e6; // 10B tokens for PM liquidity

    function setUp() public {
        owner = makeAddr("owner");
        executionAddress = makeAddr("executionAddress");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);

        usdcCurrency = Currency.wrap(address(usdc));
        usdtCurrency = Currency.wrap(address(usdt));

        mockPM = new MockPoolManager();

        // Registries
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

        // Aave
        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        mockAavePool.setReserveData(address(usdt), address(aUsdt));
        usdc.mint(address(mockAavePool), PM_BALANCE);
        usdt.mint(address(mockAavePool), PM_BALANCE);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.startPrank(owner);
        aaveAdapter.registerMarket(usdcCurrency);
        aaveAdapter.registerMarket(usdtCurrency);
        vm.stopPrank();

        // Router
        SwapDepositRouter routerImpl = new SwapDepositRouter();
        router = SwapDepositRouter(
            address(
                new ERC1967Proxy(
                    address(routerImpl),
                    abi.encodeWithSelector(
                        SwapDepositRouter.initialize.selector,
                        owner,
                        IPoolManager(address(mockPM)),
                        instrumentRegistry,
                        swapPoolRegistry,
                        usdcCurrency
                    )
                )
            )
        );

        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(router));

        // Market and instrument IDs
        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdtMarketId = keccak256(abi.encode(usdtCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        usdtInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdtMarketId);

        vm.startPrank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));
        instrumentRegistry.registerInstrument(executionAddress, usdtMarketId, address(aaveAdapter));
        vm.stopPrank();

        // Swap pool
        (Currency c0, Currency c1) = _orderCurrencies(usdcCurrency, usdtCurrency);
        PoolKey memory swapPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});

        vm.startPrank(owner);
        swapPoolRegistry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, swapPoolKey);
        swapPoolRegistry.registerDefaultSwapPool(usdtCurrency, usdcCurrency, swapPoolKey);
        vm.stopPrank();

        // Fund mock PM
        usdt.mint(address(mockPM), PM_BALANCE);
        usdc.mint(address(mockPM), PM_BALANCE);
    }

    function _orderCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    // ============ Buy Fuzz Tests ============

    function testFuzz_buy_noSwap_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, amount);

        vm.prank(fuzzUser);
        usdc.approve(address(router), amount);

        vm.prank(fuzzUser);
        uint256 deposited = router.buy(usdcInstrumentId, amount, 0, false, 0);

        assertEq(deposited, amount);
        assertEq(aUsdc.balanceOf(fuzzUser), amount);
    }

    function testFuzz_buy_withSwap_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, amount);

        vm.prank(fuzzUser);
        usdc.approve(address(router), amount);

        vm.prank(fuzzUser);
        uint256 deposited = router.buy(usdtInstrumentId, amount, 0, false, 0);

        assertEq(deposited, amount);
        assertEq(aUsdt.balanceOf(fuzzUser), amount);
    }

    function testFuzz_buy_zeroAmount_reverts(uint256 amount) public {
        // Force amount to 0
        amount = 0;

        address fuzzUser = makeAddr("fuzzUser");

        vm.prank(fuzzUser);
        vm.expectRevert(SwapDepositRouter.InvalidAmount.selector);
        router.buy(usdcInstrumentId, amount, 0, false, 0);
    }

    function testFuzz_buy_invalidInstrumentId_reverts(bytes32 randomId) public {
        // Force local chainId prefix so the ID routes locally (not cross-chain)
        randomId = bytes32((uint256(block.chainid) << 224) | (uint256(randomId) & ((1 << 224) - 1)));
        vm.assume(randomId != usdcInstrumentId);
        vm.assume(randomId != usdtInstrumentId);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, DEPOSIT_AMOUNT);

        vm.prank(fuzzUser);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(fuzzUser);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        router.buy(randomId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    // ============ Sell Fuzz Tests ============

    function testFuzz_sell_noSwap_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, amount);

        // Buy first
        vm.startPrank(fuzzUser);
        usdc.approve(address(router), amount);
        router.buy(usdcInstrumentId, amount, 0, false, 0);

        // Sell
        aUsdc.approve(address(router), amount);
        uint256 output = router.sell(usdcInstrumentId, amount, 0);
        vm.stopPrank();

        assertEq(output, amount);
        assertEq(usdc.balanceOf(fuzzUser), amount);
        assertEq(aUsdc.balanceOf(fuzzUser), 0);
    }

    function testFuzz_sell_withSwap_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, amount);

        // Buy USDT instrument
        vm.startPrank(fuzzUser);
        usdc.approve(address(router), amount);
        router.buy(usdtInstrumentId, amount, 0, false, 0);

        // Sell USDT instrument → get USDC back
        aUsdt.approve(address(router), amount);
        uint256 output = router.sell(usdtInstrumentId, amount, 0);
        vm.stopPrank();

        assertEq(output, amount);
        assertEq(usdc.balanceOf(fuzzUser), amount);
        assertEq(aUsdt.balanceOf(fuzzUser), 0);
    }

    function testFuzz_sell_invalidInstrumentId_reverts(bytes32 randomId) public {
        // Force local chainId prefix so the ID routes locally (not cross-chain)
        randomId = bytes32((uint256(block.chainid) << 224) | (uint256(randomId) & ((1 << 224) - 1)));
        vm.assume(randomId != usdcInstrumentId);
        vm.assume(randomId != usdtInstrumentId);

        address fuzzUser = makeAddr("fuzzUser");

        vm.prank(fuzzUser);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        router.sell(randomId, DEPOSIT_AMOUNT, 0);
    }

    // ============ Roundtrip Fuzz Tests ============

    function testFuzz_buySell_roundtrip_noSwap(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, amount);

        vm.startPrank(fuzzUser);
        usdc.approve(address(router), amount);
        router.buy(usdcInstrumentId, amount, 0, false, 0);

        aUsdc.approve(address(router), amount);
        router.sell(usdcInstrumentId, amount, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(fuzzUser), amount);
        assertEq(aUsdc.balanceOf(fuzzUser), 0);
    }

    function testFuzz_buySell_roundtrip_withSwap(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address fuzzUser = makeAddr("fuzzUser");
        usdc.mint(fuzzUser, amount);

        vm.startPrank(fuzzUser);
        usdc.approve(address(router), amount);
        router.buy(usdtInstrumentId, amount, 0, false, 0);

        aUsdt.approve(address(router), amount);
        router.sell(usdtInstrumentId, amount, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(fuzzUser), amount);
    }

    // ============ Multiple Operations ============

    function testFuzz_multipleOperations(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 10);
        address fuzzUser = makeAddr("fuzzUser");

        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < numOps; i++) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 1e6, 10_000e6);

            usdc.mint(fuzzUser, amount);

            vm.startPrank(fuzzUser);
            usdc.approve(address(router), amount);
            router.buy(usdcInstrumentId, amount, 0, false, 0);
            vm.stopPrank();

            totalDeposited += amount;
        }

        assertEq(aUsdc.balanceOf(fuzzUser), totalDeposited);

        // Sell all
        vm.startPrank(fuzzUser);
        aUsdc.approve(address(router), totalDeposited);
        router.sell(usdcInstrumentId, totalDeposited, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(fuzzUser), totalDeposited);
        assertEq(aUsdc.balanceOf(fuzzUser), 0);
    }

    // ============ Unauthorized Callback ============

    function testFuzz_unlockCallback_revertsOnNonPM(address caller) public {
        vm.assume(caller != address(mockPM));

        vm.prank(caller);
        vm.expectRevert(SwapDepositRouter.CallerNotPoolManager.selector);
        router.unlockCallback(new bytes(0));
    }
}
