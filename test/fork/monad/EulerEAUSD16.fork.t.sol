// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
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

/// @dev The ERC-20 metadata surface `IERC4626` does not declare.
interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title EulerEAUSD16ForkTest
/// @notice Fork test for Euler `eAUSD-16` on Monad — the shelf's first AUSD-denominated
///         instrument, and the first that depends on a swap route to be reachable at all.
///
/// @dev The vault address is read from `script/config/NetworkConfig.json`, the same source
///      `RegisterInstruments.s.sol` registers from, so removing it from config fails this test.
///
///      Surfaced by `screen/` on the 2026-08-16 snapshot with a flag set of exactly
///      `["needs_swap_pool"]` and nothing else — the cleanest the screen has produced. $10.44M,
///      8.18% APY against a 30-day mean of 7.87% (so at trend, not a spike), of which 5.82pp is
///      base rather than emissions, APY coefficient of variation 0.21 over 97 days, and
///      correlation −0.017 against a shelf whose own internal median pair correlation is +0.168.
///
///      **Why this one and not the USDC vaults.** Three USDC candidates were fork-tested first and
///      two died: Harvest `fUSDC` greylists contract callers outright
///      (`test/fork/base/HarvestFUSDC.fork.t.sol`), and Curvance `cUSDC` caps a holder exit at
///      $14,173 (`test/fork/monad/CurvanceCUSDC.fork.t.sol`). The survivor, Euler `eUSDC-2` on
///      Arbitrum, has an $80k exit ceiling against a $250k ticket. This vault is the first with a
///      ceiling *above* the ticket: `cash()` was **$1,015,869** when screened, 4x cover.
///
///      What it costs is the route. Monad had no `swapPools` and only USDC in its token map, so
///      this listing adds the chain's first. Depth is measured separately and independently in
///      `test/fork/monad/AusdUsdcRoute.fork.t.sol` — 8bps round trip at $250k, and the liquid pool
///      is fee 50 / tickSpacing 1, not the "0.01%" DeFiLlama advertises.
///
///      Two risks this test cannot discharge, carried into the listing rather than resolved:
///      the route is a single Uniswap V4 pool with no fallback by §5d, and AUSD is an Agora
///      stablecoin, so the shelf takes issuer risk it holds nowhere else.
///
///      Pinned to a block these numbers were measured against. Do NOT bump it without
///      re-measuring: the bounds below are measurements of this state, not standard invariants.
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc EulerEAUSD16ForkTest -vv
contract EulerEAUSD16ForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 103_280_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant VAULT_PATH = ".networks.monadMainnet.protocols.eulerEarn.vaults.eAUSD16";
    string internal constant AUSD_PATH = ".networks.monadMainnet.tokens.AUSD";

    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    /// @dev Euler `eAUSD-20`, holding $2.10M of AUSD at FORK_BLOCK. Used only to fund test
    ///      accounts — see {_fund} for why `deal` cannot.
    address internal constant AUSD_WHALE = 0x0F9bA9d0f2F9289efBC2b8505932b458C3CDCf64;

    /// @dev Shares and asset are both 6-decimal.
    uint256 internal constant SHARE_UNIT = 1e6;

    /// @dev The ticket `screen/` sizes its exit flags against (`--position-size`).
    uint256 internal constant POSITION_SIZE = 250_000e6;

    /// @dev Measured at FORK_BLOCK. A bound rather than an equality — Euler's EVK charges no
    ///      deposit or withdraw fee here, so what remains is share rounding.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    EulerAdapter internal adapter;
    address internal vault;
    address internal asset;
    bytes32 internal marketId;

    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        vault = vm.readFile(CONFIG_PATH).readAddress(VAULT_PATH);
        asset = IERC4626(vault).asset();
        marketId = bytes32(uint256(uint160(vault)));

        adapter = AdapterProxyLib.deployEuler(address(this));
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(asset), vault);

        user = makeAddr("eausdUser");
        recipient = makeAddr("eausdRecipient");
    }

    /// @dev AUSD's balance storage defeats `deal` — `stdStorage` cannot locate the slot, so every
    ///      funded test fails with `checked_write: Failed to write value`. Funding by transfer from
    ///      a live holder instead, which is closer to reality anyway: the tokens are real and the
    ///      total supply is untouched.
    ///
    ///      The source is Euler `eAUSD-20`, a *different* vault holding $2.10M of AUSD at
    ///      FORK_BLOCK. Deliberately not `eAUSD-16` itself — draining the vault under test would
    ///      move the `cash()` bound every exit assertion below is measured against.
    function _fund(address to, uint256 amount) internal {
        require(IERC20(asset).balanceOf(AUSD_WHALE) >= amount, "AUSD source drained: pick another holder");
        vm.prank(AUSD_WHALE);
        IERC20(asset).transfer(to, amount);
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        vm.startPrank(user);
        IERC20(asset).approve(address(adapter), amount);
        adapter.deposit(marketId, amount, user);
        vm.stopPrank();

        shares = IERC20(vault).balanceOf(user);
    }

    function _withdrawAll(uint256 shares) internal returns (uint256 withdrawn) {
        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);
        withdrawn = adapter.withdraw(marketId, shares, recipient);
    }

    function _lossBps(uint256 amountIn, uint256 amountOut) internal pure returns (uint256) {
        if (amountOut >= amountIn) return 0;
        return ((amountIn - amountOut) * 10_000) / amountIn;
    }

    /// @dev Gives `user` shares without minting them, so the exit is not funded by its own deposit.
    ///      `deal` without the supply-adjust flag leaves `totalSupply` and the share price
    ///      untouched, which is the holder this test needs. A round trip cannot answer the exit
    ///      question, because its deposit leg supplies what its exit leg draws on — Curvance
    ///      `cUSDC` round-trips $250k at 0bps and caps a real holder at $14k.
    function _becomeHolder(uint256 shares) internal {
        deal(vault, user, shares);
    }

    function _sharesFor(uint256 assets) internal view returns (uint256) {
        return (assets * SHARE_UNIT) / IERC4626(vault).convertToAssets(SHARE_UNIT);
    }

    // ============================================
    // Identity
    // ============================================

    /// @notice **The asset is not USDC**, which is the whole reason this listing needs a swap
    ///         route. Pinned against the token map so a config edit that repoints either one
    ///         fails here rather than at first swap.
    function test_vaultAssetIsConfiguredAusd() public view {
        assertEq(asset, AUSD, "eAUSD-16 must be denominated in AUSD");
        assertEq(asset, vm.readFile(CONFIG_PATH).readAddress(AUSD_PATH), "config AUSD != the vault's asset");
        assertNotEq(asset, NATIVE_USDC, "asset became USDC: the swap route is now dead weight");
    }

    /// @notice Euler ships many same-shaped `eAUSD-N` vaults on Monad and DeFiLlama labels them all
    ///         `AUSD`; the screen found five. The suffix is the only thing distinguishing them, and
    ///         they differ sharply — `eAUSD-17` sits at 99.9% utilisation with $8,875 available
    ///         while this one had $1.02M. Matching on symbol rather than address is how §2b's
    ///         production bug shipped.
    function test_vaultIdentity() public view {
        assertEq(IERC20Metadata(vault).name(), "EVK Vault eAUSD-16", "not the eAUSD-16 vault");
        assertEq(IERC20Metadata(vault).decimals(), 6, "share decimals changed: every size below is wrong");
    }

    /// @notice What `max_weight_per_protocol` budgets against. `EulerAdapter` reports "Euler Earn"
    ///         and this is an EVK market, not an Earn aggregator vault — deliberate, so that both
    ///         Euler products draw on one protocol budget rather than two for one exposure. Same
    ///         argument the Morpho V1.1 listing recorded.
    function test_adapterName() public view {
        AdapterBaseUpgradeable.AdapterMetadata memory m = adapter.getAdapterMetadata();
        assertEq(m.name, "Euler Earn", "Euler identity changed: re-check the protocol weight budget");
        assertEq(m.chainId, 143);
    }

    // ============================================
    // Entry
    // ============================================

    /// @notice High utilisation is not an entry constraint — a deposit supplies the liquidity that
    ///         is scarce, and it is the one action utilisation never blocks. What closes a lending
    ///         market to deposits is a supply cap, and this vault's is far above the ticket.
    function test_depositAtPositionSizeIsNotCapped() public {
        uint256 utilisationBps = (IEulerVault(vault).totalBorrows() * 10_000) / IERC4626(vault).totalAssets();
        assertGt(utilisationBps, 5_000, "vault is no longer meaningfully utilised: this test lost its subject");
        assertGe(
            IERC4626(vault).maxDeposit(address(adapter)),
            POSITION_SIZE,
            "a supply cap now binds below the ticket: that, not utilisation, is the entry constraint"
        );

        assertGt(_deposit(POSITION_SIZE), 0, "deposit at the intended ticket failed");
    }

    // ============================================
    // Exit
    // ============================================

    function test_depositThenWithdraw() public {
        uint256 amount = 10_000e6;
        uint256 shares = _deposit(amount);
        assertGt(shares, 0, "no shares minted");

        uint256 withdrawn = _withdrawAll(shares);

        assertGt(withdrawn, 0, "silent zero on exit");
        assertEq(IERC20(asset).balanceOf(recipient), withdrawn, "recipient did not receive the reported amount");
        assertLe(withdrawn, amount, "round trip returned more than it put in");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "round trip cost more than the expected spread");
    }

    /// @notice The batching invariant: deposit and exit must both settle in one transaction,
    ///         because the paymaster charges after execution and an async redeem has no single
    ///         operation to pay gas out of.
    function test_depositAndWithdraw_inOneTransaction() public {
        uint256 amount = 10_000e6;
        _fund(address(this), amount);
        IERC20(asset).approve(address(adapter), amount);

        adapter.deposit(marketId, amount, address(this));
        uint256 shares = IERC20(vault).balanceOf(address(this));
        IERC20(vault).transfer(address(adapter), shares);
        uint256 withdrawn = adapter.withdraw(marketId, shares, recipient);

        assertGt(withdrawn, 0, "redeem returned 0 in the same tx: exit is async, not adapter-legal");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "same-tx round trip cost more than expected");
    }

    /// @notice Self-funded round-trip cost across the sizes an allocation would use. Measures the
    ///         spread, not depth.
    function test_roundTripCostAcrossSizes() public {
        uint256[5] memory sizes = [uint256(1_000e6), 10_000e6, 100_000e6, POSITION_SIZE, 500_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            uint256 shares = _deposit(sizes[i]);
            uint256 withdrawn = _withdrawAll(shares);

            assertGt(withdrawn, 0, "silent zero at this size: shares burned, nothing returned");
            emit log_named_uint("size", sizes[i] / SHARE_UNIT);
            emit log_named_uint("  loss bps", _lossBps(sizes[i], withdrawn));
            assertLe(_lossBps(sizes[i], withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "loss exceeds the expected spread");

            vm.revertToState(snap);
        }
    }

    /// @notice **The test that made this instrument the pick.** A holder who did not just deposit
    ///         exits the full intended ticket in one transaction. Every other candidate screened
    ///         failed exactly here — Curvance at $14k, Euler `eUSDC-2` at $80k, both against the
    ///         same $250k.
    function test_holderCanExitTheFullPositionSize() public {
        uint256 cash = IEulerVault(vault).cash();
        emit log_named_uint("cash usd", cash / SHARE_UNIT);
        assertGe(cash, POSITION_SIZE, "exit ceiling fell below the ticket: the listing case is gone");

        uint256 shares = _sharesFor(POSITION_SIZE);
        _becomeHolder(shares);
        uint256 withdrawn = _withdrawAll(shares);

        emit log_named_uint("holder exit usd", withdrawn / SHARE_UNIT);
        assertGt(withdrawn, 0, "holder exit returned 0: shares burned for nothing");
        assertLe(_lossBps(POSITION_SIZE, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "holder exit cost more than the spread");
    }

    /// @notice The `yoUSD` / `syrupUSDC` discriminator. Past `cash()` this vault must revert, not
    ///         return zero: `ERC4626Adapter.withdraw` has no `assetsWithdrawn == 0` guard, so a
    ///         silent zero burns the caller's shares and returns nothing in-transaction.
    function test_exitPastCashRevertsRatherThanReturningZero() public {
        uint256 shares = _sharesFor(IEulerVault(vault).cash() * 2);
        _becomeHolder(shares);

        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);

        try adapter.withdraw(marketId, shares, recipient) returns (uint256 withdrawn) {
            assertGt(withdrawn, 0, "silent zero past cash: this instrument is unsafe on ERC4626Adapter");
            emit log_named_uint("filled past cash usd", withdrawn / SHARE_UNIT);
        } catch {
            // Reverting past capacity is the correct, adapter-legal behaviour.
        }
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
        IERC20(vault).transfer(address(adapter), shares);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        adapter.withdraw(marketId, shares, recipient);
    }
}
