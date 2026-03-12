// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {SwapDepositRouter} from "../../../src/SwapDepositRouter.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {ILendingAdapter} from "../../../src/interfaces/ILendingAdapter.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {CompoundAdapter} from "../../../src/adapters/CompoundAdapter.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {IAavePool} from "../../../src/interfaces/IAavePool.sol";
import {ICompoundV3} from "../../../src/interfaces/ICompoundV3.sol";

/// @title SwapDepositRouterE2EForkTest
/// @notice Comprehensive e2e fork tests: router × all adapters × all supported stablecoin instruments on Base mainnet
contract SwapDepositRouterE2EForkTest is AdapterForkTestBase {
    using stdJson for string;

    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    IPoolManager public poolManager;

    address public usdc;
    Currency public usdcCurrency;

    // Per-adapter execution addresses to avoid instrumentId collisions
    address public aaveExecAddr;
    address public morphoExecAddr;
    address public compoundExecAddr;
    address public fluidExecAddr;
    address public eulerExecAddr;

    // Adapters
    AaveAdapter public aaveAdapter;
    MorphoAdapter public morphoAdapter;
    CompoundAdapter public compoundAdapter;
    FluidAdapter public fluidAdapter;
    EulerAdapter public eulerAdapter;

    // Registered instruments (populated in setUp)
    struct Instrument {
        bytes32 id;
        string name;
        address adapter;
        bytes32 marketId;
        bool requiresSwap;
    }

    Instrument[] public instruments;

    function setUp() public override {
        super.setUp();

        aaveExecAddr = makeAddr("aaveExec");
        morphoExecAddr = makeAddr("morphoExec");
        compoundExecAddr = makeAddr("compoundExec");
        fluidExecAddr = makeAddr("fluidExec");
        eulerExecAddr = makeAddr("eulerExec");
        usdc = getToken("USDC");
        if (usdc == address(0)) return;
        usdcCurrency = Currency.wrap(usdc);

        poolManager = IPoolManager(json.readAddress(string.concat(networkPath, ".uniswapV4.poolManager")));

        _deployInfrastructure();
        _setupAave();
        _setupMorpho();
        _setupCompound();
        _setupFluid();
        _setupEuler();
    }

    // ============ Infrastructure ============

    function _deployInfrastructure() internal {
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(
                    address(new InstrumentRegistry()),
                    abi.encodeWithSelector(InstrumentRegistry.initialize.selector, address(this))
                )
            )
        );
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(
                    address(new SwapPoolRegistry()),
                    abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, address(this))
                )
            )
        );
        router = SwapDepositRouter(
            address(
                new ERC1967Proxy(
                    address(new SwapDepositRouter()),
                    abi.encodeWithSelector(
                        SwapDepositRouter.initialize.selector,
                        address(this),
                        poolManager,
                        instrumentRegistry,
                        swapPoolRegistry,
                        usdcCurrency
                    )
                )
            )
        );
    }

    // ============ Adapter Setup Helpers ============

    function _setupAave() internal {
        address aavePool = getAavePool();
        if (aavePool == address(0)) return;

        aaveAdapter = new AaveAdapter(aavePool, address(this));
        aaveAdapter.addAuthorizedCaller(address(router));

        // No-swap: USDC
        _tryRegisterAaveMarket("Aave-USDC", usdc, false);

        // With-swap: stablecoins that have configured swap pools
        // NOTE: GHO excluded — Aave V3 GHO has special facilitator rules that prevent standard withdraw
        _tryRegisterAaveMarketWithSwap("Aave-USDT", "USDT");
        _tryRegisterAaveMarketWithSwap("Aave-USDS", "USDS");
        _tryRegisterAaveMarketWithSwap("Aave-USDbC", "USDbC");
    }

    function _tryRegisterAaveMarket(string memory name, address token, bool requiresSwap) internal {
        Currency currency = Currency.wrap(token);
        IAavePool pool = IAavePool(getAavePool());
        IAavePool.ReserveData memory reserve = pool.getReserveData(token);
        if (reserve.aTokenAddress == address(0)) return;

        aaveAdapter.registerMarket(currency);
        _registerInstrument(name, address(aaveAdapter), _computeMarketId(currency), requiresSwap, aaveExecAddr);
    }

    function _tryRegisterAaveMarketWithSwap(string memory name, string memory symbol) internal {
        address token = getToken(symbol);
        if (token == address(0)) return;

        Currency currency = Currency.wrap(token);
        IAavePool pool = IAavePool(getAavePool());
        IAavePool.ReserveData memory reserve = pool.getReserveData(token);
        if (reserve.aTokenAddress == address(0)) return;

        aaveAdapter.registerMarket(currency);
        bytes32 marketId = _computeMarketId(currency);
        _registerInstrument(name, address(aaveAdapter), marketId, true, aaveExecAddr);
        _registerSwapPool(token);
    }

    function _setupMorpho() internal {
        morphoAdapter = new MorphoAdapter(address(this));
        morphoAdapter.addAuthorizedCaller(address(router));

        _tryRegisterMorphoVault("Morpho-steakhouseUSDC", "steakhouseUSDC");
        _tryRegisterMorphoVault("Morpho-sparkUSDC", "sparkUSDC");
        _tryRegisterMorphoVault("Morpho-gauntletUSDCPrime", "gauntletUSDCPrime");
        _tryRegisterMorphoVault("Morpho-steakhousePrimeUSDC", "steakhousePrimeUSDC");
        _tryRegisterMorphoVault("Morpho-clearstarUSDC", "clearstarUSDC");
        _tryRegisterMorphoVault("Morpho-mevFrontierUSDC", "mevFrontierUSDC");
    }

    function _tryRegisterMorphoVault(string memory name, string memory vaultName) internal {
        address vault = getMorphoVault(vaultName);
        if (vault == address(0)) return;

        Currency currency = Currency.wrap(usdc);
        try morphoAdapter.registerVault(currency, vault) {
            _registerInstrument(name, address(morphoAdapter), _computeVaultMarketId(vault), false, morphoExecAddr);
        } catch {}
    }

    function _setupCompound() internal {
        string memory compPath = string.concat(networkPath, ".protocols.compound.usdcComet");
        if (!vm.keyExistsJson(json, compPath)) return;

        compoundAdapter = new CompoundAdapter(address(this));
        compoundAdapter.addAuthorizedCaller(address(router));

        _tryRegisterCompoundMarket("Compound-USDC", "usdcComet", usdc, false);
        _tryRegisterCompoundMarket("Compound-USDbC", "usdbcComet", getToken("USDbC"), true);
    }

    function _tryRegisterCompoundMarket(string memory name, string memory cometName, address token, bool requiresSwap)
        internal
    {
        if (token == address(0)) return;
        address comet = getCompoundComet(cometName);
        if (comet == address(0)) return;

        Currency currency = Currency.wrap(token);
        try compoundAdapter.registerMarket(currency, comet) {
            _registerInstrument(
                name, address(compoundAdapter), _computeMarketId(currency), requiresSwap, compoundExecAddr
            );
            if (requiresSwap) _registerSwapPool(token);
        } catch {}
    }

    function _setupFluid() internal {
        fluidAdapter = new FluidAdapter(address(this));
        fluidAdapter.addAuthorizedCaller(address(router));

        _tryRegisterFluidToken("Fluid-fUSDC", "fUSDC", usdc, false);
        _tryRegisterFluidToken("Fluid-fEURC", "fEURC", getToken("EURC"), true);
        _tryRegisterFluidToken("Fluid-fGHO", "fGHO", getToken("GHO"), true);
    }

    function _tryRegisterFluidToken(string memory name, string memory fTokenName, address token, bool requiresSwap)
        internal
    {
        if (token == address(0)) return;
        address fToken = getFluidFToken(fTokenName);
        if (fToken == address(0)) return;

        Currency currency = Currency.wrap(token);
        try fluidAdapter.registerFToken(currency, fToken) {
            _registerInstrument(
                name, address(fluidAdapter), _computeVaultMarketId(fToken), requiresSwap, fluidExecAddr
            );
            if (requiresSwap) _registerSwapPool(token);
        } catch {}
    }

    function _setupEuler() internal {
        eulerAdapter = new EulerAdapter(address(this));
        eulerAdapter.addAuthorizedCaller(address(router));

        _tryRegisterEulerVault("Euler-eeUSDC", "eeUSDC");
    }

    function _tryRegisterEulerVault(string memory name, string memory vaultName) internal {
        address vault = getEulerVault(vaultName);
        if (vault == address(0)) return;

        Currency currency = Currency.wrap(usdc);
        try eulerAdapter.registerVault(currency, vault) {
            _registerInstrument(name, address(eulerAdapter), _computeVaultMarketId(vault), false, eulerExecAddr);
        } catch {}
    }

    // ============ Registration Helpers ============

    function _registerInstrument(
        string memory name,
        address adapter,
        bytes32 marketId,
        bool requiresSwap,
        address execAddr
    ) internal {
        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, execAddr, marketId);
        instrumentRegistry.registerInstrument(execAddr, marketId, adapter);
        instruments.push(
            Instrument({id: instrumentId, name: name, adapter: adapter, marketId: marketId, requiresSwap: requiresSwap})
        );
    }

    function _registerSwapPool(address token) internal {
        Currency tokenCurrency = Currency.wrap(token);

        // Check if already registered
        try swapPoolRegistry.getDefaultSwapPool(usdcCurrency, tokenCurrency) {
            return; // Already registered
        } catch {}

        // Find swap pool config from JSON
        string memory swapPoolsPath = string.concat(networkPath, ".swapPools");
        bytes memory raw = json.parseRaw(swapPoolsPath);
        SwapPoolConfig[] memory pools = abi.decode(raw, (SwapPoolConfig[]));

        string memory tokenSymbol = _findTokenSymbol(token);
        if (bytes(tokenSymbol).length == 0) return;

        for (uint256 i = 0; i < pools.length; i++) {
            if (
                _strEq(pools[i].tokenIn, "USDC") && _strEq(pools[i].tokenOut, tokenSymbol)
                    || _strEq(pools[i].tokenIn, tokenSymbol) && _strEq(pools[i].tokenOut, "USDC")
            ) {
                (Currency c0, Currency c1) = _order(usdcCurrency, tokenCurrency);
                PoolKey memory poolKey = PoolKey({
                    currency0: c0,
                    currency1: c1,
                    fee: pools[i].fee,
                    tickSpacing: int24(pools[i].tickSpacing),
                    hooks: IHooks(pools[i].hooks)
                });
                swapPoolRegistry.registerDefaultSwapPool(usdcCurrency, tokenCurrency, poolKey);
                swapPoolRegistry.registerDefaultSwapPool(tokenCurrency, usdcCurrency, poolKey);
                return;
            }
        }
    }

    struct SwapPoolConfig {
        uint24 fee;
        address hooks;
        int24 tickSpacing;
        string tokenIn;
        string tokenOut;
    }

    function _findTokenSymbol(address token) internal view returns (string memory) {
        string[8] memory symbols = ["USDC", "USDT", "DAI", "EURC", "USDbC", "GHO", "USDS", "eUSD"];
        for (uint256 i = 0; i < symbols.length; i++) {
            if (getToken(symbols[i]) == token) return symbols[i];
        }
        return "";
    }

    function _order(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Approve yield tokens — Compound V3 uses allow() instead of ERC20 approve
    function _approveYieldTokens(address adapter, address yieldToken, address from, address spender, uint256 amount)
        internal
    {
        bool needsAllow = ILendingAdapter(adapter).requiresAllow();
        vm.prank(from);
        if (needsAllow) {
            ICompoundV3(yieldToken).allow(spender, true);
        } else {
            IERC20(yieldToken).approve(spender, amount);
        }
    }

    // ============ E2E Tests: Buy All Instruments ============

    function test_fork_e2e_buyAll_noSwap() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].requiresSwap) continue;
            _testBuy(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one no-swap instrument");
    }

    function test_fork_e2e_buyAll_withSwap() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            if (!instruments[i].requiresSwap) continue;
            _testBuy(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one with-swap instrument");
    }

    // ============ E2E Tests: Full Roundtrip All Instruments ============

    function test_fork_e2e_roundtripAll_noSwap() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].requiresSwap) continue;
            _testRoundtrip(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one no-swap roundtrip");
    }

    function test_fork_e2e_roundtripAll_withSwap() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            if (!instruments[i].requiresSwap) continue;
            _testRoundtrip(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one with-swap roundtrip");
    }

    // ============ E2E Tests: Multiple Users ============

    function test_fork_e2e_multipleUsers_sameInstrument() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0]; // Aave-USDC

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint256 aliceAmount = 500e6;
        uint256 bobAmount = 1500e6;

        // Alice buys
        _dealTokens(usdc, alice, aliceAmount);
        _approveTokens(usdc, alice, address(router), aliceAmount);
        vm.prank(alice);
        uint256 aliceDeposited = router.buy(inst.id, aliceAmount, 0, false, 0);

        // Bob buys
        _dealTokens(usdc, bob, bobAmount);
        _approveTokens(usdc, bob, address(router), bobAmount);
        vm.prank(bob);
        uint256 bobDeposited = router.buy(inst.id, bobAmount, 0, false, 0);

        // Both should have yield tokens
        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        assertGt(_getBalance(yieldToken, alice), 0, "Alice should have yield tokens");
        assertGt(_getBalance(yieldToken, bob), 0, "Bob should have yield tokens");

        // Alice sells
        uint256 aliceYield = _getBalance(yieldToken, alice);
        _approveYieldTokens(inst.adapter, yieldToken, alice, address(router), aliceYield);
        vm.prank(alice);
        uint256 aliceOutput = router.sell(inst.id, aliceYield, 0);

        // Bob sells
        uint256 bobYield = _getBalance(yieldToken, bob);
        _approveYieldTokens(inst.adapter, yieldToken, bob, address(router), bobYield);
        vm.prank(bob);
        uint256 bobOutput = router.sell(inst.id, bobYield, 0);

        assertGe(aliceOutput, aliceDeposited - 2, "Alice roundtrip should preserve value");
        assertGe(bobOutput, bobDeposited - 2, "Bob roundtrip should preserve value");
    }

    // ============ E2E Tests: Slippage Protection ============

    function test_fork_e2e_buy_minDepositedAmount_reverts() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert();
        router.buy(inst.id, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1e6, false, 0);
    }

    function test_fork_e2e_sell_minOutputAmount_reverts() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        // Buy first
        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        // Sell with excessive minOutput
        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, user);
        _approveYieldTokens(inst.adapter, yieldToken, user, address(router), yieldBalance);

        vm.prank(user);
        vm.expectRevert();
        router.sell(inst.id, yieldBalance, DEPOSIT_AMOUNT * 2);
    }

    // ============ E2E Tests: Small / Large Amounts ============

    function test_fork_e2e_buy_smallAmount() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];
        uint256 smallAmount = 1e6; // 1 USDC

        _dealTokens(usdc, user, smallAmount);
        _approveTokens(usdc, user, address(router), smallAmount);

        vm.prank(user);
        uint256 deposited = router.buy(inst.id, smallAmount, 0, false, 0);
        assertGt(deposited, 0, "Small buy should deposit nonzero");
    }

    function test_fork_e2e_buy_largeAmount() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];
        uint256 largeAmount = 1_000_000e6; // 1M USDC

        _dealTokens(usdc, user, largeAmount);
        _approveTokens(usdc, user, address(router), largeAmount);

        vm.prank(user);
        uint256 deposited = router.buy(inst.id, largeAmount, 0, false, 0);
        assertGt(deposited, 0, "Large buy should deposit nonzero");
    }

    // ============ E2E Tests: Sequential Operations ============

    function test_fork_e2e_multipleBuysAndSingleSell() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        uint256 buyAmount = 100e6;
        uint256 totalBuys = 5;

        // Buy multiple times
        for (uint256 i = 0; i < totalBuys; i++) {
            _dealTokens(usdc, user, buyAmount);
            _approveTokens(usdc, user, address(router), buyAmount);
            vm.prank(user);
            router.buy(inst.id, buyAmount, 0, false, 0);
        }

        // Sell all at once
        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 totalYield = _getBalance(yieldToken, user);
        assertGt(totalYield, 0, "Should have accumulated yield tokens");

        _approveYieldTokens(inst.adapter, yieldToken, user, address(router), totalYield);
        vm.prank(user);
        uint256 output = router.sell(inst.id, totalYield, 0);

        // Allow rounding loss of up to 2 wei per buy
        assertGe(output, buyAmount * totalBuys - totalBuys * 2, "Should recover most of the deposited amount");
    }

    // ============ E2E Tests: Cross-Chain Revert ============

    function test_fork_e2e_sell_crossChainInstrument_reverts() public {
        uint256 otherChainId = block.chainid == 8453 ? 42161 : 8453;
        bytes32 fakeId =
            InstrumentIdLib.generateInstrumentId(otherChainId, aaveExecAddr, _computeMarketId(usdcCurrency));

        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.CrossChainSellNotSupported.selector);
        router.sell(fakeId, 1e6, 0);
    }

    function test_fork_e2e_buy_crossChain_reverts_noBridge() public {
        uint256 otherChainId = block.chainid == 8453 ? 42161 : 8453;
        bytes32 fakeId =
            InstrumentIdLib.generateInstrumentId(otherChainId, aaveExecAddr, _computeMarketId(usdcCurrency));

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(SwapDepositRouter.CrossChainBridgeNotConfigured.selector);
        router.buy(fakeId, DEPOSIT_AMOUNT, 0, false, 0);
    }

    // ============ E2E Tests: Admin Functions ============

    function test_fork_e2e_rescueTokens() public {
        _dealTokens(usdc, address(router), 100e6);
        uint256 routerBal = _getBalance(usdc, address(router));
        assertGt(routerBal, 0);

        address rescueTo = makeAddr("rescue");
        router.rescueTokens(usdc, rescueTo, routerBal);
        assertEq(_getBalance(usdc, rescueTo), routerBal);
        assertEq(_getBalance(usdc, address(router)), 0);
    }

    function test_fork_e2e_setters_onlyOwner() public {
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);
        vm.expectRevert();
        router.setPoolManager(IPoolManager(address(1)));
        vm.expectRevert();
        router.setInstrumentRegistry(InstrumentRegistry(address(1)));
        vm.expectRevert();
        router.setSwapPoolRegistry(SwapPoolRegistry(address(1)));
        vm.expectRevert();
        router.rescueTokens(usdc, attacker, 1);
        vm.stopPrank();
    }

    // ============ E2E Tests: No Leftover Tokens ============

    function test_fork_e2e_noTokensLeftInRouter_afterBuy() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        assertEq(_getBalance(usdc, address(router)), 0, "Router should not hold USDC after buy");

        Currency marketCurrency = ILendingAdapter(inst.adapter).getMarketCurrency(inst.marketId);
        address marketToken = Currency.unwrap(marketCurrency);
        if (marketToken != usdc) {
            assertEq(_getBalance(marketToken, address(router)), 0, "Router should not hold market token after buy");
        }
    }

    function test_fork_e2e_noTokensLeftInRouter_afterSell() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        // Buy
        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        // Sell
        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, user);
        _approveYieldTokens(inst.adapter, yieldToken, user, address(router), yieldBalance);
        vm.prank(user);
        router.sell(inst.id, yieldBalance, 0);

        assertEq(_getBalance(usdc, address(router)), 0, "Router should not hold USDC after sell");
        assertEq(_getBalance(yieldToken, address(router)), 0, "Router should not hold yield tokens after sell");
    }

    // ============ Internal Test Helpers ============

    function _testBuy(Instrument memory inst, uint256 amount) internal {
        address testUser = makeAddr(string.concat("buyer-", inst.name));
        vm.deal(testUser, 1 ether);

        _dealTokens(usdc, testUser, amount);
        _approveTokens(usdc, testUser, address(router), amount);

        vm.prank(testUser);
        uint256 deposited = router.buy(inst.id, amount, 0, false, 0);

        assertGt(deposited, 0, string.concat("Buy should deposit nonzero for ", inst.name));

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        assertGt(_getBalance(yieldToken, testUser), 0, string.concat("Should receive yield tokens for ", inst.name));
    }

    function _testRoundtrip(Instrument memory inst, uint256 amount) internal {
        address testUser = makeAddr(string.concat("roundtrip-", inst.name));
        vm.deal(testUser, 1 ether);

        // Buy (input is always USDC)
        _dealTokens(usdc, testUser, amount);
        _approveTokens(usdc, testUser, address(router), amount);
        vm.prank(testUser);
        uint256 deposited = router.buy(inst.id, amount, 0, false, 0);
        assertGt(deposited, 0, string.concat("Buy failed for ", inst.name));

        // Sell (output is always USDC)
        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, testUser);
        _approveYieldTokens(inst.adapter, yieldToken, testUser, address(router), yieldBalance);
        vm.prank(testUser);
        uint256 output = router.sell(inst.id, yieldBalance, 0);

        assertGt(output, 0, string.concat("Sell should return nonzero for ", inst.name));

        // Compare output USDC against input USDC (not deposited amount which may be in different decimals)
        if (!inst.requiresSwap) {
            // Allow small rounding loss from yield token share math (aTokens, ERC4626 vaults)
            assertGe(output, amount - 2, string.concat("Roundtrip should preserve value for ", inst.name));
        } else {
            // With swap, allow up to 10% slippage from fees
            assertGt(output, amount * 90 / 100, string.concat("Roundtrip lost too much to slippage for ", inst.name));
        }
    }
}
