// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
import {ILendingAdapter} from "../../../src/interfaces/ILendingAdapter.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {IAavePool} from "../../../src/interfaces/IAavePool.sol";

/// @title SwapDepositRouterE2EArbitrumForkTest
/// @notice E2E fork tests for SwapDepositRouter on Arbitrum mainnet
contract SwapDepositRouterE2EArbitrumForkTest is AdapterForkTestBase {
    using stdJson for string;

    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    IPoolManager public poolManager;

    address public usdc;
    Currency public usdcCurrency;
    address public aaveExecAddr;
    address public morphoExecAddr;
    address public eulerExecAddr;

    AaveAdapter public aaveAdapter;
    MorphoAdapter public morphoAdapter;
    EulerAdapter public eulerAdapter;

    struct Instrument {
        bytes32 id;
        string name;
        address adapter;
        bytes32 marketId;
        bool requiresSwap;
    }

    Instrument[] public instruments;

    function setUp() public override {
        networkName = "arbitrumMainnet";
        super.setUp();

        aaveExecAddr = makeAddr("aaveExec");
        morphoExecAddr = makeAddr("morphoExec");
        eulerExecAddr = makeAddr("eulerExec");
        usdc = getToken("USDC");
        if (usdc == address(0)) return;
        usdcCurrency = Currency.wrap(usdc);

        poolManager = IPoolManager(json.readAddress(string.concat(networkPath, ".uniswapV4.poolManager")));

        _deployInfrastructure();
        _setupAave();
        _setupMorpho();
        _setupEuler();
    }

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

    function _setupAave() internal {
        address aavePool = getAavePool();
        if (aavePool == address(0)) return;

        aaveAdapter = new AaveAdapter(aavePool, address(this));
        aaveAdapter.addAuthorizedCaller(address(router));

        _tryRegisterAaveMarket("Aave-USDC", usdc, false);
        _tryRegisterAaveMarketWithSwap("Aave-USDT", "USDT");
        _tryRegisterAaveMarketWithSwap("Aave-DAI", "DAI");
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
        _registerInstrument(name, address(aaveAdapter), _computeMarketId(currency), true, aaveExecAddr);
        _registerSwapPool(token);
    }

    function _setupMorpho() internal {
        morphoAdapter = new MorphoAdapter(address(this));
        morphoAdapter.addAuthorizedCaller(address(router));

        _tryRegisterMorphoVault("Morpho-clearstarHighYieldUSDC", "clearstarHighYieldUSDC");
        _tryRegisterMorphoVault("Morpho-kpkUSDCYield", "kpkUSDCYield");
        _tryRegisterMorphoVault("Morpho-gauntletUSDCCore", "gauntletUSDCCore");
        _tryRegisterMorphoVault("Morpho-steakhousePrimeUSDC", "steakhousePrimeUSDC");
        _tryRegisterMorphoVault("Morpho-steakhouseHighYieldUSDC", "steakhouseHighYieldUSDC");
    }

    function _tryRegisterMorphoVault(string memory name, string memory vaultName) internal {
        address vault = getMorphoVault(vaultName);
        if (vault == address(0)) return;

        Currency currency = Currency.wrap(usdc);
        try morphoAdapter.registerVault(currency, vault) {
            _registerInstrument(name, address(morphoAdapter), _computeVaultMarketId(vault), false, morphoExecAddr);
        } catch {}
    }

    function _setupEuler() internal {
        eulerAdapter = new EulerAdapter(address(this));
        eulerAdapter.addAuthorizedCaller(address(router));

        address vault = getEulerVault("eeUSDC");
        if (vault == address(0)) return;

        Currency currency = Currency.wrap(usdc);
        try eulerAdapter.registerVault(currency, vault) {
            _registerInstrument("Euler-eeUSDC", address(eulerAdapter), _computeVaultMarketId(vault), false, eulerExecAddr);
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

    struct SwapPoolConfig {
        uint24 fee;
        address hooks;
        int24 tickSpacing;
        string tokenIn;
        string tokenOut;
    }

    function _registerSwapPool(address token) internal {
        Currency tokenCurrency = Currency.wrap(token);
        try swapPoolRegistry.getDefaultSwapPool(usdcCurrency, tokenCurrency) {
            return;
        } catch {}

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

    function _findTokenSymbol(address token) internal view returns (string memory) {
        string[3] memory symbols = ["USDC", "USDT", "DAI"];
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

    // ============ E2E Tests ============

    function test_fork_arb_e2e_buyAll_noSwap() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].requiresSwap) continue;
            _testBuy(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one instrument");
    }

    function test_fork_arb_e2e_buyAll_withSwap() public {
        for (uint256 i = 0; i < instruments.length; i++) {
            if (!instruments[i].requiresSwap) continue;
            _testBuy(instruments[i], DEPOSIT_AMOUNT);
        }
    }

    function test_fork_arb_e2e_roundtripAll_noSwap() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].requiresSwap) continue;
            _testRoundtrip(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one roundtrip");
    }

    function test_fork_arb_e2e_roundtripAll_withSwap() public {
        for (uint256 i = 0; i < instruments.length; i++) {
            if (!instruments[i].requiresSwap) continue;
            _testRoundtrip(instruments[i], DEPOSIT_AMOUNT);
        }
    }

    function test_fork_arb_e2e_multipleUsers() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _dealTokens(usdc, alice, 500e6);
        _approveTokens(usdc, alice, address(router), 500e6);
        vm.prank(alice);
        router.buy(inst.id, 500e6, 0, false, 0);

        _dealTokens(usdc, bob, 1500e6);
        _approveTokens(usdc, bob, address(router), 1500e6);
        vm.prank(bob);
        router.buy(inst.id, 1500e6, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        assertGt(_getBalance(yieldToken, alice), 0, "Alice should have yield tokens");
        assertGt(_getBalance(yieldToken, bob), 0, "Bob should have yield tokens");
    }

    function test_fork_arb_e2e_noTokensLeftInRouter() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        assertEq(_getBalance(usdc, address(router)), 0, "Router should not hold USDC");

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, user);
        _approveTokens(yieldToken, user, address(router), yieldBalance);
        vm.prank(user);
        router.sell(inst.id, yieldBalance, 0);

        assertEq(_getBalance(usdc, address(router)), 0, "Router should not hold USDC after sell");
    }

    // ============ E2E Tests: Slippage Protection ============

    function test_fork_arb_e2e_buy_noSwap_exactSlippage_passes() public {
        Instrument memory inst = _findInstrument(false);

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(inst.id, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, false, 0);
        assertEq(deposited, DEPOSIT_AMOUNT, "No-swap deposit should equal input exactly");
    }

    function test_fork_arb_e2e_buy_noSwap_tightSlippage_reverts() public {
        Instrument memory inst = _findInstrument(false);

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert();
        router.buy(inst.id, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1, false, 0);
    }

    function test_fork_arb_e2e_buy_withSwap_tightSlippage_reverts() public {
        if (!_hasInstrument(true)) return;
        Instrument memory inst = _findInstrument(true);

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert();
        router.buy(inst.id, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, false, 0);
    }

    function test_fork_arb_e2e_buy_withSwap_reasonableSlippage_passes() public {
        if (!_hasInstrument(true)) return;
        // First with-swap instrument is Aave-USDT (USD→USD stable swap)
        Instrument memory inst = _findInstrument(true);

        // 1% max slippage — production-realistic for stablecoin swaps
        uint256 minDeposited = DEPOSIT_AMOUNT * 99 / 100;

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(inst.id, DEPOSIT_AMOUNT, minDeposited, false, 0);
        assertGe(deposited, minDeposited, "Stable-to-stable swap should lose less than 1%");
    }

    function test_fork_arb_e2e_sell_tightSlippage_reverts() public {
        Instrument memory inst = _findInstrument(false);

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, user);
        _approveTokens(yieldToken, user, address(router), yieldBalance);

        vm.prank(user);
        vm.expectRevert();
        router.sell(inst.id, yieldBalance, DEPOSIT_AMOUNT * 2);
    }

    function test_fork_arb_e2e_sell_reasonableSlippage_passes() public {
        Instrument memory inst = _findInstrument(false);

        // Buy
        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        // Probe to discover actual sell output
        address probe = makeAddr("sell-probe");
        _dealTokens(usdc, probe, DEPOSIT_AMOUNT);
        _approveTokens(usdc, probe, address(router), DEPOSIT_AMOUNT);
        vm.prank(probe);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 probeYield = _getBalance(yieldToken, probe);
        _approveTokens(yieldToken, probe, address(router), probeYield);
        vm.prank(probe);
        uint256 actualOutput = router.sell(inst.id, probeYield, 0);

        // Sell with minOutputAmount = actual output
        uint256 userYield = _getBalance(yieldToken, user);
        _approveTokens(yieldToken, user, address(router), userYield);
        vm.prank(user);
        uint256 output = router.sell(inst.id, userYield, actualOutput);
        assertGe(output, actualOutput, "Should meet min when using actual output as threshold");
    }

    function _hasInstrument(bool requiresSwap) internal view returns (bool) {
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].requiresSwap == requiresSwap) return true;
        }
        return false;
    }

    function _findInstrument(bool requiresSwap) internal view returns (Instrument memory) {
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].requiresSwap == requiresSwap) return instruments[i];
        }
        revert("No matching instrument found");
    }

    // ============ Internal Helpers ============

    function _testBuy(Instrument memory inst, uint256 amount) internal {
        address testUser = makeAddr(string.concat("buyer-", inst.name));
        vm.deal(testUser, 1 ether);

        _dealTokens(usdc, testUser, amount);
        _approveTokens(usdc, testUser, address(router), amount);

        vm.prank(testUser);
        uint256 deposited = router.buy(inst.id, amount, 0, false, 0);

        if (!inst.requiresSwap) {
            assertEq(deposited, amount, string.concat("No-swap deposit should equal input for ", inst.name));
        } else {
            assertGt(deposited, 0, string.concat("With-swap deposit should be nonzero for ", inst.name));
        }

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        assertGt(_getBalance(yieldToken, testUser), 0, string.concat("No yield tokens for ", inst.name));
    }

    function _testRoundtrip(Instrument memory inst, uint256 amount) internal {
        address testUser = makeAddr(string.concat("rt-", inst.name));
        vm.deal(testUser, 1 ether);

        _dealTokens(usdc, testUser, amount);
        _approveTokens(usdc, testUser, address(router), amount);
        vm.prank(testUser);
        router.buy(inst.id, amount, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, testUser);
        _approveTokens(yieldToken, testUser, address(router), yieldBalance);
        vm.prank(testUser);
        uint256 output = router.sell(inst.id, yieldBalance, 0);

        assertGt(output, 0, string.concat("Sell returned 0 for ", inst.name));
        // Compare output USDC against input USDC (not deposited which may differ in decimals)
        if (!inst.requiresSwap) {
            assertGe(output, amount - 2, string.concat("Value loss for ", inst.name));
        } else {
            assertGt(output, amount * 90 / 100, string.concat("Excessive slippage for ", inst.name));
        }
    }
}
