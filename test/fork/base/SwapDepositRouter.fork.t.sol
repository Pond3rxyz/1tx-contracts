// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {SwapDepositRouter} from "../../../src/SwapDepositRouter.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {IAavePool} from "../../../src/interfaces/IAavePool.sol";

/// @title SwapDepositRouterForkTest
/// @notice Fork tests for SwapDepositRouter against Base mainnet (Uniswap V4 + Aave)
contract SwapDepositRouterForkTest is AdapterForkTestBase {
    using stdJson for string;

    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;
    IAavePool public aavePool;
    IPoolManager public poolManager;

    address public usdc;
    address public usdbc;
    Currency public usdcCurrency;
    Currency public usdbcCurrency;

    bytes32 public usdcInstrumentId;
    bytes32 public usdbcInstrumentId;
    bool public hasUsdbcMarket;

    address public executionAddress;

    function setUp() public override {
        super.setUp();

        executionAddress = makeAddr("executionAddress");

        usdc = getToken("USDC");
        usdbc = getToken("USDbC");
        if (usdc == address(0)) return;

        usdcCurrency = Currency.wrap(usdc);

        poolManager = IPoolManager(json.readAddress(string.concat(networkPath, ".uniswapV4.poolManager")));
        aavePool = IAavePool(getAavePool());

        // Deploy registries
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

        // Deploy Aave adapter & register USDC (always available)
        aaveAdapter = new AaveAdapter(address(aavePool), address(this));
        aaveAdapter.registerMarket(usdcCurrency);

        // Conditionally register USDbC if Aave supports it
        if (usdbc != address(0)) {
            IAavePool.ReserveData memory reserve = aavePool.getReserveData(usdbc);
            if (reserve.aTokenAddress != address(0)) {
                usdbcCurrency = Currency.wrap(usdbc);
                aaveAdapter.registerMarket(usdbcCurrency);
                hasUsdbcMarket = true;
            }
        }

        // Deploy router
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

        aaveAdapter.addAuthorizedCaller(address(router));

        // Register USDC instrument
        bytes32 usdcMarketId = _computeMarketId(usdcCurrency);
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));

        // Register USDbC instrument + swap pool if available
        if (hasUsdbcMarket) {
            bytes32 usdbcMarketId = _computeMarketId(usdbcCurrency);
            usdbcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdbcMarketId);
            instrumentRegistry.registerInstrument(executionAddress, usdbcMarketId, address(aaveAdapter));

            // USDC<>USDbC swap pool (from config: fee=100, tickSpacing=1)
            (Currency c0, Currency c1) = _order(usdcCurrency, usdbcCurrency);
            PoolKey memory poolKey =
                PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: int24(1), hooks: IHooks(address(0))});
            swapPoolRegistry.registerDefaultSwapPool(usdcCurrency, usdbcCurrency, poolKey);
            swapPoolRegistry.registerDefaultSwapPool(usdbcCurrency, usdcCurrency, poolKey);
        }
    }

    function _order(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    // ============ Buy — No Swap (USDC → aUSDC) ============

    function test_fork_buy_noSwap_usdc() public {
        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 0, address(0));

        assertEq(deposited, DEPOSIT_AMOUNT);
        address aToken = aaveAdapter.getYieldToken(_computeMarketId(usdcCurrency));
        assertGt(_getBalance(aToken, user), 0, "Should receive aUSDC");
    }

    // ============ Buy — With Swap (USDC → USDbC → aUSDbC) ============

    function test_fork_buy_withSwap_usdbc() public {
        if (!hasUsdbcMarket) return;

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(usdbcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 0, address(0));

        assertGt(deposited, 0, "Should deposit nonzero USDbC");
        address aToken = aaveAdapter.getYieldToken(_computeMarketId(usdbcCurrency));
        assertGt(_getBalance(aToken, user), 0, "Should receive aUSDbC");
    }

    // ============ Sell — No Swap (aUSDC → USDC) ============

    function test_fork_sell_noSwap_usdc() public {
        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 0, address(0));

        address aToken = aaveAdapter.getYieldToken(_computeMarketId(usdcCurrency));
        uint256 aTokenBalance = _getBalance(aToken, user);

        _approveTokens(aToken, user, address(router), aTokenBalance);

        uint256 usdcBefore = _getBalance(usdc, user);
        vm.prank(user);
        uint256 output = router.sell(usdcInstrumentId, aTokenBalance, 0, 0, address(0));

        assertGt(output, 0, "Should receive USDC");
        assertEq(_getBalance(usdc, user), usdcBefore + output);
    }

    // ============ Sell — With Swap (aUSDbC → USDbC → USDC) ============

    function test_fork_sell_withSwap_usdbc() public {
        if (!hasUsdbcMarket) return;

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(usdbcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 0, address(0));

        address aToken = aaveAdapter.getYieldToken(_computeMarketId(usdbcCurrency));
        uint256 aTokenBalance = _getBalance(aToken, user);

        _approveTokens(aToken, user, address(router), aTokenBalance);

        uint256 usdcBefore = _getBalance(usdc, user);
        vm.prank(user);
        uint256 output = router.sell(usdbcInstrumentId, aTokenBalance, 0, 0, address(0));

        assertGt(output, 0, "Should receive USDC");
        assertEq(_getBalance(usdc, user), usdcBefore + output);
    }

    // ============ Roundtrip ============

    function test_fork_buySell_roundtrip_noSwap() public {
        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(usdcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 0, address(0));

        address aToken = aaveAdapter.getYieldToken(_computeMarketId(usdcCurrency));
        uint256 aTokenBalance = _getBalance(aToken, user);

        _approveTokens(aToken, user, address(router), aTokenBalance);

        vm.prank(user);
        uint256 output = router.sell(usdcInstrumentId, aTokenBalance, 0, 0, address(0));

        assertGe(output, DEPOSIT_AMOUNT - 1, "Roundtrip should preserve value");
    }

    function test_fork_buySell_roundtrip_withSwap() public {
        if (!hasUsdbcMarket) return;

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        router.buy(usdbcInstrumentId, DEPOSIT_AMOUNT, 0, false, 0, 0, address(0));

        address aToken = aaveAdapter.getYieldToken(_computeMarketId(usdbcCurrency));
        uint256 aTokenBalance = _getBalance(aToken, user);

        _approveTokens(aToken, user, address(router), aTokenBalance);

        vm.prank(user);
        uint256 output = router.sell(usdbcInstrumentId, aTokenBalance, 0, 0, address(0));

        assertGt(output, 0, "Should get USDC back");
        assertGt(output, DEPOSIT_AMOUNT * 95 / 100, "Should lose less than 5% in fees/slippage");
    }
}
