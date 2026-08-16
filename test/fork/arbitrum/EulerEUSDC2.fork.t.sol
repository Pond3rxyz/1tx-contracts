// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {AdapterBaseUpgradeable} from "../../../src/adapters/base/AdapterBaseUpgradeable.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev Euler's EVK surface beyond ERC-4626. `cash()` is the balance actually held by the vault as
///      opposed to lent out, and it — not `totalAssets()` — is what bounds an exit.
interface IEulerVault {
    function cash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
}

/// @title EulerEUSDC2ForkTest
/// @notice Pre-listing fork test for Euler's `eUSDC-2` EVK vault on Arbitrum.
///
/// @dev **Not in `NetworkConfig.json`.** The address is hardcoded because this is the test that
///      decides whether it belongs there; on listing, move it to config and read it the way
///      `EulerAdapter.fork.t.sol` does, so `RegisterInstruments.s.sol` and this test share a
///      source.
///
///      Surfaced by `screen/` on the 2026-08-15 snapshot, and only because of that week's sizing
///      fix: DeFiLlama reports `tvlUsd` **net of borrows** for lending pools, so this vault
///      published $54,811 against a $397,022 book and sat under the $250k floor. It is admitted
///      `lending_book` and flagged `rescued`. 357 days of history, APY coefficient of variation
///      0.28, correlation +0.117 against a shelf whose own internal median pair correlation is
///      +0.168 — more independent of the book than the book is of itself.
///
///      The listing question here is **not** utilisation. At 71% this vault is doing what a
///      lending market is for, and a high utilisation is the mechanism of the supply rate rather
///      than a defect — it never blocks a deposit, and `maxDeposit` here is $149.6M. The question
///      is what a *holder* can get out, which `cash()` bounds directly and no APY screen can see.
///      {test_holderExitIsBoundedByCash} and {test_exitPastCashRevertsRatherThanReturningZero}
///      are the two that matter; the second is the `yoUSD` / `syrupUSDC` discriminator, because
///      `ERC4626Adapter.withdraw` has no `assetsWithdrawn == 0` guard and a silent zero would burn
///      the caller's shares for nothing.
///
///      Pinned to a block these numbers were measured against. Do NOT bump it without
///      re-measuring: the bounds below are measurements of this state, not standard invariants.
///
///      Run: ARBITRUM_RPC_URL=... forge test --mc EulerEUSDC2ForkTest -vv
contract EulerEUSDC2ForkTest is Test {
    uint256 internal constant FORK_BLOCK = 495_100_000;

    /// @dev `EVK Vault eUSDC-2`. 6-decimal shares over 6-decimal native USDC.
    address internal constant VAULT = 0x6aFB8d3F6D4A34e9cB2f217317f4dc8e05Aa673b;
    address internal constant NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant SHARE_UNIT = 1e6;

    /// @dev The ticket `screen/` sizes its exit flags against (`--position-size`). A round trip at
    ///      $1k proves nothing about the position actually intended.
    uint256 internal constant POSITION_SIZE = 250_000e6;

    /// @dev Measured at FORK_BLOCK. A bound rather than an equality — Euler's EVK charges no
    ///      deposit or withdraw fee on this vault, so what remains is share rounding, but that is
    ///      a property of this configuration and not of the standard.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    EulerAdapter internal adapter;
    address internal usdc;
    bytes32 internal marketId;

    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);

        usdc = IERC4626(VAULT).asset();
        marketId = bytes32(uint256(uint160(VAULT)));

        adapter = AdapterProxyLib.deployEuler(address(this));
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(usdc), VAULT);

        user = makeAddr("eulerUser");
        recipient = makeAddr("eulerRecipient");
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
    ///      deposit. `deal` without the supply-adjust flag leaves `totalSupply` — and therefore
    ///      the share price — untouched, which is the holder this test needs: someone redeeming
    ///      against liquidity that was already there. A deposit-then-exit round trip cannot
    ///      answer that, because the deposit leg supplies what the exit leg draws on.
    ///
    ///      This is the funded-holder simulation `screen/README.md` records as unreachable from
    ///      this repo's RPC credentials. It is reachable on a fork, and that is what this file is
    ///      for.
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
        assertEq(usdc, NATIVE_USDC, "eUSDC-2 must be denominated in native Arbitrum USDC");
    }

    /// @notice Euler ships many same-shaped `eUSDC-N` vaults on one chain and DeFiLlama labels
    ///         them all `USDC`. The suffix is the only thing distinguishing them, so it is pinned
    ///         to the address here.
    function test_vaultIdentity() public view {
        assertEq(IERC20Metadata(VAULT).name(), "EVK Vault eUSDC-2", "not the eUSDC-2 vault");
        assertEq(IERC20Metadata(VAULT).decimals(), 6, "share decimals changed: every size below is wrong");
    }

    /// @notice What `max_weight_per_protocol` budgets against — and a naming mismatch worth
    ///         stating rather than discovering later.
    ///
    /// @dev `EulerAdapter._adapterName()` returns **"Euler Earn"**, and the shelf's existing Euler
    ///      listings sit under a config block called `eulerEarn`. But Euler Earn and an EVK vault
    ///      are different products: Earn is an aggregator over markets, `eUSDC-2` *is* one of the
    ///      markets. Listing this instrument therefore files an EVK vault under an adapter named
    ///      for the aggregator.
    ///
    ///      That is the right call for budgeting, by the same argument the Morpho V1.1 listing
    ///      recorded: the adapter's name is the identity `max_weight_per_protocol` budgets
    ///      against, both products take Euler market risk, and splitting them would hand the
    ///      allocator two Euler budgets for one exposure. It is the wrong call for anyone reading
    ///      the API and expecting the name to describe the product. Pinned here so the decision is
    ///      explicit; if a separate EVK identity is ever wanted, this test is what fails.
    function test_adapterName() public view {
        AdapterBaseUpgradeable.AdapterMetadata memory m = adapter.getAdapterMetadata();
        assertEq(m.name, "Euler Earn", "Euler identity changed: re-check the protocol weight budget");
        assertEq(m.chainId, 42161);
    }

    // ============================================
    // Entry
    // ============================================

    /// @notice High utilisation is not an entry constraint — a deposit *supplies* the liquidity
    ///         that is scarce, and it is the one action utilisation never blocks. Pinned because
    ///         reading a 71% utilisation as "closed" gets the economics backwards; what closes a
    ///         lending market to deposits is a supply cap, and this vault's is $149.6M away.
    function test_depositIsNotConstrainedByUtilisation() public {
        uint256 utilisationBps = (IEulerVault(VAULT).totalBorrows() * 10_000) / IERC4626(VAULT).totalAssets();
        assertGt(utilisationBps, 5_000, "vault is no longer meaningfully utilised: this test lost its subject");
        assertGe(
            IERC4626(VAULT).maxDeposit(address(adapter)),
            POSITION_SIZE,
            "supply cap now binds below the intended ticket: that, not utilisation, is the entry constraint"
        );

        uint256 shares = _deposit(POSITION_SIZE);
        assertGt(shares, 0, "deposit at a fully-utilised vault failed");
    }

    // ============================================
    // Exit — the actual question
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

    /// @notice Self-funded round-trip cost across the sizes an allocation would use. This measures
    ///         the spread, not depth — the deposit leg supplies most of what the exit leg draws
    ///         on, so a pass here says nothing about a holder exiting.
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

    /// @notice **The load-bearing test.** A holder who did not just deposit exits against `cash()`
    ///         only. This is the number `screen/` reports as `available_usd` and the one the
    ///         `exit_buffer_below_position` flag is asking about — measured here through the real
    ///         adapter rather than inferred from a vendor feed.
    function test_holderExitIsBoundedByCash() public {
        uint256 cash = IEulerVault(VAULT).cash();
        assertGt(cash, 0, "vault holds no cash at this block: exit bound is zero, re-pin the block");

        // Exit a position sized to sit comfortably inside cash, so this isolates "does a
        // non-self-funded exit settle" from "is there enough liquidity".
        uint256 assets = cash / 2;
        uint256 shares = _sharesFor(assets);
        _becomeHolder(shares);

        uint256 withdrawn = _withdrawAll(shares);

        emit log_named_uint("cash usd", cash / 1e6);
        emit log_named_uint("holder exit usd", withdrawn / 1e6);
        assertGt(withdrawn, 0, "holder exit inside cash returned 0: shares burned for nothing");
        assertLe(_lossBps(assets, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "holder exit cost more than the spread");
    }

    /// @notice The `yoUSD` / `syrupUSDC` discriminator. Past available liquidity this vault must
    ///         revert, not return zero: `ERC4626Adapter.withdraw` has no `assetsWithdrawn == 0`
    ///         guard, so a silent zero burns the caller's shares and returns nothing
    ///         in-transaction. This is the single assertion that decides whether the instrument is
    ///         safe to hold on the adapter as it exists today.
    function test_exitPastCashRevertsRatherThanReturningZero() public {
        uint256 cash = IEulerVault(VAULT).cash();
        uint256 shares = _sharesFor(cash * 2);
        _becomeHolder(shares);

        vm.prank(user);
        IERC20(VAULT).transfer(address(adapter), shares);

        try adapter.withdraw(marketId, shares, recipient) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "silent zero past cash: this instrument is unsafe on ERC4626Adapter");
            // A partial fill that still returns value is acceptable; a zero is not.
            emit log_named_uint("filled past cash usd", withdrawn / 1e6);
        } catch {
            // Reverting past capacity is the correct, adapter-legal behaviour.
        }
    }

    /// @notice The sizing consequence, stated rather than left implicit: `cash()` is the exit
    ///         ceiling, and at this block it sits **below** the ticket the screen flags against.
    ///         A $250k holder exit would revert; a position that size unwinds in `cash()`-sized
    ///         increments as borrowers repay.
    ///
    /// @dev This is what `exit_buffer_below_position` was pointing at, now with a number on it.
    ///      It is a sizing bound, not a defect — the vault reverts cleanly and nothing is lost —
    ///      but `min_position_usd` has no notion of per-instrument exit capacity, so it is a
    ///      caveat the listing has to carry rather than something the stack enforces.
    function test_exitCeilingSitsBelowThePositionSize() public {
        uint256 cash = IEulerVault(VAULT).cash();
        emit log_named_uint("exit ceiling (cash) usd", cash / 1e6);
        emit log_named_uint("position size usd", POSITION_SIZE / 1e6);
        assertLt(cash, POSITION_SIZE, "cash now covers the ticket: the sizing caveat can be dropped");
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

/// @dev The ERC-20 metadata surface `IERC4626` does not declare.
interface IERC20Metadata {
    function name() external view returns (string memory);
    function decimals() external view returns (uint8);
}
