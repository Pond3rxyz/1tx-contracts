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
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title AaveGHOForkTest
/// @notice Aave V3's GHO reserve on Monad — the first instrument added to the live Aave adapter
///         since the chain was deployed, and the shelf's first **18-decimal** instrument.
///
/// @dev GHO had no fork test at all, and it is the market being listed first. This holds it to the
///      `eAUSD-16` bar.
///
///      Why it is on the list (`notes/plan_loop.md` §1, from the 2026-09-08 `/lendBorrow`
///      snapshot): ltv 0.75 · supply 5.97% (2.96% base) · looped 10.99% at n=5 · rewards-off
///      **+1.08%** · book $38.72M · pool cash 4.89M GHO. It is the only one of the three that
///      still carries positive carry with rewards switched off, and the only one sizable at the
///      $250k ticket. This plan lists it **unlevered**; nothing here loops anything.
///
///      **Two things about this market that are not true of the rest of the shelf.**
///
///      1. *It is 18-decimal.* Every size in this file is `e18`. `AaveAdapter.convertToUnderlying`
///         is `pure` and returns its argument, which is correct for aTokens at any decimals — the
///         place a 6dp assumption could still hide is the swap leg, and that is
///         `test/fork/monad/GhoUsdcRoute.fork.t.sol`'s subject, not this file's.
///      2. *Aave's own AUSD reserve on this chain reports `ltv = 0`* — borrowable but never
///         collateral. That is why GHO rather than Aave AUSD is the Aave-side loop candidate;
///         `NeverlandAUSDForkTest.test_ausdReserveIsCollateralHere` records the contrast from the
///         other side.
///
///      Pinned to a block these numbers were measured against. Do not bump without re-measuring.
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc AaveGHOForkTest -vv
contract AaveGHOForkTest is Test {
    uint256 internal constant FORK_BLOCK = 103_060_000;

    /// @dev The pool the live Monad `AaveAdapter` (`0x451b9EBd…`) is initialized against.
    address internal constant POOL = 0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef;
    address internal constant GHO = 0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73;
    address internal constant A_MON_GHO = 0x4586face17B0e3D4d51EcABb4B4EBC2354b61b0D;

    /// @dev Aave's AUSD reserve on the same pool. Present only as the `ltv = 0` contrast below.
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    /// @dev **18 decimals.** Every size in this file is wrong if that changes, which is why
    ///      {test_ghoReserveIdentity} asserts it before anything else runs against a size.
    uint256 internal constant POSITION_SIZE = 250_000e18;

    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    uint256 internal constant EXPECTED_LTV_BPS = 7500;
    uint256 internal constant EXPECTED_LIQ_THRESHOLD_BPS = 7800;

    AaveAdapter internal adapter;
    bytes32 internal marketId;
    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        // The live Monad Aave adapter's shape: initialized through {AaveAdapter-initialize}, so it
        // reports the historical `"Aave V3"` identity from `_adapterName()`'s fallback. Deployed
        // fresh here rather than reused from config because `registerMarket` is `onlyOwner`.
        adapter = AdapterProxyLib.deployAave(POOL, address(this));
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(GHO));
        marketId = keccak256(abi.encode(Currency.wrap(GHO)));

        user = makeAddr("ghoUser");
        recipient = makeAddr("ghoRecipient");
    }

    function _lossBps(uint256 amountIn, uint256 amountOut) internal pure returns (uint256) {
        if (amountOut >= amountIn) return 0;
        return ((amountIn - amountOut) * 10_000) / amountIn;
    }

    // ============================================
    // Identity
    // ============================================

    /// @notice The reserve is live, usable as collateral, and shaped the way every size below
    ///         assumes. Read off the reserve configuration bitmap: LTV is bits 0-15 in basis
    ///         points, liquidation threshold bits 16-31, then the flag bits from 56.
    function test_ghoReserveIdentity() public {
        IAavePool.ReserveData memory d = IAavePool(POOL).getReserveData(GHO);
        uint256 cfg = d.configuration;

        assertEq(d.aTokenAddress, A_MON_GHO, "aToken moved: the reserve was re-listed");
        assertEq(cfg & 0xFFFF, EXPECTED_LTV_BPS, "ltv changed");
        assertEq((cfg >> 16) & 0xFFFF, EXPECTED_LIQ_THRESHOLD_BPS, "liquidation threshold changed");
        assertGt((cfg >> 16) & 0xFFFF, cfg & 0xFFFF, "liquidation threshold must exceed LTV");
        assertEq((cfg >> 48) & 0xFF, 18, "reserve decimals changed: every size in this file is wrong");

        assertTrue((cfg >> 56) & 1 == 1, "reserve is not active");
        assertTrue((cfg >> 57) & 1 == 0, "reserve is frozen: no new supply");
        assertTrue((cfg >> 58) & 1 == 1, "borrowing disabled: this is no longer a loop candidate");
        assertTrue((cfg >> 60) & 1 == 0, "reserve is paused");

        emit log_named_uint("ltv bps", cfg & 0xFFFF);
        emit log_named_uint("liquidation threshold bps", (cfg >> 16) & 0xFFFF);
    }

    /// @notice `aMonGHO` answers the aToken surface, and it is 18-decimal like its underlying.
    function test_aTokenIsAnAToken() public view {
        assertEq(IAToken(A_MON_GHO).UNDERLYING_ASSET_ADDRESS(), GHO, "aMonGHO is not GHO-denominated");
        assertEq(IAToken(A_MON_GHO).POOL(), POOL, "aMonGHO does not belong to the Aave V3 pool");
        assertGt(IAToken(A_MON_GHO).scaledTotalSupply(), 0, "no scaled supply: not a live aToken");
        assertEq(IERC20Metadata(A_MON_GHO).symbol(), "aMonGHO", "symbol changed: re-check which market this is");
        assertEq(IERC20Metadata(A_MON_GHO).decimals(), 18, "aToken decimals changed: every size below is wrong");
        assertEq(IERC20Metadata(GHO).decimals(), 18, "GHO decimals changed: every size below is wrong");
    }

    /// @notice `registerMarket` reads `getReserveData(asset).aTokenAddress` through the repo's own
    ///         `IAavePool`. That it resolves to `aMonGHO` is the proof the struct decodes here.
    function test_registerMarketResolvedTheRightAToken() public view {
        (, address yieldToken,) = adapter.markets(marketId);
        assertEq(yieldToken, A_MON_GHO, "adapter resolved a different aToken");
        assertEq(adapter.getYieldToken(marketId), A_MON_GHO, "yield token mismatch");
        assertTrue(adapter.hasMarket(marketId), "market did not register");
    }

    /// @notice This proxy takes the default init path, so it must still report `"Aave V3"` —
    ///         the same identity the live Monad proxy will keep reporting after its upgrade.
    function test_adapterStillReportsAaveV3() public view {
        assertEq(
            adapter.getAdapterMetadata().name,
            "Aave V3",
            "default identity moved: the live Aave proxies would be re-bucketed by an upgrade"
        );
    }

    /// @notice **Aave's AUSD on this chain cannot be collateral**, so it is not a substitute for
    ///         GHO however good its rate looks. Pinned here so the contrast is a measurement.
    function test_aaveAusdIsNotCollateralHere() public {
        IAavePool.ReserveData memory d = IAavePool(POOL).getReserveData(AUSD);
        emit log_named_uint("aave AUSD ltv bps", d.configuration & 0xFFFF);
        assertEq(d.configuration & 0xFFFF, 0, "Aave's AUSD gained an LTV: re-screen it as a loop candidate");
    }

    // ============================================
    // Entry and exit
    // ============================================

    /// @notice The exit ceiling, measured **before** anything of ours is supplied. For Aave,
    ///         `withdraw` pays out of the aToken's own underlying balance, so pool cash is the
    ///         bound — there is no per-vault buffer and no `cash()` to read. This is the honest
    ///         version of the funded-holder test here: the bound is a public balance that our own
    ///         deposit cannot flatter.
    function test_exitCeilingCoversPositionSize() public {
        uint256 available = IERC20(GHO).balanceOf(A_MON_GHO);
        emit log_named_uint("pool cash gho", available / 1e18);
        assertGe(available, POSITION_SIZE, "pool liquidity fell below the ticket");
    }

    function test_depositAtPositionSize() public {
        deal(GHO, user, POSITION_SIZE);

        vm.startPrank(user);
        IERC20(GHO).approve(address(adapter), POSITION_SIZE);
        adapter.deposit(marketId, POSITION_SIZE, user);
        vm.stopPrank();

        assertApproxEqAbs(IERC20(A_MON_GHO).balanceOf(user), POSITION_SIZE, 1, "aToken balance != supplied amount");
    }

    /// @notice Round-trip cost at the intended ticket. Measures the spread, not depth — depth is
    ///         {test_exitCeilingCoversPositionSize} above.
    function test_roundTripAtPositionSize() public {
        deal(GHO, user, POSITION_SIZE);

        vm.startPrank(user);
        IERC20(GHO).approve(address(adapter), POSITION_SIZE);
        adapter.deposit(marketId, POSITION_SIZE, user);
        IERC20(A_MON_GHO).transfer(address(adapter), IERC20(A_MON_GHO).balanceOf(user));
        vm.stopPrank();

        uint256 withdrawn = adapter.withdraw(marketId, IERC20(A_MON_GHO).balanceOf(address(adapter)), recipient);

        emit log_named_uint("round trip out gho", withdrawn / 1e18);
        assertGt(withdrawn, 0, "silent zero on exit");
        assertEq(IERC20(GHO).balanceOf(recipient), withdrawn, "recipient did not receive the reported amount");
        assertLe(_lossBps(POSITION_SIZE, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "round trip cost more than the spread");
    }

    /// @notice Deposit and exit must settle in one transaction — the paymaster charges after
    ///         execution.
    function test_depositAndWithdraw_inOneTransaction() public {
        uint256 amount = 10_000e18;
        deal(GHO, address(this), amount);
        IERC20(GHO).approve(address(adapter), amount);

        adapter.deposit(marketId, amount, address(this));
        IERC20(A_MON_GHO).transfer(address(adapter), IERC20(A_MON_GHO).balanceOf(address(this)));
        uint256 withdrawn = adapter.withdraw(marketId, IERC20(A_MON_GHO).balanceOf(address(adapter)), recipient);

        assertGt(withdrawn, 0, "redeem returned 0 in the same tx");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "same-tx round trip cost more than expected");
    }

    /// @notice The valuation path the router and registry use must be STATICCALL-safe. Probed at
    ///         one *whole* GHO, not `1e6` — the wrong unit reads exactly like a broken market.
    function test_convertToUnderlyingIsStaticcallSafe() public view {
        assertGt(adapter.convertToUnderlying(marketId, 1e18), 0, "valuation path returned zero");
    }
}
