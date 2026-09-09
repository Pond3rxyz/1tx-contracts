// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

/// @title GhoUsdcRouteForkTest
/// @notice Measures the Uniswap V4 GHO/USDC route on Monad — the swap leg the Aave GHO instrument
///         is entered and exited through.
///
/// @dev Mirrors `test/fork/monad/AusdUsdcRoute.fork.t.sol`. `LoopRouteScan` already established
///      that GHO is *reachable*; a scan is not a guard, and a route with no pinned test is a route
///      that can move fee tier without failing anything. This is the guard.
///
///      §5d constrains routing to Uniswap V4, single hop, so this pool is the entire path — there
///      is no v3 leg and no aggregator to fall back on. Its depth is therefore a listing
///      precondition, not an optimisation.
///
///      **Only one tier exists at all.** Scanning the plausible tiers at FORK_BLOCK, eight of the
///      nine are not even initialised (`sqrtPriceX96 == 0`); the ninth is **fee 100 (0.01%),
///      tickSpacing 1** and holds `3_804_065_530_501_035_894_594` of liquidity. That is a
///      stronger statement than AUSD/USDC's, where four tiers were initialised and one was liquid,
///      and it is why {test_onlyOneFeeTierExists} asserts non-initialisation rather than
///      zero-liquidity.
///
///      **GHO is 18-decimal**, the first non-6dp instrument on the Monad shelf, so the pool sits
///      at tick ~276_335 rather than ~0: that is the 1e12 unit gap, not a depeg. Every conversion
///      below carries the scale explicitly for that reason.
///
///      Pinned to a block these numbers were measured against. Concentrated liquidity moves; do
///      not bump without re-measuring.
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc GhoUsdcRouteForkTest -vv
contract GhoUsdcRouteForkTest is Test {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 103_060_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";

    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant GHO = 0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73;

    /// @dev Measured, not taken from a vendor label. See the table in the docstring.
    uint24 internal constant POOL_FEE = 100;
    int24 internal constant POOL_TICK_SPACING = 1;

    /// @dev USDC sorts below GHO, so `currency0` is USDC and a USDC-in swap is `zeroForOne`.
    uint256 internal constant USDC_ONE = 1e6;
    uint256 internal constant GHO_ONE = 1e18;

    /// @dev The 1e12 gap between 6-decimal USDC and 18-decimal GHO. The pool's tick is ~276_335
    ///      because of this, not because either token has moved off a dollar.
    int24 internal constant DECIMAL_GAP_TICK = 276_335;

    /// @dev Reference size, small enough that its own impact is negligible — the difference
    ///      between its rate and a larger one is the depth cost.
    uint256 internal constant REFERENCE_SIZE = 1_000e6;

    /// @dev The ticket `screen/` sizes against.
    uint256 internal constant POSITION_SIZE = 250_000e6;

    /// @dev Ceiling for a round trip at POSITION_SIZE. **Measured: 3bps** — 2bps of it is the
    ///      2 x 0.01% fee, and depth cost rounds to nothing from $1k to $250k (2bps at $1M). Set at
    ///      25 rather than at the measurement, matching the AUSD route's reasoning: a constant
    ///      pinned to the exact reading fails on noise rather than on a real change, and 25bps
    ///      still catches the thing that matters, which is LPs leaving this pool. At 25bps a
    ///      position repays the round trip in ~15 days of 5.97%; at the measured 3bps, ~2 days.
    uint256 internal constant MAX_ROUND_TRIP_SLIPPAGE_BPS = 25;

    IPoolManager internal poolManager;
    V4Quoter internal quoter;
    PoolKey internal key;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        poolManager = IPoolManager(vm.readFile(CONFIG_PATH).readAddress(".networks.monadMainnet.uniswapV4.poolManager"));
        // Deployed rather than looked up: v4-periphery's quoter is vendored here and Monad has no
        // canonical deployment in config. It is a pure lens over PoolManager.
        quoter = new V4Quoter(poolManager);

        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(GHO),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev `zeroForOne == true` spends USDC (currency0) for GHO (currency1).
    function _quoteUsdcToGho(uint256 amountIn) internal returns (uint256 out) {
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: true, exactAmount: uint128(amountIn), hookData: ""
            })
        );
    }

    function _quoteGhoToUsdc(uint256 amountIn) internal returns (uint256 out) {
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: false, exactAmount: uint128(amountIn), hookData: ""
            })
        );
    }

    /// @dev Cost of a swap in basis points against the rate the reference size gets. Isolates
    ///      *depth* — the fee and the spot price are in both numbers and cancel out. Decimal-
    ///      agnostic: it only ever compares an out-amount against a scaled out-amount.
    function _slippageBps(uint256 amountIn, uint256 amountOut, uint256 refIn, uint256 refOut)
        internal
        pure
        returns (uint256)
    {
        uint256 expected = (amountIn * refOut) / refIn;
        if (amountOut >= expected) return 0;
        return ((expected - amountOut) * 10_000) / expected;
    }

    // ============================================
    // The pool is real, and it is the only one
    // ============================================

    function test_poolIsInitialisedAndLiquid() public view {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = poolManager.getLiquidity(key.toId());

        assertGt(sqrtPriceX96, 0, "pool not initialised at this fee tier");
        assertGt(liquidity, 0, "pool has no liquidity: the route is a hole");
        // Around the decimal gap, not around zero. 50 ticks is ~0.5%.
        assertApproxEqAbs(tick, DECIMAL_GAP_TICK, 50, "GHO has moved more than ~0.5% off USDC parity");
    }

    /// @notice Eight plausible tiers are not initialised at all; the ninth is the configured one.
    ///         Fails if another tier is ever opened, which is a decision, not a detail — the
    ///         `swapPools` entry would need re-measuring before it moved.
    function test_onlyOneFeeTierExists() public view {
        uint24[8] memory otherFees = [uint24(20), 50, 200, 500, 1000, 3000, 10000, 100];
        int24[8] memory otherSpacings = [int24(1), 1, 4, 10, 20, 60, 200, 2];

        for (uint256 i = 0; i < otherFees.length; i++) {
            PoolKey memory other = PoolKey({
                currency0: Currency.wrap(USDC),
                currency1: Currency.wrap(GHO),
                fee: otherFees[i],
                tickSpacing: otherSpacings[i],
                hooks: IHooks(address(0))
            });
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(other.toId());
            assertEq(sqrtPriceX96, 0, "another GHO/USDC tier was initialised: re-measure before re-pointing the route");
        }
        assertGt(poolManager.getLiquidity(key.toId()), 0, "the configured tier lost its liquidity");
    }

    /// @notice The route this test guards is the one config actually registers.
    /// @dev The failure this catches is a `swapPools` entry edited to a tier nobody measured —
    ///      `RegisterSwapPools` will happily register a `PoolKey` addressing an empty pool, since
    ///      a `PoolKey` is just five fields and the registry cannot tell.
    function test_configuredRouteMatchesTheMeasuredPool() public view {
        string memory config = vm.readFile(CONFIG_PATH);
        string memory poolsPath = ".networks.monadMainnet.swapPools";

        bool found;
        for (uint256 i = 0;; i++) {
            string memory entry = string.concat(poolsPath, "[", vm.toString(i), "]");
            if (!vm.keyExistsJson(config, string.concat(entry, ".tokenIn"))) break;

            string memory tokenIn = vm.parseJsonString(config, string.concat(entry, ".tokenIn"));
            string memory tokenOut = vm.parseJsonString(config, string.concat(entry, ".tokenOut"));
            if (keccak256(bytes(tokenOut)) != keccak256(bytes("GHO"))) continue;

            assertEq(tokenIn, "USDC", "the GHO route is not quoted against USDC");
            assertEq(
                vm.parseJsonUint(config, string.concat(entry, ".fee")),
                POOL_FEE,
                "configured fee tier is not the liquid one"
            );
            assertEq(
                vm.parseJsonUint(config, string.concat(entry, ".tickSpacing")),
                uint256(int256(POOL_TICK_SPACING)),
                "configured tickSpacing addresses a different pool"
            );
            assertEq(
                vm.parseJsonAddress(config, string.concat(entry, ".hooks")),
                address(0),
                "a hooked pool is a different pool entirely"
            );
            found = true;
        }
        assertTrue(found, "no USDC/GHO route in config: the GHO instrument would be unreachable");
    }

    // ============================================
    // Depth
    // ============================================

    /// @notice Entry (USDC to GHO) across the sizes an allocation would use.
    function test_depthEnteringGho() public {
        uint256 refOut = _quoteUsdcToGho(REFERENCE_SIZE);
        emit log_named_uint("reference $1k -> GHO", refOut / GHO_ONE);

        uint256[6] memory sizes = [uint256(10_000e6), 50_000e6, 100_000e6, POSITION_SIZE, 500_000e6, 1_000_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 out = _quoteUsdcToGho(sizes[i]);
            emit log_named_uint("USDC in", sizes[i] / USDC_ONE);
            emit log_named_uint("  GHO out", out / GHO_ONE);
            emit log_named_uint("  slippage bps", _slippageBps(sizes[i], out, REFERENCE_SIZE, refOut));
        }
    }

    /// @notice And the exit (GHO to USDC) — the leg that matters under stress, and the one that
    ///         will be crowded when everyone wants it.
    function test_depthExitingGho() public {
        uint256 refIn = 1_000e18;
        uint256 refOut = _quoteGhoToUsdc(refIn);
        emit log_named_uint("reference 1k GHO -> USDC", refOut / USDC_ONE);

        uint256[6] memory sizes = [uint256(10_000e18), 50_000e18, 100_000e18, 250_000e18, 500_000e18, 1_000_000e18];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 out = _quoteGhoToUsdc(sizes[i]);
            emit log_named_uint("GHO in", sizes[i] / GHO_ONE);
            emit log_named_uint("  USDC out", out / USDC_ONE);
            emit log_named_uint("  slippage bps", _slippageBps(sizes[i], out, refIn, refOut));
        }
    }

    /// @notice **The listing gate.** A full round trip at the intended ticket — in through the
    ///         route and straight back out — must cost less than the yield can repay in a
    ///         reasonable holding period.
    function test_roundTripAtPositionSize() public {
        uint256 gho = _quoteUsdcToGho(POSITION_SIZE);
        uint256 back = _quoteGhoToUsdc(gho);

        uint256 lossBps = back >= POSITION_SIZE ? 0 : ((POSITION_SIZE - back) * 10_000) / POSITION_SIZE;

        emit log_named_uint("USDC in", POSITION_SIZE / USDC_ONE);
        emit log_named_uint("GHO held", gho / GHO_ONE);
        emit log_named_uint("USDC back", back / USDC_ONE);
        emit log_named_uint("round trip loss bps", lossBps);
        emit log_named_uint("days of 5.97% APY to repay", (lossBps * 365) / 597);

        assertLe(lossBps, MAX_ROUND_TRIP_SLIPPAGE_BPS, "route too shallow at the intended ticket");
    }
}
