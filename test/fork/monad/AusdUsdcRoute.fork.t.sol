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

/// @title AusdUsdcRouteForkTest
/// @notice Measures the Uniswap V4 AUSD/USDC route on Monad — the swap leg any AUSD-denominated
///         instrument would be entered and exited through.
///
/// @dev Monad has **no `swapPools` entries at all** and only `USDC` in its token map, so listing an
///      AUSD vault (Euler `eAUSD-16`: $10.44M, 8.18%, $1.02M available, `needs_swap_pool` and no
///      other flag) means adding the chain's first route. §5d constrains routing to Uniswap V4
///      only, so this pool is the entire path — there is no v3 or aggregator fallback to fall back
///      on. That makes its depth a listing precondition rather than an optimisation.
///
///      **The pool is not the one the vendor describes.** DeFiLlama lists this pair at "0.01%"
///      with $3.88M TVL. The initialised, liquid pool on-chain is **fee 50 (0.005%), tickSpacing
///      1**. Scanning the plausible tiers at FORK_BLOCK finds four initialised pools and exactly
///      one with liquidity:
///
///      | fee | tickSpacing | liquidity |
///      |---|---|---|
///      | 500 | 10 | 0 (tick pinned at 887271 — degenerate) |
///      | 10000 | 200 | 0 |
///      | 20 | 1 | 0 |
///      | **50** | **1** | **643_682_090_469_433** |
///
///      A `swapPools` entry written from the vendor's fee tier would point `SwapPoolRegistry` at
///      an empty pool, and every swap through it would fail or price catastrophically.
///      {test_onlyOneFeeTierHasLiquidity} is the guard.
///
///      Pinned to a block these numbers were measured against. Concentrated liquidity moves; do
///      not bump without re-measuring.
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc AusdUsdcRouteForkTest -vv
contract AusdUsdcRouteForkTest is Test {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 96_460_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";

    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    /// @dev Measured, not taken from the vendor label. See the table above.
    uint24 internal constant POOL_FEE = 50;
    int24 internal constant POOL_TICK_SPACING = 1;

    /// @dev Both tokens are 6-decimal, and AUSD sorts below USDC, so `currency0` is AUSD and a
    ///      USDC-in swap is `zeroForOne == false`.
    uint256 internal constant ONE = 1e6;

    /// @dev The reference size slippage is measured against — small enough that its own impact is
    ///      negligible, so the difference between its rate and a larger one is the depth cost.
    uint256 internal constant REFERENCE_SIZE = 1_000e6;

    /// @dev The ticket `screen/` sizes against, and the size this route has to clear for the
    ///      `eAUSD-16` listing to make sense.
    uint256 internal constant POSITION_SIZE = 250_000e6;

    /// @dev Ceiling for a round trip at POSITION_SIZE. **Measured: 8bps** — 1bp of fee (2 x 0.005%)
    ///      and ~7bps of spread and depth. Set at 25 rather than at the measurement, because
    ///      concentrated liquidity moves between blocks and a constant pinned to the exact reading
    ///      would fail on noise rather than on a real change. It is still tight enough to catch the
    ///      thing that matters: LPs leaving this pool. At 25bps a position repays the round trip in
    ///      ~11 days of 8.18%; at the measured 8bps, ~3 days.
    uint256 internal constant MAX_ROUND_TRIP_SLIPPAGE_BPS = 25;

    IPoolManager internal poolManager;
    V4Quoter internal quoter;
    PoolKey internal key;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        poolManager = IPoolManager(vm.readFile(CONFIG_PATH).readAddress(".networks.monadMainnet.uniswapV4.poolManager"));
        // Deployed here rather than looked up: v4-periphery's quoter is vendored in this repo, and
        // Monad has no canonical deployment recorded in config. It is a pure lens over PoolManager,
        // so a local instance quotes identically to any other.
        quoter = new V4Quoter(poolManager);

        key = PoolKey({
            currency0: Currency.wrap(AUSD),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev `zeroForOne == false` spends USDC (currency1) for AUSD (currency0).
    function _quoteUsdcToAusd(uint256 amountIn) internal returns (uint256 out) {
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: false, exactAmount: uint128(amountIn), hookData: ""
            })
        );
    }

    function _quoteAusdToUsdc(uint256 amountIn) internal returns (uint256 out) {
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: true, exactAmount: uint128(amountIn), hookData: ""
            })
        );
    }

    /// @dev Cost of a swap in basis points against the rate the reference size gets. This isolates
    ///      *depth* — the fee and the spot price are in both numbers and cancel out.
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
        assertApproxEqAbs(tick, int24(0), 50, "AUSD has depegged from USDC by more than ~0.5%");
    }

    /// @notice Four fee tiers are initialised for this pair and only one holds liquidity. A
    ///         `swapPools` entry written from DeFiLlama's "0.01%" label would point at an empty
    ///         pool. Fails if another tier ever becomes the venue, which is a config change.
    function test_onlyOneFeeTierHasLiquidity() public view {
        uint24[3] memory otherFees = [uint24(500), 10000, 20];
        int24[3] memory otherSpacings = [int24(10), 200, 1];

        for (uint256 i = 0; i < otherFees.length; i++) {
            PoolKey memory other = PoolKey({
                currency0: Currency.wrap(AUSD),
                currency1: Currency.wrap(USDC),
                fee: otherFees[i],
                tickSpacing: otherSpacings[i],
                hooks: IHooks(address(0))
            });
            assertEq(poolManager.getLiquidity(other.toId()), 0, "another fee tier gained liquidity: re-pick the route");
        }
        assertGt(poolManager.getLiquidity(key.toId()), 0, "the configured tier lost its liquidity");
    }

    // ============================================
    // Depth
    // ============================================

    /// @notice The measurement. Entry (USDC to AUSD) across the sizes an allocation would use.
    function test_depthEnteringAusd() public {
        uint256 refOut = _quoteUsdcToAusd(REFERENCE_SIZE);
        emit log_named_uint("reference $1k -> AUSD", refOut);

        uint256[6] memory sizes = [uint256(10_000e6), 50_000e6, 100_000e6, POSITION_SIZE, 500_000e6, 1_000_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 out = _quoteUsdcToAusd(sizes[i]);
            emit log_named_uint("USDC in", sizes[i] / ONE);
            emit log_named_uint("  AUSD out", out / ONE);
            emit log_named_uint("  slippage bps", _slippageBps(sizes[i], out, REFERENCE_SIZE, refOut));
        }
    }

    /// @notice And the exit (AUSD to USDC), which is the leg that matters under stress — an exit is
    ///         what a rebalance or a redemption needs, and it is the direction that will be
    ///         crowded when everyone wants it.
    function test_depthExitingAusd() public {
        uint256 refOut = _quoteAusdToUsdc(REFERENCE_SIZE);
        emit log_named_uint("reference $1k -> USDC", refOut);

        uint256[6] memory sizes = [uint256(10_000e6), 50_000e6, 100_000e6, POSITION_SIZE, 500_000e6, 1_000_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 out = _quoteAusdToUsdc(sizes[i]);
            emit log_named_uint("AUSD in", sizes[i] / ONE);
            emit log_named_uint("  USDC out", out / ONE);
            emit log_named_uint("  slippage bps", _slippageBps(sizes[i], out, REFERENCE_SIZE, refOut));
        }
    }

    /// @notice **The listing gate.** A full round trip at the intended ticket — in through the
    ///         route and straight back out — must cost less than the yield can repay in a
    ///         reasonable holding period. This is the assertion that decides whether the `eAUSD-16`
    ///         listing is worth the plumbing.
    function test_roundTripAtPositionSize() public {
        uint256 ausd = _quoteUsdcToAusd(POSITION_SIZE);
        uint256 back = _quoteAusdToUsdc(ausd);

        uint256 lossBps = back >= POSITION_SIZE ? 0 : ((POSITION_SIZE - back) * 10_000) / POSITION_SIZE;

        emit log_named_uint("USDC in", POSITION_SIZE / ONE);
        emit log_named_uint("AUSD held", ausd / ONE);
        emit log_named_uint("USDC back", back / ONE);
        emit log_named_uint("round trip loss bps", lossBps);
        emit log_named_uint("days of 8.18% APY to repay", (lossBps * 365) / 818);

        assertLe(lossBps, MAX_ROUND_TRIP_SLIPPAGE_BPS, "route too shallow at the intended ticket");
    }
}
