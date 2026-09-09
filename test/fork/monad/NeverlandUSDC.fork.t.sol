// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {IAavePool} from "../../../src/interfaces/IAavePool.sol";

interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
    function scaledTotalSupply() external view returns (uint256);
}

interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title NeverlandUSDCForkTest
/// @notice Can the shelf hold Neverland's USDC market on Monad, and is it the loop candidate the
///         `darex` loop plan is looking for?
///
/// @dev Neverland is the **#2 loop candidate on any deployed chain** by the plan's own arithmetic
///      (`docs/plan_loop.md`, Phase 2), measured on the 2026-09-08 `/lendBorrow` snapshot:
///
///          ltv 0.85 · leverage 4.15x at n=5 · supply 9.60% · borrow 4.18%
///          looped 26.70% · unlevered 9.60% · rewards-off -14.26% · available $1.68M
///
///      It matters more than the #1 (Neverland USDT0, 31.44%) because it is **native USDC**: no
///      `SwapPoolRegistry` entry, no route. Monad's USDC/USDT0 v4 pools are empty — $1,000 in
///      quotes 0-84 out (`test/fork/monad/Usdt0RouteScan.fork.t.sol`) — so every USDT0 loop on
///      this chain is unreachable regardless of its APY.
///
///      **What this test establishes: Neverland is an Aave V3 fork, and `AaveAdapter` holds it
///      unchanged.** `nUSDC` answers the full aToken surface and the pool answers
///      `getReserveData` with a struct the repo's `IAavePool` decodes. So listing it is a second
///      `AaveAdapter` proxy — `AAVE_POOL` is per-proxy storage set at init, not a registrable
///      field — plus a `NetworkConfig` entry. The one Solidity change it needed,
///      `AaveAdapter.initializeNamed`, is in; see {test_adapterReportsItsOwnProtocolIdentity}.
///
///      **Two things this test does NOT establish.** It does not exercise the loop: the loop is
///      `supply`/`borrow` from the user's own Safe (`plan_loop.md`, Part A), which never touches
///      this adapter. And the 26.70% is **154% reward-dependent** — the base carry is -14.26%,
///      so the position is a bet on Neverland's emissions continuing and nothing else.
///
///      Run: MONAD_RPC_URL=... forge test --mc NeverlandUSDCForkTest -vv
contract NeverlandUSDCForkTest is Test {
    uint256 internal constant FORK_BLOCK = 103_060_000;

    address internal constant POOL = 0x80F00661b13CC5F6ccd3885bE7b4C9c67545D585;
    address internal constant N_USDC = 0x38648958836eA88b368b4ac23b86Ad44B0fe7508;
    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    /// @dev The pool the live Monad `AaveAdapter` (`0x451b9EBd…`) is initialized against. Pinned
    ///      so the "second proxy" claim below is a measurement rather than an assumption.
    address internal constant AAVE_V3_POOL_MONAD = 0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef;

    /// @dev The protocol identity this proxy reports, and the string `max_weight_per_protocol`
    ///      budgets against. Must match `protocols.neverland.adapter.name` in NetworkConfig.json.
    string internal constant ADAPTER_NAME = "Neverland";

    uint256 internal constant POSITION_SIZE = 250_000e6;
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    AaveAdapter internal adapter;
    bytes32 internal marketId;
    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        // The shape this market is actually listed in: its own proxy, carrying its own protocol
        // identity. `RegisterInstruments.s.sol` deploys it exactly this way.
        adapter = AdapterProxyLib.deployAaveNamed(POOL, address(this), ADAPTER_NAME);
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(NATIVE_USDC));
        marketId = keccak256(abi.encode(Currency.wrap(NATIVE_USDC)));

        user = makeAddr("neverlandUser");
        recipient = makeAddr("neverlandRecipient");
    }

    function _lossBps(uint256 amountIn, uint256 amountOut) internal pure returns (uint256) {
        if (amountOut >= amountIn) return 0;
        return ((amountIn - amountOut) * 10_000) / amountIn;
    }

    // ============================================
    // Identity — it really is an Aave V3 fork
    // ============================================

    /// @notice `nUSDC` answers the aToken surface, and the pool it names is Neverland's, not
    ///         Aave's. This is what makes `AaveAdapter` reusable here.
    function test_nUsdcIsAnAToken() public view {
        assertEq(IAToken(N_USDC).UNDERLYING_ASSET_ADDRESS(), NATIVE_USDC, "nUSDC is not USDC-denominated");
        assertEq(IAToken(N_USDC).POOL(), POOL, "nUSDC does not belong to the Neverland pool");
        assertGt(IAToken(N_USDC).scaledTotalSupply(), 0, "no scaled supply: not an Aave aToken");
        assertEq(IERC20Metadata(N_USDC).symbol(), "nUSDC", "symbol changed: re-check which market this is");
        assertEq(IERC20Metadata(N_USDC).decimals(), 6, "share decimals changed: every size below is wrong");
    }

    /// @notice `registerMarket` reads `getReserveData(asset).aTokenAddress` through the repo's own
    ///         `IAavePool`. That it resolves to `nUSDC` is the proof the struct layout matches —
    ///         a fork that reordered the reserve struct would silently return a wrong address.
    function test_registerMarketResolvedTheRightAToken() public view {
        (, address yieldToken,) = adapter.markets(marketId);
        assertEq(yieldToken, N_USDC, "adapter resolved a different aToken: the reserve struct diverged");
        assertEq(adapter.getYieldToken(marketId), N_USDC, "yield token mismatch");
        assertTrue(adapter.hasMarket(marketId), "market did not register");
    }

    /// @notice Neverland needs its **own** adapter proxy: `AAVE_POOL` is set once in `initialize`.
    ///         Pinned because the cheap-looking mistake is to register this market on the live
    ///         Aave adapter, where `marketId = keccak256(currency)` would collide with Aave's own
    ///         USDC market and silently repoint it.
    function test_neverlandIsADifferentPoolFromAave() public view {
        assertEq(address(adapter.AAVE_POOL()), POOL, "adapter is not pointed at Neverland");
        assertNotEq(POOL, AAVE_V3_POOL_MONAD, "Neverland and Aave now share a pool: this test lost its subject");
    }

    /// @notice Neverland is booked under **its own** protocol identity, not Aave's.
    ///
    /// @dev This was the one piece of Solidity the listing needed, and it is now in:
    ///      `AaveAdapter` had no `initializeNamed` path and `getAdapterMetadata()` returned the
    ///      literal `"Aave V3"`, so a second proxy pointed at Neverland reported itself as Aave
    ///      and `max_weight_per_protocol` would have budgeted Neverland exposure out of Aave's
    ///      bucket — two protocols, one risk budget, silently.
    ///
    ///      The predecessor of this test asserted the hardcoded name and was written to fail once
    ///      the fix landed. It has. What is pinned now is the property that replaced it: the name
    ///      is per-proxy, set once at init, with no setter.
    function test_adapterReportsItsOwnProtocolIdentity() public view {
        assertEq(
            adapter.getAdapterMetadata().name,
            ADAPTER_NAME,
            "Neverland proxy is reporting another protocol's identity: check initializeNamed"
        );
        assertEq(
            adapter.getAdapterMetadata().chainId,
            block.chainid,
            "chainId mismatch: registerInstrument would revert on this adapter"
        );
    }

    /// @notice The live Aave proxy is untouched by that change — it keeps reporting `"Aave V3"`.
    /// @dev The fallback in `_adapterName()`, exercised on the same chain the upgrade ships to.
    ///      Monad's live `AaveAdapter` was initialized before the name field existed, so its slot
    ///      is empty; a fresh proxy on the default path stands in for it here.
    function test_defaultInitPathStillReportsAaveV3() public {
        AaveAdapter unnamed = AdapterProxyLib.deployAave(AAVE_V3_POOL_MONAD, address(this));
        assertEq(
            unnamed.getAdapterMetadata().name,
            "Aave V3",
            "the default identity moved: live Aave proxies would be re-bucketed by an upgrade"
        );
    }

    // ============================================
    // Entry and exit
    // ============================================

    function test_depositAtPositionSize() public {
        deal(NATIVE_USDC, user, POSITION_SIZE);

        vm.startPrank(user);
        IERC20(NATIVE_USDC).approve(address(adapter), POSITION_SIZE);
        adapter.deposit(marketId, POSITION_SIZE, user);
        vm.stopPrank();

        assertApproxEqAbs(IERC20(N_USDC).balanceOf(user), POSITION_SIZE, 1, "aToken balance != supplied amount");
    }

    /// @notice The exit ceiling, measured **before** anything of ours is supplied. For an Aave
    ///         fork `withdraw` pays out of the aToken's own underlying balance, so pool cash is
    ///         the bound — there is no per-vault buffer to reason about and no `cash()` to read.
    ///         This is the honest version of the funded-holder test here: unlike an ERC-4626
    ///         vault, the bound is a public balance that our own deposit cannot flatter.
    function test_exitCeilingCoversPositionSize() public view {
        uint256 available = IERC20(NATIVE_USDC).balanceOf(N_USDC);
        assertGe(available, POSITION_SIZE, "pool liquidity fell below the ticket");
    }

    /// @notice Round-trip cost at the intended ticket. Measures the spread, not depth — the depth
    ///         question is answered by {test_exitCeilingCoversPositionSize} above.
    function test_roundTripAtPositionSize() public {
        uint256 availableBefore = IERC20(NATIVE_USDC).balanceOf(N_USDC);
        emit log_named_uint("pool available usd", availableBefore / 1e6);

        deal(NATIVE_USDC, user, POSITION_SIZE);
        vm.startPrank(user);
        IERC20(NATIVE_USDC).approve(address(adapter), POSITION_SIZE);
        adapter.deposit(marketId, POSITION_SIZE, user);
        IERC20(N_USDC).transfer(address(adapter), IERC20(N_USDC).balanceOf(user));
        vm.stopPrank();

        uint256 withdrawn = adapter.withdraw(marketId, IERC20(N_USDC).balanceOf(address(adapter)), recipient);

        emit log_named_uint("round trip out usd", withdrawn / 1e6);
        assertGt(withdrawn, 0, "silent zero on exit");
        assertEq(IERC20(NATIVE_USDC).balanceOf(recipient), withdrawn, "recipient did not receive the reported amount");
        assertLe(_lossBps(POSITION_SIZE, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "round trip cost more than the spread");
    }

    /// @notice Deposit and exit must settle in one transaction — the paymaster charges after
    ///         execution.
    function test_depositAndWithdraw_inOneTransaction() public {
        uint256 amount = 10_000e6;
        deal(NATIVE_USDC, address(this), amount);
        IERC20(NATIVE_USDC).approve(address(adapter), amount);

        adapter.deposit(marketId, amount, address(this));
        IERC20(N_USDC).transfer(address(adapter), IERC20(N_USDC).balanceOf(address(this)));
        uint256 withdrawn = adapter.withdraw(marketId, IERC20(N_USDC).balanceOf(address(adapter)), recipient);

        assertGt(withdrawn, 0, "redeem returned 0 in the same tx");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "same-tx round trip cost more than expected");
    }

    /// @notice The valuation path the router and registry use must be STATICCALL-safe.
    function test_convertToUnderlyingIsStaticcallSafe() public view {
        assertGt(adapter.convertToUnderlying(marketId, 1_000e6), 0, "valuation path returned zero");
    }

    // ============================================
    // The loop precondition
    // ============================================

    /// @notice What makes this a loop candidate rather than just another supply market: the USDC
    ///         reserve is borrowable and carries a non-zero LTV, which is exactly what
    ///         `plan_loop.md` Phase 2 filters on. Read off the reserve configuration bitmap —
    ///         LTV is bits 0-15 in basis points, liquidation threshold bits 16-31.
    function test_usdcReserveIsBorrowableWithLtv() public {
        IAavePool.ReserveData memory d = IAavePool(POOL).getReserveData(NATIVE_USDC);
        uint256 ltvBps = d.configuration & 0xFFFF;
        uint256 liqThresholdBps = (d.configuration >> 16) & 0xFFFF;

        emit log_named_uint("ltv bps", ltvBps);
        emit log_named_uint("liquidation threshold bps", liqThresholdBps);

        assertGt(ltvBps, 0, "USDC reserve has no LTV: it cannot be looped");
        assertGt(liqThresholdBps, ltvBps, "liquidation threshold must exceed LTV or entry is instantly liquidatable");
    }
}
