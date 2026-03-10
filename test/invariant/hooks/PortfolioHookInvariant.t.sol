// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BaseHookTest} from "../../utils/BaseHookTest.sol";
import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";

contract PortfolioHookHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IUniswapV4Router04 public immutable swapRouter;
    IPoolManager public immutable poolManager;
    PortfolioHook public immutable hook;
    PortfolioVault public immutable vault;
    MockERC20 public immutable usdc;
    MockERC20 public immutable aUsdc;
    MockAavePool public immutable mockAavePool;
    PoolKey public poolKey;
    address public immutable user;

    uint256 public buyCalls;
    uint256 public sellCalls;
    uint256 public routeEvents;
    uint256 public navBuyRoutes;
    uint256 public ammBuyRoutes;
    uint256 public navSellRoutes;
    uint256 public ammSellRoutes;

    constructor(
        IUniswapV4Router04 _swapRouter,
        IPoolManager _poolManager,
        PortfolioHook _hook,
        PortfolioVault _vault,
        MockERC20 _usdc,
        MockERC20 _aUsdc,
        MockAavePool _mockAavePool,
        PoolKey memory _poolKey,
        address _user
    ) {
        swapRouter = _swapRouter;
        poolManager = _poolManager;
        hook = _hook;
        vault = _vault;
        usdc = _usdc;
        aUsdc = _aUsdc;
        mockAavePool = _mockAavePool;
        poolKey = _poolKey;
        user = _user;
    }

    function buy(uint96 rawAmount) external {
        uint256 amount = _boundLocal(rawAmount, 1e6, 2_000e6);

        usdc.mint(user, amount);

        vm.startPrank(user);
        vm.recordLogs();
        try swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: _buyZeroForOne(),
            poolKey: poolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        }) {
            buyCalls++;
            _captureRoute();
        } catch {}
        vm.stopPrank();
    }

    function sell(uint96 rawBps) external {
        uint256 bal = vault.balanceOf(user);
        if (bal == 0) return;

        uint256 bps = _boundLocal(rawBps, 1_000, 10_000);
        uint256 shares = (bal * bps) / 10_000;
        if (shares == 0) shares = 1;

        // Ensure there is enough base liquidity for withdraw path in mocks.
        usdc.mint(address(mockAavePool), 10_000e6);

        vm.startPrank(user);
        vm.recordLogs();
        try swapRouter.swapExactTokensForTokens({
            amountIn: shares,
            amountOutMin: 0,
            zeroForOne: !_buyZeroForOne(),
            poolKey: poolKey,
            hookData: abi.encode(user),
            receiver: user,
            deadline: block.timestamp + 1
        }) {
            sellCalls++;
            _captureRoute();
        } catch {}
        vm.stopPrank();
    }

    function _captureRoute() internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapRouted(address,bool,bool,uint256)");

        for (uint256 i = entries.length; i > 0; i--) {
            Vm.Log memory log = entries[i - 1];
            if (log.emitter == address(hook) && log.topics.length > 0 && log.topics[0] == sig) {
                (bool isBuy, bool usedAmm,) = abi.decode(log.data, (bool, bool, uint256));
                routeEvents++;
                if (isBuy) {
                    if (usedAmm) ammBuyRoutes++;
                    else navBuyRoutes++;
                } else {
                    if (usedAmm) ammSellRoutes++;
                    else navSellRoutes++;
                }
                return;
            }
        }
    }

    function _buyZeroForOne() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(usdc);
    }

    function _boundLocal(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

}

contract PortfolioHookInvariantTest is StdInvariant, BaseHookTest {
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

    PortfolioHookHandler public handler;

    uint256 public constant INITIAL_BALANCE = 1_000_000e6;

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
            address(new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner)))
        );

        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        swapPoolRegistry = SwapPoolRegistry(
            address(new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner)))
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
            name: "Invariant Portfolio",
            symbol: "iPORT",
            stable: usdcCurrency,
            poolManager: poolManager,
            instrumentRegistry: instrumentRegistry,
            swapPoolRegistry: swapPoolRegistry,
            allocations: allocs
        });

        vault = PortfolioVault(
            address(new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(PortfolioVault.initialize.selector, params)))
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

        portfolioPoolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        portfolioPoolId = portfolioPoolKey.toId();

        poolManager.initialize(portfolioPoolKey, Constants.SQRT_PRICE_1_1);

        usdc.mint(address(poolManager), INITIAL_BALANCE * 10);
        usdc.mint(user, INITIAL_BALANCE * 10);

        vm.startPrank(user);
        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        handler = new PortfolioHookHandler(
            swapRouter,
            IPoolManager(address(poolManager)),
            hook,
            vault,
            usdc,
            aUsdc,
            mockAavePool,
            portfolioPoolKey,
            user
        );

        targetContract(address(handler));
    }

    function invariant_totalSupplyGteUserAndPmBalances() public view {
        uint256 userBal = vault.balanceOf(user);
        uint256 pmBal = vault.balanceOf(address(poolManager));
        assertGe(vault.totalSupply(), userBal + pmBal);
    }

    function invariant_hookStableBalanceBoundedBySeed() public view {
        // Allow operational buffer from repeated withdraw-side over-withdraw and rounding.
        assertLe(usdc.balanceOf(address(hook)), hook.MIN_SEED_STABLE() + 10e6);
    }

    function invariant_hookDoesNotHoldShares() public view {
        assertEq(vault.balanceOf(address(hook)), 0);
    }

    function invariant_routeAccountingIsConsistent() public view {
        uint256 totalRouted = handler.navBuyRoutes() + handler.ammBuyRoutes() + handler.navSellRoutes() + handler.ammSellRoutes();
        assertEq(totalRouted, handler.routeEvents());
        assertEq(handler.routeEvents(), handler.buyCalls() + handler.sellCalls());
    }

    function invariant_sellRouteStaysAmmOnly() public view {
        assertEq(handler.navSellRoutes(), 0);
    }

    function _computeHookAddress() internal pure returns (address) {
        // beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta
        return address(uint160(0x1000000000000000000000000000000000000aC8));
    }
}
