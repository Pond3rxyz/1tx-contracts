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
import {CCTPBridge} from "../../src/CCTPBridge.sol";
import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockTokenMessengerV2 {
    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinalityThreshold;
    bytes public lastHookData;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
    }
}

contract SwapDepositRouterTest is Test {
    using CurrencyLibrary for Currency;

    // Contracts
    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    MockPoolManager public mockPM;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;
    CCTPBridge public cctpBridge;
    MockTokenMessengerV2 public mockTokenMessenger;

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
    event CCTPBridgeUpdated(address indexed cctpBridge);
    event CCTPBridgeInitiated(
        address indexed sender,
        bytes32 indexed instrumentId,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

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
        mockTokenMessenger = new MockTokenMessengerV2();

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

        CCTPBridge cctpBridgeImpl = new CCTPBridge();
        ERC1967Proxy cctpBridgeProxy =
            new ERC1967Proxy(address(cctpBridgeImpl), abi.encodeWithSelector(CCTPBridge.initialize.selector, owner));
        cctpBridge = CCTPBridge(address(cctpBridgeProxy));

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
        swapPoolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});

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
        router.initialize(user, IPoolManager(address(mockPM)), instrumentRegistry, swapPoolRegistry, usdcCurrency);
    }

    function test_setCCTPBridge_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.setCCTPBridge(address(cctpBridge));
    }

    function test_setCCTPBridge_updatesStateAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit CCTPBridgeUpdated(address(cctpBridge));

        vm.prank(owner);
        router.setCCTPBridge(address(cctpBridge));

        assertEq(router.cctpBridge(), address(cctpBridge));
    }

    function test_setCCTPBridge_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidAddress.selector);
        router.setCCTPBridge(address(0));
    }

    // ============ Admin Setter Tests ============

    function test_setPoolManager_success() public {
        address newPM = makeAddr("newPM");
        vm.prank(owner);
        router.setPoolManager(IPoolManager(newPM));
        assertEq(address(router.poolManager()), newPM);
    }

    function test_setPoolManager_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidPoolManager.selector);
        router.setPoolManager(IPoolManager(address(0)));
    }

    function test_setPoolManager_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.setPoolManager(IPoolManager(makeAddr("newPM")));
    }

    function test_setInstrumentRegistry_success() public {
        address newIR = makeAddr("newIR");
        vm.prank(owner);
        router.setInstrumentRegistry(InstrumentRegistry(newIR));
        assertEq(address(router.instrumentRegistry()), newIR);
    }

    function test_setInstrumentRegistry_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidRegistry.selector);
        router.setInstrumentRegistry(InstrumentRegistry(address(0)));
    }

    function test_setInstrumentRegistry_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.setInstrumentRegistry(InstrumentRegistry(makeAddr("newIR")));
    }

    function test_setSwapPoolRegistry_success() public {
        address newSPR = makeAddr("newSPR");
        vm.prank(owner);
        router.setSwapPoolRegistry(SwapPoolRegistry(newSPR));
        assertEq(address(router.swapPoolRegistry()), newSPR);
    }

    function test_setSwapPoolRegistry_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidRegistry.selector);
        router.setSwapPoolRegistry(SwapPoolRegistry(address(0)));
    }

    function test_setSwapPoolRegistry_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.setSwapPoolRegistry(SwapPoolRegistry(makeAddr("newSPR")));
    }

    // ============ Rescue Tokens Tests ============

    function test_rescueTokens_success() public {
        uint256 stuckAmount = 500e6;
        usdc.mint(address(router), stuckAmount);

        address rescueTo = makeAddr("rescueTo");
        vm.prank(owner);
        router.rescueTokens(address(usdc), rescueTo, stuckAmount);

        assertEq(usdc.balanceOf(rescueTo), stuckAmount);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_rescueTokens_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidAddress.selector);
        router.rescueTokens(address(usdc), address(0), 100e6);
    }

    function test_rescueTokens_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.rescueTokens(address(usdc), user, 100e6);
    }

    // ============ Slippage Protection Tests ============

    function test_buy_revertsOnInsufficientDepositedAmount() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(SwapDepositRouter.InsufficientOutput.selector, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1)
        );
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1, false, 0);
        vm.stopPrank();
    }

    function test_sell_revertsOnInsufficientOutputAmount() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        aUsdc.approve(address(router), DEPOSIT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(SwapDepositRouter.InsufficientOutput.selector, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1)
        );
        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1);
        vm.stopPrank();
    }

    // ============ Buy Tests — No Swap (USDC market) ============

    function test_buy_noSwap_success() public {
        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

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
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    function test_buy_noSwap_multipleDeposits() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT * 3);

        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
        vm.stopPrank();

        assertEq(aUsdc.balanceOf(user), DEPOSIT_AMOUNT * 3);
    }

    // ============ Buy Tests — With Swap (USDT market, pay USDC) ============

    function test_buy_withSwap_success() public {
        // Buy USDT instrument paying USDC → requires USDC→USDT swap
        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(usdtInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

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
        router.buy(usdtInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    // ============ Buy Tests — Revert Cases ============

    function test_buy_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.InvalidAmount.selector);
        router.buy(usdcInstrumentId, 0, 0, false, 0);
    }

    function test_buy_revertsOnUnregisteredInstrument() public {
        bytes32 fakeMarketId = keccak256("fake");
        bytes32 fakeId = InstrumentIdLib.generateInstrumentId(block.chainid, makeAddr("fakeExecution"), fakeMarketId);

        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        router.buy(fakeId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    function test_buy_revertsOnInsufficientBalance() public {
        address poorUser = makeAddr("poor");

        vm.prank(poorUser);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(poorUser);
        vm.expectRevert();
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    function test_buy_revertsOnNoApproval() public {
        vm.prank(user);
        vm.expectRevert();
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    // ============ Sell Tests — No Swap (USDC market) ============

    function test_sell_noSwap_success() public {
        // First buy to get aTokens
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        // Now sell
        aUsdc.approve(address(router), DEPOSIT_AMOUNT);
        uint256 output = router.sell(usdcInstrumentId, DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        assertEq(output, DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(user), 0);
        // User gets USDC back
        assertEq(usdc.balanceOf(user), INITIAL_BALANCE);
    }

    function test_sell_noSwap_emitsEvent() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        aUsdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Sell(usdcInstrumentId, user, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT, 0);
        vm.stopPrank();
    }

    function test_sell_noSwap_partialSell() public {
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        uint256 halfAmount = DEPOSIT_AMOUNT / 2;
        aUsdc.approve(address(router), halfAmount);
        uint256 output = router.sell(usdcInstrumentId, halfAmount, 0);
        vm.stopPrank();

        assertEq(output, halfAmount);
        assertEq(aUsdc.balanceOf(user), halfAmount);
    }

    // ============ Sell Tests — With Swap (USDT market, receive USDC) ============

    function test_sell_withSwap_success() public {
        // Buy USDT instrument first
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdtInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        // Sell USDT instrument → withdraw USDT → swap to USDC
        aUsdt.approve(address(router), DEPOSIT_AMOUNT);
        uint256 output = router.sell(usdtInstrumentId, DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        // Mock PM does 1:1 swap
        assertEq(output, DEPOSIT_AMOUNT);
        assertEq(aUsdt.balanceOf(user), 0);
    }

    // ============ Bridge Tests ============

    function test_buy_crossChain_bridgesWithStandardModeByDefault() public {
        uint256 amount = 100e6;
        uint32 targetChainId = 8453;
        uint32 destinationDomain = 6;
        bytes32 marketId = keccak256("remote-market");
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(targetChainId, makeAddr("remoteExecution"), marketId);
        bytes32 mintRecipient = bytes32(uint256(uint160(user)));
        bytes32 destinationCaller = bytes32(uint256(uint160(makeAddr("standardRelayer"))));
        uint256 maxFee = 0;

        vm.prank(owner);
        cctpBridge.setTokenMessenger(address(mockTokenMessenger));

        vm.prank(owner);
        cctpBridge.setDestinationDomain(targetChainId, destinationDomain);

        vm.prank(owner);
        cctpBridge.setDestinationMintRecipient(targetChainId, mintRecipient);

        vm.prank(owner);
        cctpBridge.setDestinationCaller(targetChainId, destinationCaller);

        vm.prank(owner);
        cctpBridge.setAuthorizedCaller(address(router), true);

        vm.prank(owner);
        router.setCCTPBridge(address(cctpBridge));

        vm.prank(user);
        usdc.approve(address(router), amount);

        vm.expectEmit(true, true, true, true);
        emit CCTPBridgeInitiated(user, remoteInstrumentId, amount, destinationDomain, mintRecipient, maxFee, 2000);

        vm.prank(user);
        uint256 deposited = router.buy(remoteInstrumentId, amount, 0, false, 0);

        assertEq(deposited, 0);

        assertEq(mockTokenMessenger.lastAmount(), amount);
        assertEq(mockTokenMessenger.lastDestinationDomain(), destinationDomain);
        assertEq(mockTokenMessenger.lastMintRecipient(), mintRecipient);
        assertEq(mockTokenMessenger.lastBurnToken(), address(usdc));
        assertEq(mockTokenMessenger.lastDestinationCaller(), destinationCaller);
        assertEq(mockTokenMessenger.lastMaxFee(), maxFee);
        assertEq(mockTokenMessenger.lastMinFinalityThreshold(), 2000);
    }

    function test_buy_crossChain_bridgesWithFastMode() public {
        uint256 amount = 100e6;
        uint32 targetChainId = 8453;
        uint32 destinationDomain = 6;
        bytes32 marketId = keccak256("remote-market-fast");
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(targetChainId, makeAddr("remoteExecutionFast"), marketId);
        bytes32 mintRecipient = bytes32(uint256(uint160(makeAddr("destRecipientFast"))));
        bytes32 destinationCaller = bytes32(uint256(uint160(makeAddr("relayer"))));
        uint256 maxFee = 50_000;

        vm.prank(owner);
        cctpBridge.setTokenMessenger(address(mockTokenMessenger));

        vm.prank(owner);
        cctpBridge.setDestinationDomain(targetChainId, destinationDomain);

        vm.prank(owner);
        cctpBridge.setDestinationMintRecipient(targetChainId, mintRecipient);

        vm.prank(owner);
        cctpBridge.setDestinationCaller(targetChainId, destinationCaller);

        vm.prank(owner);
        cctpBridge.setAuthorizedCaller(address(router), true);

        vm.prank(owner);
        router.setCCTPBridge(address(cctpBridge));

        vm.prank(user);
        usdc.approve(address(router), amount);

        vm.prank(user);
        uint256 deposited = router.buy(remoteInstrumentId, amount, 0, true, maxFee);

        assertEq(deposited, 0);

        assertEq(mockTokenMessenger.lastAmount(), amount);
        assertEq(mockTokenMessenger.lastDestinationDomain(), destinationDomain);
        assertEq(mockTokenMessenger.lastMintRecipient(), mintRecipient);
        assertEq(mockTokenMessenger.lastBurnToken(), address(usdc));
        assertEq(mockTokenMessenger.lastDestinationCaller(), destinationCaller);
        assertEq(mockTokenMessenger.lastMaxFee(), maxFee);
        assertEq(mockTokenMessenger.lastMinFinalityThreshold(), 1000);
    }

    function test_buy_crossChain_bridgesWithFastMode_overload() public {
        uint256 amount = 100e6;
        uint32 targetChainId = 8453;
        uint32 destinationDomain = 6;
        bytes32 marketId = keccak256("remote-market-fast-overload");
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(targetChainId, makeAddr("remoteExecutionFastOverload"), marketId);
        bytes32 mintRecipient = bytes32(uint256(uint160(makeAddr("destRecipientFastOverload"))));
        bytes32 destinationCaller = bytes32(uint256(uint160(makeAddr("relayerOverload"))));
        uint256 maxFee = 75_000;

        vm.prank(owner);
        cctpBridge.setTokenMessenger(address(mockTokenMessenger));

        vm.prank(owner);
        cctpBridge.setDestinationDomain(targetChainId, destinationDomain);

        vm.prank(owner);
        cctpBridge.setDestinationMintRecipient(targetChainId, mintRecipient);

        vm.prank(owner);
        cctpBridge.setDestinationCaller(targetChainId, destinationCaller);

        vm.prank(owner);
        cctpBridge.setAuthorizedCaller(address(router), true);

        vm.prank(owner);
        router.setCCTPBridge(address(cctpBridge));

        vm.prank(user);
        usdc.approve(address(router), amount);

        vm.prank(user);
        uint256 deposited = router.buy(remoteInstrumentId, amount, 0, true, maxFee);

        assertEq(deposited, 0);
        assertEq(mockTokenMessenger.lastAmount(), amount);
        assertEq(mockTokenMessenger.lastDestinationDomain(), destinationDomain);
        assertEq(mockTokenMessenger.lastMintRecipient(), mintRecipient);
        assertEq(mockTokenMessenger.lastDestinationCaller(), destinationCaller);
        assertEq(mockTokenMessenger.lastMaxFee(), maxFee);
        assertEq(mockTokenMessenger.lastMinFinalityThreshold(), 1000);
    }

    function test_buy_crossChain_revertsWhenMessengerNotConfigured() public {
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(8453, makeAddr("remoteExecutionNoMessenger"), keccak256("m"));

        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.CrossChainBridgeNotConfigured.selector);
        router.buy(remoteInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    function test_buy_crossChain_revertsWhenDomainNotConfigured() public {
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(8453, makeAddr("remoteExecutionNoDomain"), keccak256("m2"));

        vm.prank(owner);
        cctpBridge.setTokenMessenger(address(mockTokenMessenger));

        vm.prank(owner);
        cctpBridge.setAuthorizedCaller(address(router), true);

        vm.prank(owner);
        router.setCCTPBridge(address(cctpBridge));

        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.DestinationDomainNotConfigured.selector, uint32(8453)));
        router.buy(remoteInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    function test_buy_crossChain_fastMode_revertsOnZeroFee() public {
        uint32 targetChainId = 8453;
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(targetChainId, makeAddr("remoteExecutionFastNoFee"), keccak256("m3"));

        vm.prank(owner);
        cctpBridge.setTokenMessenger(address(mockTokenMessenger));

        vm.prank(owner);
        cctpBridge.setDestinationDomain(targetChainId, 6);

        vm.prank(owner);
        cctpBridge.setDestinationMintRecipient(targetChainId, bytes32(uint256(uint160(user))));

        vm.prank(owner);
        cctpBridge.setDestinationCaller(targetChainId, bytes32(0));

        vm.prank(owner);
        cctpBridge.setAuthorizedCaller(address(router), true);

        vm.prank(owner);
        router.setCCTPBridge(address(cctpBridge));

        vm.prank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(CCTPBridge.FastTransferRequiresFee.selector);
        router.buy(remoteInstrumentId, DEPOSIT_AMOUNT, 0, true, 0);
    }

    // ============ Sell Tests — Revert Cases ============

    function test_sell_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.InvalidAmount.selector);
        router.sell(usdcInstrumentId, 0, 0);
    }

    function test_sell_revertsOnUnregisteredInstrument() public {
        bytes32 fakeMarketId = keccak256("fake");
        bytes32 fakeId =
            InstrumentIdLib.generateInstrumentId(block.chainid, makeAddr("fakeExecutionSell"), fakeMarketId);

        vm.prank(user);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        router.sell(fakeId, DEPOSIT_AMOUNT, 0);
    }

    function test_sell_revertsOnCrossChainInstrument() public {
        bytes32 remoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(8453, makeAddr("remoteExecutionSell"), keccak256("m4"));

        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.CrossChainSellNotSupported.selector);
        router.sell(remoteInstrumentId, DEPOSIT_AMOUNT, 0);
    }

    function test_sell_revertsOnNoApproval() public {
        // Buy first
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
        vm.stopPrank();

        // Try sell without approving aTokens
        vm.prank(user);
        vm.expectRevert();
        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT, 0);
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
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        aUsdc.approve(address(router), DEPOSIT_AMOUNT);
        router.sell(usdcInstrumentId, DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), balanceBefore);
        assertEq(aUsdc.balanceOf(user), 0);
    }

    function test_buySell_roundtrip_withSwap() public {
        uint256 balanceBefore = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdtInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);

        aUsdt.approve(address(router), DEPOSIT_AMOUNT);
        router.sell(usdtInstrumentId, DEPOSIT_AMOUNT, 0);
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

    // ============ setCCTPReceiver Tests ============

    function test_setCCTPReceiver_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.setCCTPReceiver(makeAddr("receiver"));
    }

    function test_setCCTPReceiver_updatesState() public {
        address receiverAddr = makeAddr("receiver");
        vm.prank(owner);
        router.setCCTPReceiver(receiverAddr);
        assertEq(router.cctpReceiver(), receiverAddr);
    }

    function test_setCCTPReceiver_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidAddress.selector);
        router.setCCTPReceiver(address(0));
    }

    // ============ buyFor Tests ============

    function test_buyFor_success() public {
        address receiverAddr = makeAddr("receiver");
        vm.prank(owner);
        router.setCCTPReceiver(receiverAddr);

        // Fund receiver and approve router
        usdc.mint(receiverAddr, DEPOSIT_AMOUNT);
        vm.prank(receiverAddr);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.prank(receiverAddr);
        uint256 deposited = router.buyFor(usdcInstrumentId, DEPOSIT_AMOUNT, user);

        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(user), DEPOSIT_AMOUNT);
    }

    function test_buyFor_revertsWhenCallerNotReceiver() public {
        vm.prank(owner);
        router.setCCTPReceiver(makeAddr("receiver"));

        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.UnauthorizedBuyForCaller.selector);
        router.buyFor(usdcInstrumentId, DEPOSIT_AMOUNT, user);
    }

    function test_buyFor_revertsOnZeroAmount() public {
        address receiverAddr = makeAddr("receiver");
        vm.prank(owner);
        router.setCCTPReceiver(receiverAddr);

        vm.prank(receiverAddr);
        vm.expectRevert(SwapDepositRouter.InvalidAmount.selector);
        router.buyFor(usdcInstrumentId, 0, user);
    }

    function test_buyFor_revertsOnZeroRecipient() public {
        address receiverAddr = makeAddr("receiver");
        vm.prank(owner);
        router.setCCTPReceiver(receiverAddr);

        vm.prank(receiverAddr);
        vm.expectRevert(SwapDepositRouter.InvalidAddress.selector);
        router.buyFor(usdcInstrumentId, DEPOSIT_AMOUNT, address(0));
    }

    function test_buyFor_emitsBuyEvent() public {
        address receiverAddr = makeAddr("receiver");
        vm.prank(owner);
        router.setCCTPReceiver(receiverAddr);

        usdc.mint(receiverAddr, DEPOSIT_AMOUNT);
        vm.startPrank(receiverAddr);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Buy(usdcInstrumentId, user, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        router.buyFor(usdcInstrumentId, DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    function test_buyFor_withSwap_success() public {
        address receiverAddr = makeAddr("receiver");
        vm.prank(owner);
        router.setCCTPReceiver(receiverAddr);

        usdc.mint(receiverAddr, DEPOSIT_AMOUNT);
        vm.startPrank(receiverAddr);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        uint256 deposited = router.buyFor(usdtInstrumentId, DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(aUsdt.balanceOf(user), DEPOSIT_AMOUNT);
    }
    // ============ Fee Logic Tests ============

    function test_setFeeConfig_success() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit SwapDepositRouter.FeeConfigUpdated(100, user);
        router.setFeeConfig(100, user);
        assertEq(router.protocolFeeBps(), 100);
        assertEq(router.feeRecipient(), user);
    }

    function test_setFeeConfig_revertsIfTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.FeeTooHigh.selector);
        router.setFeeConfig(501, user);
    }

    function test_setFeeConfig_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapDepositRouter.InvalidAddress.selector);
        router.setFeeConfig(100, address(0));
    }

    function test_setFeeConfig_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        router.setFeeConfig(100, user);
    }

    function test_BuyChargesProtocolFee() public {
        address feeRecipient = makeAddr("feeRecipient");
        vm.prank(owner);
        router.setFeeConfig(50, feeRecipient);

        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit SwapDepositRouter.FeeCharged(feeRecipient, 5e6, "protocol");

        uint256 deposited = router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0);
        vm.stopPrank();

        assertEq(deposited, DEPOSIT_AMOUNT - 5e6);
        assertEq(usdc.balanceOf(feeRecipient), 5e6);
        assertEq(aUsdc.balanceOf(user), DEPOSIT_AMOUNT - 5e6);
    }

    function test_BuyWithReferralChargesBothFees() public {
        address feeRecipient = makeAddr("feeRecipient");
        address referralRecipient = makeAddr("referralRecipient");
        vm.prank(owner);
        router.setFeeConfig(50, feeRecipient); // 0.5%

        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        uint256 deposited = router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 30, referralRecipient); // 0.3%
        vm.stopPrank();

        assertEq(deposited, DEPOSIT_AMOUNT - 8e6);
        assertEq(usdc.balanceOf(feeRecipient), 5e6);
        assertEq(usdc.balanceOf(referralRecipient), 3e6);
        assertEq(aUsdc.balanceOf(user), DEPOSIT_AMOUNT - 8e6);
    }

    function test_BuyWithReferralRevertsIfFeeTooHigh() public {
        vm.prank(owner);
        router.setFeeConfig(500, makeAddr("feeRecipient"));

        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        vm.expectRevert(SwapDepositRouter.FeeTooHigh.selector);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 501, makeAddr("referralRecipient"));

        // Exceeds total (1000)
        vm.expectRevert(SwapDepositRouter.FeeTooHigh.selector);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 501, makeAddr("referralRecipient"));
        vm.stopPrank();
    }

    function test_BuyForSkipsFees() public {
        address receiverAddr = makeAddr("receiver");
        address feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(owner);
        router.setCCTPReceiver(receiverAddr);
        router.setFeeConfig(500, feeRecipient); // Even with max fee
        vm.stopPrank();

        usdc.mint(receiverAddr, DEPOSIT_AMOUNT);
        vm.startPrank(receiverAddr);
        usdc.approve(address(router), DEPOSIT_AMOUNT);

        uint256 deposited = router.buyFor(usdcInstrumentId, DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        // No fees taken
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_SellFeeOnNetOutput() public {
        address feeRecipient = makeAddr("feeRecipient");
        vm.prank(owner);
        router.setFeeConfig(50, feeRecipient);

        // First buy to get aTokens
        vm.startPrank(user);
        usdc.approve(address(router), DEPOSIT_AMOUNT);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0); // 50 bps fee taken here too

        uint256 aTokenBalance = aUsdc.balanceOf(user);

        aUsdc.approve(address(router), aTokenBalance);
        uint256 output = router.sell(usdcInstrumentId, aTokenBalance, 0);
        vm.stopPrank();

        uint256 expectedFee = (aTokenBalance * 50) / 10_000;
        assertEq(output, aTokenBalance - expectedFee);

        // Fee recipient gets both buy and sell fees
        assertEq(usdc.balanceOf(feeRecipient), 5e6 + expectedFee);
    }
}
