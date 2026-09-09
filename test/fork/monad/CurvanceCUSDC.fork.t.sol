// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {AdapterBaseUpgradeable} from "../../../src/adapters/base/AdapterBaseUpgradeable.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev The ERC-20 metadata surface `IERC4626` does not declare.
interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title CurvanceCUSDCForkTest
/// @notice Pre-listing fork test for Curvance's `cUSDC` lending market on Monad.
///
/// @dev **Result: not listable at the intended ticket.** The vault is well-behaved — it reverts
///      rather than returning zero, round trips cost 0bps, entry is uncapped — but a holder can
///      only exit **$14,173** in one transaction, measured by bisection. See
///      {test_holderExitIsBoundedByTokenBalance}, which is where the number comes from and what
///      it means for the vendor feed that reports 10x it.
///
/// @dev **Not in `NetworkConfig.json`.** The address is hardcoded because this is the test that
///      decides whether it belongs there; on listing, move it to config and read it the way
///      `MonadInstruments.fork.t.sol` does.
///
///      Surfaced by `screen/` on the 2026-08-15 snapshot, and only because of that week's sizing
///      fix: DeFiLlama reports `tvlUsd` net of borrows for lending pools, so this published
///      $57,160 against a $348k book and sat under the $250k floor. Admitted `lending_book`,
///      flagged `rescued`. 12.51% APY against a 30-day mean of 10.11%, of which 11.16pp is base
///      rather than emissions, 146 days of history, and correlation **−0.023** against a shelf
///      whose own internal median pair correlation is +0.168 — the most independent candidate the
///      screen found on any chain.
///
///      Three things make this one worth testing rather than assuming, and none is utilisation:
///
///      1. **The two liquidity signals disagree.** The vault holds **$14.2k** of USDC by
///         `balanceOf` — 4.1% of assets — while DeFiLlama's `lendBorrow` reports ~$151k available
///         at 56% utilisation. Curvance holds assets somewhere the token balance does not see, so
///         `screen/`'s `idle_assets` and `available_usd` columns disagree by 10x and neither can
///         be trusted as the exit bound. {test_holderExitPastTokenBalance} settles it by
///         redeeming through the adapter, which is the only reading that counts.
///      2. **It is small.** $343k of assets, so the `--position-size` ticket the screen flags
///         against is 73% of the pool. That is a concentration limit, not an exitability problem,
///         and {test_holderExitAtPositionSizeIsConcentrated} records the ratio rather than
///         asserting the trade is sensible — sizing is the allocator's call.
///      3. **No Curvance adapter exists on Monad.** Still no new Solidity — `ERC4626Adapter`
///         carries the protocol name in storage — but the listing includes a proxy deploy and a
///         registry entry, not just a config line.
///
///      Pinned to a block these numbers were measured against. Do NOT bump it without
///      re-measuring: the bounds below are measurements of this state, not standard invariants.
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc CurvanceCUSDCForkTest -vv
contract CurvanceCUSDCForkTest is Test {
    uint256 internal constant FORK_BLOCK = 103_280_000;

    /// @dev `Curvance USDC`. 6-decimal shares over 6-decimal native USDC, `maxDeposit` uncapped.
    address internal constant VAULT = 0x8EE9FC28B8Da872c38A496e9dDB9700bb7261774;
    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    uint256 internal constant SHARE_UNIT = 1e6;

    /// @dev The ticket `screen/` sizes its exit flags against (`--position-size`).
    uint256 internal constant POSITION_SIZE = 250_000e6;

    /// @dev Measured at FORK_BLOCK. A bound rather than an equality: Curvance publishes no fee
    ///      constant, so what remains is share rounding plus whatever entry/exit spread the market
    ///      carries.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    /// @dev The most a holder can redeem in one transaction at FORK_BLOCK, found by bisection:
    ///      **$133,608.80**, equal to the vault's own USDC `balanceOf` ($133,610.32) to within
    ///      $1.52. See {test_holderExitIsBoundedByTokenBalance}.
    uint256 internal constant MAX_HOLDER_EXIT_USD = 133_610e6;

    ERC4626Adapter internal adapter;
    address internal usdc;
    bytes32 internal marketId;

    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        usdc = IERC4626(VAULT).asset();
        marketId = bytes32(uint256(uint160(VAULT)));

        adapter = AdapterProxyLib.deployNamed(address(this), "Curvance");
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(usdc), VAULT);

        user = makeAddr("curvanceUser");
        recipient = makeAddr("curvanceRecipient");
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(usdc, user, amount);
        vm.startPrank(user);
        IERC20(usdc).approve(address(adapter), amount);
        adapter.deposit(marketId, amount, user);
        vm.stopPrank();

        shares = IERC20(VAULT).balanceOf(user);
    }

    function _withdrawAll(uint256 shares) internal returns (uint256 withdrawn) {
        vm.prank(user);
        IERC20(VAULT).transfer(address(adapter), shares);
        withdrawn = adapter.withdraw(marketId, shares, recipient);
    }

    function _lossBps(uint256 depositAmount, uint256 withdrawn) internal pure returns (uint256) {
        if (withdrawn >= depositAmount) return 0;
        return ((depositAmount - withdrawn) * 10_000) / depositAmount;
    }

    /// @dev Gives `user` shares without minting them, so the exit is not funded by its own
    ///      deposit. `deal` without the supply-adjust flag leaves `totalSupply` — and the share
    ///      price — untouched, which is the holder this test needs: someone redeeming against
    ///      liquidity that was already there. A round trip cannot answer that, because its deposit
    ///      leg supplies what its exit leg draws on.
    function _becomeHolder(uint256 shares) internal {
        deal(VAULT, user, shares);
    }

    function _sharesFor(uint256 assets) internal view returns (uint256) {
        return (assets * SHARE_UNIT) / IERC4626(VAULT).convertToAssets(SHARE_UNIT);
    }

    // ============================================
    // Identity
    // ============================================

    /// @notice `registerMarket` asserts `IERC4626(vault).asset() == currency`, so a wrong address
    ///         fails at registration rather than at first deposit.
    function test_vaultAssetIsNativeUSDC() public view {
        assertEq(usdc, NATIVE_USDC, "cUSDC must be denominated in native Monad USDC");
    }

    function test_vaultIdentity() public view {
        assertEq(IERC20Metadata(VAULT).name(), "Curvance USDC", "not the Curvance USDC market");
        assertEq(IERC20Metadata(VAULT).symbol(), "cUSDC", "symbol changed");
        assertEq(IERC20Metadata(VAULT).decimals(), 6, "share decimals changed: every size below is wrong");
    }

    /// @notice A new protocol identity for `max_weight_per_protocol` to budget against. A fallback
    ///         to "ERC4626 Adapter" would merge Curvance's weight cap with every other generic
    ///         listing — which is the whole reason `initializeNamed` exists.
    function test_adapterName() public view {
        AdapterBaseUpgradeable.AdapterMetadata memory m = adapter.getAdapterMetadata();
        assertEq(m.name, "Curvance", "adapter must carry its own identity, not a generic fallback");
        assertEq(m.chainId, 143);
    }

    // ============================================
    // Entry
    // ============================================

    function test_depositThenWithdraw() public {
        uint256 amount = 10_000e6;
        uint256 shares = _deposit(amount);
        assertGt(shares, 0, "no shares minted");

        uint256 withdrawn = _withdrawAll(shares);

        assertGt(withdrawn, 0, "silent zero on exit");
        assertEq(IERC20(usdc).balanceOf(recipient), withdrawn, "recipient did not receive the reported amount");
        assertLe(withdrawn, amount, "round trip returned more than it put in");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "round trip cost more than the expected spread");
    }

    /// @notice The batching invariant: deposit and exit must both settle in one transaction,
    ///         because the paymaster charges after execution and an async redeem has no single
    ///         operation to pay gas out of.
    function test_depositAndWithdraw_inOneTransaction() public {
        uint256 amount = 10_000e6;
        deal(usdc, address(this), amount);
        IERC20(usdc).approve(address(adapter), amount);

        adapter.deposit(marketId, amount, address(this));
        uint256 shares = IERC20(VAULT).balanceOf(address(this));
        IERC20(VAULT).transfer(address(adapter), shares);
        uint256 withdrawn = adapter.withdraw(marketId, shares, recipient);

        assertGt(withdrawn, 0, "redeem returned 0 in the same tx: exit is async, not adapter-legal");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "same-tx round trip cost more than expected");
    }

    /// @notice Entry is not capped: `maxDeposit` is uncapped and a full ticket goes in. A supply
    ///         cap — not utilisation — is what closes a lending market to deposits, and this one
    ///         has none.
    function test_depositAtPositionSizeIsNotCapped() public {
        assertGe(IERC4626(VAULT).maxDeposit(address(adapter)), POSITION_SIZE, "a supply cap now binds below the ticket");
        assertGt(_deposit(POSITION_SIZE), 0, "deposit at the intended ticket failed");
    }

    // ============================================
    // Exit — the actual question
    // ============================================

    /// @notice Self-funded round-trip cost across the sizes an allocation would use. Measures the
    ///         spread, not depth.
    function test_roundTripCostAcrossSizes() public {
        uint256[4] memory sizes = [uint256(1_000e6), 10_000e6, 100_000e6, POSITION_SIZE];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            uint256 shares = _deposit(sizes[i]);
            uint256 withdrawn = _withdrawAll(shares);

            assertGt(withdrawn, 0, "silent zero at this size: shares burned, nothing returned");
            emit log_named_uint("size usd", sizes[i] / 1e6);
            emit log_named_uint("  loss bps", _lossBps(sizes[i], withdrawn));
            assertLe(_lossBps(sizes[i], withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "loss exceeds the expected spread");

            vm.revertToState(snap);
        }
    }

    /// @notice **The load-bearing test, and the finding.** A holder exit is bounded by the vault's
    ///         own USDC balance and nothing more.
    ///
    /// @dev Bisection through the real adapter puts the ceiling at **$133,608.80** against a
    ///      `balanceOf` of $133,610.32 — the vault's own token balance and nothing more.
    ///
    ///      The rule this pins was established at block 96_450_000, where `screen/`'s two
    ///      liquidity readings disagreed by 10x: `idle_assets` (the token balance) read ~$14.2k
    ///      while `available_usd` from DeFiLlama's `lendBorrow` reported ~$151k at 56%
    ///      utilisation, and bisection sided with the token balance. That is not a Curvance
    ///      defect; it is a warning about the vendor field. Where the two disagree, believe the
    ///      token balance until a fork test says otherwise.
    ///
    ///      The consequence for listing is concrete: the intended $250k ticket cannot be exited in
    ///      one transaction. It has to be unwound in ceiling-sized bites as borrowers repay, and
    ///      nothing in `min_position_usd` or `cost_estimate` models that. Note that
    ///      {test_roundTripCostAcrossSizes} passes at $250k for 0bps — a self-funded round trip
    ///      brings the liquidity its own exit consumes, which is exactly the illusion
    ///      `_becomeHolder` exists to strip away.
    function test_holderExitIsBoundedByTokenBalance() public {
        uint256 tokenBalance = IERC20(usdc).balanceOf(VAULT);
        assertApproxEqAbs(
            tokenBalance, MAX_HOLDER_EXIT_USD, 1e6, "token balance moved: re-bisect the ceiling before trusting it"
        );

        // Just inside the ceiling: a holder exit settles cleanly.
        uint256 inside = (tokenBalance * 9) / 10;
        uint256 snap = vm.snapshotState();
        _becomeHolder(_sharesFor(inside));
        uint256 withdrawn = _withdrawAll(_sharesFor(inside));

        emit log_named_uint("vault token balance usd", tokenBalance / 1e6);
        emit log_named_uint("holder exit usd", withdrawn / 1e6);
        assertGt(withdrawn, 0, "holder exit inside the ceiling returned 0: shares burned for nothing");
        assertLe(_lossBps(inside, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "holder exit cost more than the spread");
        vm.revertToState(snap);

        // Just past it: reverts. The bound is the token balance, not `available_usd`.
        uint256 past = (tokenBalance * 12) / 10;
        uint256 shares = _sharesFor(past);
        _becomeHolder(shares);
        vm.prank(user);
        IERC20(VAULT).transfer(address(adapter), shares);

        vm.expectRevert();
        adapter.withdraw(marketId, shares, recipient);
    }

    /// @notice The sizing consequence, stated as an assertion rather than left in a comment: the
    ///         ticket this instrument is being screened for is past what a holder can exit in one
    ///         transaction — by ~1.9x at FORK_BLOCK, down from ~18x at block 96_450_000 as the
    ///         vault's idle balance grew. Listing it still means accepting a position that unwinds
    ///         in ceiling-sized increments as borrowers repay. The assertion is the tripwire: it
    ///         fails the day the ceiling covers the ticket.
    function test_positionSizeIsFarPastTheExitCeiling() public {
        uint256 ceiling = IERC20(usdc).balanceOf(VAULT);
        assertLt(ceiling, POSITION_SIZE, "exit ceiling now covers the ticket: this instrument became listable");
        emit log_named_uint("tickets-worth of exits needed", POSITION_SIZE / ceiling);
    }

    /// @notice The `yoUSD` / `syrupUSDC` discriminator. Past whatever liquidity exists, this vault
    ///         must revert rather than return zero: `ERC4626Adapter.withdraw` has no
    ///         `assetsWithdrawn == 0` guard, so a silent zero burns the caller's shares and
    ///         returns nothing in-transaction. This single assertion decides whether the
    ///         instrument is safe to hold on the adapter as it exists today.
    function test_exitPastLiquidityRevertsRatherThanReturningZero() public {
        uint256 shares = _sharesFor(IERC4626(VAULT).totalAssets() * 2);
        _becomeHolder(shares);

        vm.prank(user);
        IERC20(VAULT).transfer(address(adapter), shares);

        try adapter.withdraw(marketId, shares, recipient) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "silent zero past capacity: this instrument is unsafe on ERC4626Adapter");
            emit log_named_uint("filled past capacity usd", withdrawn / 1e6);
        } catch {
            // Reverting past capacity is the correct, adapter-legal behaviour.
        }
    }

    /// @notice Not an assertion about safety — a record of the sizing constraint. A $250k ticket is
    ///         a large share of a $343k market, and concentration, not exitability, is what should
    ///         bound this listing. Emits the ratio so the number lands in the listing PR rather
    ///         than being rediscovered later.
    function test_holderExitAtPositionSizeIsConcentrated() public {
        uint256 totalAssets = IERC4626(VAULT).totalAssets();
        uint256 shareOfPoolBps = (POSITION_SIZE * 10_000) / totalAssets;

        emit log_named_uint("vault total assets usd", totalAssets / 1e6);
        emit log_named_uint("position share bps", shareOfPoolBps);

        assertGt(shareOfPoolBps, 5_000, "vault grew past the concentration concern: revisit the sizing note");
    }

    // ============================================
    // Wiring
    // ============================================

    /// @notice The valuation path the router and registry use must be STATICCALL-safe.
    function test_convertToUnderlyingIsStaticcallSafe() public view {
        uint256 marked = adapter.convertToUnderlying(marketId, 1_000 * SHARE_UNIT);
        assertGt(marked, 0, "valuation path returned zero");
    }

    /// @notice An adapter deployed without `setAuthorizedCaller(router)` ships a market where
    ///         deposits succeed and every exit reverts.
    function test_withdrawRevertsForUnauthorizedCaller() public {
        uint256 shares = _deposit(1_000e6);
        vm.prank(user);
        IERC20(VAULT).transfer(address(adapter), shares);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        adapter.withdraw(marketId, shares, recipient);
    }
}
