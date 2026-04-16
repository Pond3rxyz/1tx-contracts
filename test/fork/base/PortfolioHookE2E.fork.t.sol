// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {PortfolioStrategy} from "../../../src/hooks/PortfolioStrategy.sol";
import {IPortfolioStrategy} from "../../../src/interfaces/IPortfolioStrategy.sol";
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

/// @title PortfolioHookE2EForkTest
/// @notice End-to-end fork tests for PortfolioHook + PortfolioVault on Base mainnet
/// @dev Tests real protocol interactions: Aave, Morpho, Compound, Euler, Fluid
///      with real Uniswap V4 PoolManager and real tokens.
contract PortfolioHookE2EForkTest is Test {
    using stdJson for string;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal json;
    string internal networkPath;

    // Infrastructure (real deployed contracts on Base mainnet)
    IPermit2 public permit2;
    IPoolManager public poolManager;
    IUniswapV4Router04 public swapRouter;

    // Portfolio contracts
    PortfolioHook public hook;
    PortfolioVault public vault;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;

    // Strategy
    PortfolioStrategy public strategy;

    // Adapters
    AaveAdapter public aaveAdapter;
    MorphoAdapter public morphoAdapter;
    EulerAdapter public eulerAdapter;

    // Tokens
    address public usdc;
    Currency public usdcCurrency;

    // Pool
    PoolKey public portfolioPoolKey;
    PoolId public portfolioPoolId;

    // Test addresses
    address public owner;
    address public user;
    address public user2;
    address public executionAddress;

    uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1k USDC
    bool internal forkActive;

    // Track registered instruments
    struct Instrument {
        bytes32 id;
        string name;
        address adapter;
    }

    Instrument[] public instruments;

    function setUp() public {
        // Fork Base mainnet — skip if RPC not configured
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        forkActive = true;
        vm.createSelectFork(rpcUrl);

        json = vm.readFile(CONFIG_PATH);
        networkPath = ".networks.baseMainnet";

        owner = makeAddr("owner");
        user = makeAddr("user");
        user2 = makeAddr("user2");
        executionAddress = makeAddr("portfolioExec");

        vm.deal(owner, 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);

        usdc = json.readAddress(string.concat(networkPath, ".tokens.USDC"));
        usdcCurrency = Currency.wrap(usdc);

        _loadV4Infrastructure();
        _deployRegistries();
        _setupAdapters();
        _deployVaultAndHook();
    }

    // ============ Infrastructure Setup ============

    function _loadV4Infrastructure() internal {
        string memory v4Path = string.concat(networkPath, ".uniswapV4");
        permit2 = IPermit2(json.readAddress(string.concat(v4Path, ".permit2")));
        poolManager = IPoolManager(json.readAddress(string.concat(v4Path, ".poolManager")));
        // Deploy hookmate router pointing to the real PM — the on-chain router has a different interface
        swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));
    }

    function _deployRegistries() internal {
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(
                    address(new InstrumentRegistry()),
                    abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner)
                )
            )
        );
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(
                    address(new SwapPoolRegistry()), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner)
                )
            )
        );
    }

    function _setupAdapters() internal {
        // Aave
        address aavePool = json.readAddress(string.concat(networkPath, ".protocols.aave.pool"));
        aaveAdapter = new AaveAdapter(aavePool, owner);

        vm.startPrank(owner);
        aaveAdapter.registerMarket(usdcCurrency);

        bytes32 usdcMarketId = keccak256(abi.encode(usdcCurrency));
        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));
        instruments.push(Instrument({id: instrumentId, name: "Aave-USDC", adapter: address(aaveAdapter)}));

        // Morpho — register steakhouseUSDC vault
        string memory morphoPath = string.concat(networkPath, ".protocols.morpho.vaults.steakhouseUSDC");
        if (vm.keyExistsJson(json, morphoPath)) {
            address morphoVault = json.readAddress(morphoPath);
            morphoAdapter = new MorphoAdapter(owner);
            morphoAdapter.registerVault(usdcCurrency, morphoVault);
            bytes32 morphoMarketId = bytes32(uint256(uint160(morphoVault)));
            bytes32 morphoInstrumentId =
                InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, morphoMarketId);
            instrumentRegistry.registerInstrument(executionAddress, morphoMarketId, address(morphoAdapter));
            instruments.push(
                Instrument({id: morphoInstrumentId, name: "Morpho-steakhouseUSDC", adapter: address(morphoAdapter)})
            );
        }

        // Euler — register eeUSDC
        string memory eulerPath = string.concat(networkPath, ".protocols.eulerEarn.vaults.eeUSDC");
        if (vm.keyExistsJson(json, eulerPath)) {
            address eulerVault = json.readAddress(eulerPath);
            eulerAdapter = new EulerAdapter(owner);
            eulerAdapter.registerVault(usdcCurrency, eulerVault);
            bytes32 eulerMarketId = bytes32(uint256(uint160(eulerVault)));
            bytes32 eulerInstrumentId =
                InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, eulerMarketId);
            instrumentRegistry.registerInstrument(executionAddress, eulerMarketId, address(eulerAdapter));
            instruments.push(Instrument({id: eulerInstrumentId, name: "Euler-eeUSDC", adapter: address(eulerAdapter)}));
        }
        vm.stopPrank();
    }

    function _deployVaultAndHook() internal {
        // Deploy shared strategy (UUPS proxy)
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, owner)
                )
            )
        );

        // Single allocation: 100% Aave USDC for basic tests
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 10000});

        vault = new PortfolioVault(
            PortfolioVault.InitParams({
                initialOwner: owner,
                name: "Fork Test Portfolio",
                symbol: "fPORT",
                stable: usdcCurrency,
                poolManager: poolManager,
                instrumentRegistry: instrumentRegistry,
                swapPoolRegistry: swapPoolRegistry,
                strategy: IPortfolioStrategy(address(strategy)),
                allocations: allocs
            })
        );

        // Deploy hook
        address hookAddress = _computeHookAddress();
        deployCodeTo("PortfolioHook.sol:PortfolioHook", abi.encode(poolManager, vault, usdcCurrency), hookAddress);
        hook = PortfolioHook(hookAddress);

        vm.startPrank(owner);
        vault.setHook(address(hook));
        aaveAdapter.addAuthorizedCaller(address(strategy));
        if (address(morphoAdapter) != address(0)) {
            morphoAdapter.addAuthorizedCaller(address(strategy));
        }
        if (address(eulerAdapter) != address(0)) {
            eulerAdapter.addAuthorizedCaller(address(strategy));
        }
        vm.stopPrank();

        // Create pool
        (Currency c0, Currency c1) = Currency.unwrap(usdcCurrency) < address(vault)
            ? (usdcCurrency, Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), usdcCurrency);

        portfolioPoolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddress)});
        portfolioPoolId = portfolioPoolKey.toId();

        poolManager.initialize(portfolioPoolKey, Constants.SQRT_PRICE_1_1);
    }

    modifier onlyFork() {
        if (!forkActive) return;
        _;
    }

    // ============ Helpers ============

    function _computeHookAddress() internal pure returns (address) {
        return address(uint160(0x1000000000000000000000000000000000000aC8));
    }

    function _buyZeroForOne() internal view returns (bool) {
        return Currency.unwrap(portfolioPoolKey.currency0) == Currency.unwrap(usdcCurrency);
    }

    function _setupUserApprovals(address u) internal {
        vm.startPrank(u);
        IERC20(usdc).approve(address(permit2), type(uint256).max);
        IERC20(usdc).approve(address(swapRouter), type(uint256).max);
        permit2.approve(usdc, address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _setupSellApprovals(address u) internal {
        vm.startPrank(u);
        IERC20(address(vault)).approve(address(permit2), type(uint256).max);
        IERC20(address(vault)).approve(address(swapRouter), type(uint256).max);
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
        _setupSellApprovals(shareOwner);
        uint256 usdcBefore = IERC20(usdc).balanceOf(shareOwner);
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
        usdcReturned = IERC20(usdc).balanceOf(shareOwner) - usdcBefore;
    }

    // ============ Basic Fork Tests ============

    function test_fork_buy_realAave() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        assertGt(shares, 0, "should mint shares on fork");
        assertGt(vault.totalAssets(), 0, "NAV should be positive after buy");
    }

    function test_fork_buySell_roundtrip_realAave() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 returned = _sellShares(shares, user);

        // Aave deposits/withdrawals should be nearly lossless (1:1 aTokens)
        assertGe(returned, DEPOSIT_AMOUNT - 3, "roundtrip should preserve value within 3 wei");
    }

    function test_fork_sqrtPrice_stays_static() public onlyFork {
        (uint160 priceBefore,,,) = poolManager.getSlot0(portfolioPoolId);

        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);
        _buyShares(DEPOSIT_AMOUNT, user);

        (uint160 priceAfter,,,) = poolManager.getSlot0(portfolioPoolId);
        assertEq(priceBefore, priceAfter, "price should stay static on fork");
    }

    // ============ Large Amount Fork Tests ============

    function test_fork_buy_largeAmount_100k() public onlyFork {
        uint256 largeAmount = 100_000e6;
        deal(usdc, user, largeAmount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(largeAmount, user);
        assertGt(shares, 0, "100k buy should work");
        assertApproxEqRel(vault.totalAssets(), largeAmount, 1e16, "NAV should match deposit");
    }

    function test_fork_buy_largeAmount_1M() public onlyFork {
        uint256 largeAmount = 1_000_000e6;
        deal(usdc, user, largeAmount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(largeAmount, user);
        assertGt(shares, 0, "1M buy should work on Aave");
    }

    function test_fork_roundtrip_1M() public onlyFork {
        uint256 largeAmount = 1_000_000e6;
        deal(usdc, user, largeAmount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(largeAmount, user);
        uint256 returned = _sellShares(shares, user);

        // Within 0.01% of deposited amount for Aave
        assertGe(returned, largeAmount * 9999 / 10000, "1M roundtrip should be near lossless");
    }

    // ============ Multi-User Fork Tests ============

    function test_fork_multiUser_buy_sell() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        deal(usdc, user2, DEPOSIT_AMOUNT * 2);
        _setupUserApprovals(user);
        _setupUserApprovals(user2);

        uint256 shares1 = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT * 2, user2);

        assertGt(shares1, 0);
        assertGt(shares2, 0);
        // user2 deposited 2x, should have ~2x shares
        assertApproxEqRel(shares2, shares1 * 2, 1e16, "double deposit should give double shares");

        // user1 exits
        uint256 returned1 = _sellShares(shares1, user);
        assertGe(returned1, DEPOSIT_AMOUNT - 3, "user1 should recover deposit within 3 wei");

        // user2 exits
        uint256 returned2 = _sellShares(shares2, user2);
        assertGe(returned2, DEPOSIT_AMOUNT * 2 - 5, "user2 should recover deposit within 5 wei");
    }

    function test_fork_multiUser_sequential_exits() public onlyFork {
        address[] memory users_ = new address[](5);
        uint256[] memory deposits = new uint256[](5);
        uint256[] memory shares_ = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            users_[i] = makeAddr(string(abi.encodePacked("forkUser", vm.toString(i))));
            vm.deal(users_[i], 1 ether);
            deposits[i] = (i + 1) * 100e6; // 100, 200, 300, 400, 500 USDC
            deal(usdc, users_[i], deposits[i]);
            _setupUserApprovals(users_[i]);
            shares_[i] = _buyShares(deposits[i], users_[i]);
        }

        // Everyone exits in reverse order
        for (uint256 i = 5; i > 0; i--) {
            uint256 idx = i - 1;
            uint256 returned = _sellShares(shares_[idx], users_[idx]);
            assertGe(returned, deposits[idx] * 99 / 100, "each user should recover at least 99% of deposit");
        }

        // Vault should be nearly empty
        assertLe(vault.totalAssets(), 10, "vault should be near empty");
    }

    // ============ Yield Accrual Fork Tests ============

    function test_fork_yieldAccrual_afterTimeSkip() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 navBefore = vault.totalAssets();

        // Skip 30 days — Aave yield should accrue
        vm.warp(block.timestamp + 30 days);

        uint256 navAfter = vault.totalAssets();
        // Aave yield is typically 2-8% APY, so 30 days ~= 0.2-0.7%
        assertGe(navAfter, navBefore, "NAV should not decrease after time (Aave yield)");

        // Sell after yield accrual
        uint256 returned = _sellShares(shares, user);
        assertGe(returned, DEPOSIT_AMOUNT, "should get at least deposit back after yield");
    }

    // ============ Exact Output Fork Tests ============

    function test_fork_exactOutputBuy() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT * 2);
        _setupUserApprovals(user);

        uint256 targetShares = 500e6;
        vm.prank(user);
        swapRouter.swapTokensForExactTokens({
            amountOut: targetShares,
            amountInMax: DEPOSIT_AMOUNT * 2,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        });

        assertEq(vault.balanceOf(user), targetShares, "should get exact shares on fork");
    }

    function test_fork_exactOutputSell() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        _buyShares(DEPOSIT_AMOUNT, user);
        _setupSellApprovals(user);

        uint256 requestedOut = 500e6;
        uint256 usdcBefore = IERC20(usdc).balanceOf(user);

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

        uint256 usdcDelta = IERC20(usdc).balanceOf(user) - usdcBefore;
        assertEq(usdcDelta, requestedOut, "should get exact USDC on fork");
    }

    // ============ NAV Consistency Fork Tests ============

    function test_fork_nav_matches_deposit() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        _buyShares(DEPOSIT_AMOUNT, user);

        uint256 nav = vault.totalAssets();
        // With Aave 1:1 aTokens, NAV should closely match deposit
        assertApproxEqRel(nav, DEPOSIT_AMOUNT, 1e16, "NAV should match deposit on Aave");
    }

    function test_fork_sharePrice_consistency() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares = vault.balanceOf(user);

        uint256 shareValue = vault.convertToAssets(shares);
        assertApproxEqRel(shareValue, DEPOSIT_AMOUNT, 1e16, "share value should match deposit");
    }

    // ============ PM State Tests ============

    function test_fork_pmDeadSharesBurnedByNextSwap() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT * 2);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        _sellShares(shares, user);

        // After sell, PM holds "dead" ERC-20 shares (router settled them after afterSwap)
        uint256 pmAfterSell = vault.balanceOf(address(poolManager));
        assertGt(pmAfterSell, 0, "PM should hold dead shares after sell");

        // Next buy burns them in its afterSwap
        _buyShares(DEPOSIT_AMOUNT, user);
        assertEq(vault.balanceOf(address(poolManager)), 0, "PM dead shares burned by next buy");
    }

    function test_fork_hookHoldsNoResidualTokens() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        _sellShares(shares, user);

        assertLe(IERC20(usdc).balanceOf(address(hook)), 1, "hook should hold at most 1 wei USDC");
        assertEq(vault.balanceOf(address(hook)), 0, "hook should hold no shares");
    }

    // ============ Multi-Allocation Fork Tests ============

    /// @dev Deploys a fresh vault+hook+pool with multi-allocation config for full E2E testing
    struct MultiSetup {
        PortfolioVault vault;
        PortfolioHook hook;
        PoolKey poolKey;
        PoolId poolId;
    }

    function _deployMultiAllocationSetup(PortfolioVault.Allocation[] memory allocs)
        internal
        returns (MultiSetup memory ms)
    {
        ms.vault = new PortfolioVault(
            PortfolioVault.InitParams({
                initialOwner: owner,
                name: "Multi Allocation Portfolio",
                symbol: "maPORT",
                stable: usdcCurrency,
                poolManager: poolManager,
                instrumentRegistry: instrumentRegistry,
                swapPoolRegistry: swapPoolRegistry,
                strategy: IPortfolioStrategy(address(strategy)),
                allocations: allocs
            })
        );

        // Deploy hook at address with correct permission bits (different prefix from main hook)
        address multiHookAddr = address(uint160(0x2000000000000000000000000000000000000Ac8));
        deployCodeTo("PortfolioHook.sol:PortfolioHook", abi.encode(poolManager, ms.vault, usdcCurrency), multiHookAddr);
        ms.hook = PortfolioHook(multiHookAddr);

        vm.startPrank(owner);
        ms.vault.setHook(multiHookAddr);
        vm.stopPrank();

        // Create pool: USDC <> multiVault shares
        (Currency c0, Currency c1) = Currency.unwrap(usdcCurrency) < address(ms.vault)
            ? (usdcCurrency, Currency.wrap(address(ms.vault)))
            : (Currency.wrap(address(ms.vault)), usdcCurrency);

        ms.poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(multiHookAddr)});
        ms.poolId = ms.poolKey.toId();

        poolManager.initialize(ms.poolKey, Constants.SQRT_PRICE_1_1);
    }

    function _multiBuyZeroForOne(MultiSetup memory ms) internal view returns (bool) {
        return Currency.unwrap(ms.poolKey.currency0) == Currency.unwrap(usdcCurrency);
    }

    function _multiBuyShares(MultiSetup memory ms, uint256 amount, address recipient) internal returns (uint256) {
        uint256 sharesBefore = ms.vault.balanceOf(recipient);
        vm.prank(recipient);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: _multiBuyZeroForOne(ms),
            poolKey: ms.poolKey,
            hookData: abi.encode(recipient),
            receiver: recipient,
            deadline: block.timestamp + 1
        });
        return ms.vault.balanceOf(recipient) - sharesBefore;
    }

    function _multiSellShares(MultiSetup memory ms, uint256 shareAmount, address shareOwner)
        internal
        returns (uint256)
    {
        // Sell approvals for multi vault
        vm.startPrank(shareOwner);
        IERC20(address(ms.vault)).approve(address(permit2), type(uint256).max);
        IERC20(address(ms.vault)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(ms.vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        uint256 usdcBefore = IERC20(usdc).balanceOf(shareOwner);
        vm.prank(shareOwner);
        swapRouter.swapExactTokensForTokens({
            amountIn: shareAmount,
            amountOutMin: 0,
            zeroForOne: !_multiBuyZeroForOne(ms),
            poolKey: ms.poolKey,
            hookData: abi.encode(shareOwner),
            receiver: shareOwner,
            deadline: block.timestamp + 1
        });
        return IERC20(usdc).balanceOf(shareOwner) - usdcBefore;
    }

    /// @notice Full swap flow with Aave+Morpho 60/40 allocation — buy, verify NAV, sell roundtrip
    function test_fork_multiAllocation_buySellRoundtrip() public onlyFork {
        if (instruments.length < 2) return;

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 6000}); // 60% Aave
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 4000}); // 40% Morpho

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        // Buy through swap router
        uint256 shares = _multiBuyShares(ms, DEPOSIT_AMOUNT, user);
        assertGt(shares, 0, "multi-alloc buy should mint shares");

        // NAV should match deposit (both Aave and Morpho are USDC-based, near 1:1)
        uint256 nav = ms.vault.totalAssets();
        assertApproxEqRel(nav, DEPOSIT_AMOUNT, 2e16, "multi-alloc NAV should match deposit within 2%");

        // Sell all shares back
        uint256 returned = _multiSellShares(ms, shares, user);
        assertGe(returned, DEPOSIT_AMOUNT * 98 / 100, "multi-alloc roundtrip should preserve 98%+");
    }

    /// @notice Aave+Morpho 80/20 allocation — verify capital splits correctly
    function test_fork_multiAllocation_80_20_split() public onlyFork {
        if (instruments.length < 2) return;

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 8000}); // 80% Aave
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 2000}); // 20% Morpho

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        uint256 amount = 10_000e6; // 10k USDC
        deal(usdc, user, amount);
        _setupUserApprovals(user);

        uint256 shares = _multiBuyShares(ms, amount, user);
        assertGt(shares, 0, "80/20 buy should mint shares");

        uint256 nav = ms.vault.totalAssets();
        assertApproxEqRel(nav, amount, 2e16, "80/20 NAV should match deposit");

        // Sell roundtrip
        uint256 returned = _multiSellShares(ms, shares, user);
        assertGe(returned, amount * 98 / 100, "80/20 roundtrip should preserve 98%+");
    }

    /// @notice Large deposit (100k) with multi-allocation, then full withdrawal
    function test_fork_multiAllocation_largeAmount_100k() public onlyFork {
        if (instruments.length < 2) return;

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 5000}); // 50% Aave
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 5000}); // 50% Morpho

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        uint256 amount = 100_000e6;
        deal(usdc, user, amount);
        _setupUserApprovals(user);

        uint256 shares = _multiBuyShares(ms, amount, user);
        assertGt(shares, 0, "100k multi-alloc buy should work");

        uint256 nav = ms.vault.totalAssets();
        assertApproxEqRel(nav, amount, 2e16, "100k multi-alloc NAV should match");

        uint256 returned = _multiSellShares(ms, shares, user);
        assertGe(returned, amount * 98 / 100, "100k multi-alloc roundtrip");
    }

    /// @notice Multi-user buys and sells with multi-allocation vault
    function test_fork_multiAllocation_multiUser() public onlyFork {
        if (instruments.length < 2) return;

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 6000});
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 4000});

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        deal(usdc, user, DEPOSIT_AMOUNT);
        deal(usdc, user2, DEPOSIT_AMOUNT * 3);
        _setupUserApprovals(user);
        _setupUserApprovals(user2);

        uint256 shares1 = _multiBuyShares(ms, DEPOSIT_AMOUNT, user);
        uint256 shares2 = _multiBuyShares(ms, DEPOSIT_AMOUNT * 3, user2);

        assertGt(shares1, 0);
        assertGt(shares2, 0);
        assertApproxEqRel(shares2, shares1 * 3, 2e16, "3x deposit should give ~3x shares");

        // Both exit
        uint256 returned1 = _multiSellShares(ms, shares1, user);
        uint256 returned2 = _multiSellShares(ms, shares2, user2);

        assertGe(returned1, DEPOSIT_AMOUNT * 97 / 100, "user1 should recover 97%+");
        assertGe(returned2, DEPOSIT_AMOUNT * 3 * 97 / 100, "user2 should recover 97%+");
    }

    /// @notice Rebalance: start 60/40, change to 40/60, rebalance, verify NAV preserved
    function test_fork_multiAllocation_rebalance_weightShift() public onlyFork {
        if (instruments.length < 2) return;

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 6000});
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 4000});

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        uint256 amount = 10_000e6;
        deal(usdc, user, amount);
        _setupUserApprovals(user);

        uint256 shares = _multiBuyShares(ms, amount, user);
        uint256 navBefore = ms.vault.totalAssets();

        // Change allocations to 40/60
        PortfolioVault.Allocation[] memory newAllocs = new PortfolioVault.Allocation[](2);
        newAllocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 4000});
        newAllocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 6000});

        vm.startPrank(owner);
        ms.vault.setAllocations(newAllocs);
        ms.vault.rebalance();
        vm.stopPrank();

        uint256 navAfter = ms.vault.totalAssets();
        // NAV should be preserved within 2% (rebalance moves capital, small slippage/rounding)
        assertApproxEqRel(navAfter, navBefore, 2e16, "NAV preserved after rebalance");

        // User can still fully withdraw after rebalance
        uint256 returned = _multiSellShares(ms, shares, user);
        assertGe(returned, amount * 96 / 100, "user should recover 96%+ after rebalance");
    }

    /// @notice Full lifecycle: buy → yield accrual → rebalance → sell
    function test_fork_multiAllocation_fullLifecycle() public onlyFork {
        if (instruments.length < 2) return;

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 7000}); // 70% Aave
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 3000}); // 30% Morpho

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        // User1 buys
        deal(usdc, user, DEPOSIT_AMOUNT * 5);
        _setupUserApprovals(user);
        uint256 shares1 = _multiBuyShares(ms, DEPOSIT_AMOUNT * 5, user);

        // Time passes — yield accrues
        vm.warp(block.timestamp + 30 days);

        uint256 navAfterYield = ms.vault.totalAssets();
        assertGe(navAfterYield, DEPOSIT_AMOUNT * 5, "NAV should not decrease after yield");

        // User2 buys at higher NAV
        deal(usdc, user2, DEPOSIT_AMOUNT * 2);
        _setupUserApprovals(user2);
        uint256 shares2 = _multiBuyShares(ms, DEPOSIT_AMOUNT * 2, user2);

        // User2 should get fewer shares per USDC (higher share price)
        uint256 sharesPerUsdcUser1 = shares1 * 1e6 / (DEPOSIT_AMOUNT * 5);
        uint256 sharesPerUsdcUser2 = shares2 * 1e6 / (DEPOSIT_AMOUNT * 2);
        assertLe(sharesPerUsdcUser2, sharesPerUsdcUser1, "later buyer gets fewer shares per USDC");

        // Rebalance to 50/50
        PortfolioVault.Allocation[] memory newAllocs = new PortfolioVault.Allocation[](2);
        newAllocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 5000});
        newAllocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 5000});

        vm.startPrank(owner);
        ms.vault.setAllocations(newAllocs);
        ms.vault.rebalance();
        vm.stopPrank();

        // Both users exit — should recover their value
        uint256 returned1 = _multiSellShares(ms, shares1, user);
        uint256 returned2 = _multiSellShares(ms, shares2, user2);

        // User1 should profit from yield
        assertGe(returned1, DEPOSIT_AMOUNT * 5, "user1 should profit from yield");
        // User2 bought after yield, should recover near deposit (small rounding loss possible)
        assertGe(returned2, DEPOSIT_AMOUNT * 2 * 95 / 100, "user2 should recover 95%+");

        // Vault should be near empty
        assertLe(ms.vault.totalAssets(), 5000, "vault near empty after all exits");
    }

    /// @notice Three allocations: Aave + Morpho + Euler with rebalance
    function test_fork_threeAllocations_aaveMorphoEuler() public onlyFork {
        if (instruments.length < 3) return; // skip if Euler not registered

        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](3);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 4000}); // 40% Aave
        allocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 3000}); // 30% Morpho
        allocs[2] = PortfolioVault.Allocation({instrumentId: instruments[2].id, weightBps: 3000}); // 30% Euler

        MultiSetup memory ms = _deployMultiAllocationSetup(allocs);

        uint256 amount = 5_000e6;
        deal(usdc, user, amount);
        _setupUserApprovals(user);

        uint256 shares = _multiBuyShares(ms, amount, user);
        assertGt(shares, 0, "3-alloc buy should work");

        uint256 nav = ms.vault.totalAssets();
        assertApproxEqRel(nav, amount, 3e16, "3-alloc NAV should match deposit within 3%");

        // Rebalance to equal weights
        PortfolioVault.Allocation[] memory eqAllocs = new PortfolioVault.Allocation[](3);
        eqAllocs[0] = PortfolioVault.Allocation({instrumentId: instruments[0].id, weightBps: 3334});
        eqAllocs[1] = PortfolioVault.Allocation({instrumentId: instruments[1].id, weightBps: 3333});
        eqAllocs[2] = PortfolioVault.Allocation({instrumentId: instruments[2].id, weightBps: 3333});

        vm.startPrank(owner);
        ms.vault.setAllocations(eqAllocs);
        ms.vault.rebalance();
        vm.stopPrank();

        uint256 navAfterRebalance = ms.vault.totalAssets();
        assertApproxEqRel(navAfterRebalance, nav, 3e16, "NAV preserved after 3-alloc rebalance");

        // Full withdrawal
        uint256 returned = _multiSellShares(ms, shares, user);
        assertGe(returned, amount * 95 / 100, "3-alloc roundtrip should preserve 95%+");
    }

    // ============ Small Amount Fork Tests ============

    function test_fork_buy_smallAmount_1USDC() public onlyFork {
        uint256 smallAmount = 1e6;
        deal(usdc, user, smallAmount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(smallAmount, user);
        assertGt(shares, 0, "1 USDC buy should work on fork");
    }

    function test_fork_buy_smallAmount_10USDC() public onlyFork {
        uint256 amount = 10e6;
        deal(usdc, user, amount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(amount, user);
        uint256 returned = _sellShares(shares, user);
        assertGe(returned, amount - 3, "10 USDC roundtrip should preserve value");
    }

    // ============ Stress Test ============

    function test_fork_multipleBuysAndSells_10rounds() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT * 20);
        _setupUserApprovals(user);

        for (uint256 i = 0; i < 10; i++) {
            uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
            assertGt(shares, 0, "each buy should mint shares");

            uint256 returned = _sellShares(shares, user);
            assertGe(returned, DEPOSIT_AMOUNT * 99 / 100, "each roundtrip should preserve 99%+");
        }

        // PM may hold dead shares from last sell — these would be burned by next swap
        uint256 pmShares = vault.balanceOf(address(poolManager));
        assertLe(pmShares, vault.totalSupply(), "PM shares should be bounded");
    }
}
