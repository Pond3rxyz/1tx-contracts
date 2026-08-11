// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {AdapterBaseUpgradeable} from "../../../src/adapters/base/AdapterBaseUpgradeable.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev `baseUSD.previewRedeem` writes storage, so the ERC-4626 `view` declaration cannot be used
///      to reach it — Solidity emits STATICCALL for any function an interface marks `view`, and
///      the vault reverts `StateChangeDuringStaticCall`. This non-view redeclaration is what lets
///      the tests below observe the function's real behaviour. See
///      {test_previewRedeemIsNotStaticcallSafe} for why that quirk is harmless here.
interface ITokemakPreview {
    function previewRedeem(uint256 shares) external returns (uint256);
}

/// @title TokemakBaseUSDForkTest
/// @notice Fork tests for the Tokemak autopool `baseUSD` on Base.
/// @dev The vault address is read from `script/config/NetworkConfig.json`, the same source
///      `script/RegisterInstruments.s.sol` registers from.
///
///      `baseUSD` is an autopool: it routes deposits across "destinations" (LP positions) rather
///      than into a single lending market, so its return driver is DEX fees, not a borrow
///      utilisation curve. That makes it the second non-lending instrument on the shelf after
///      `avUSDC`, and it brings two behaviours no lending vault here has:
///
///      1. **Exits are bounded by destination liquidity.** Past that bound the vault reverts
///         `"insufficient liquidity"`. It does **not** return zero — which is what makes it
///         listable on `ERC4626Adapter` as that contract exists today, because `withdraw` has no
///         `assetsWithdrawn == 0` guard. `yoUSD` and Maple's `syrupUSDC` both return 0 past their
///         buffer instead of reverting, and against this adapter that burns the caller's shares
///         and returns nothing in-transaction. {test_exitAboveAvailableLiquidityReverts} is the
///         regression guard: if a Tokemak upgrade ever softened that revert into a zero return,
///         this instrument would become unsafe and that test is what catches it.
///      2. **`previewRedeem` is state-mutating**, in violation of ERC-4626. Harmless *only*
///         because `ERC4626Adapter` never calls it — it values positions through
///         `convertToAssets` and exits through `redeem`. Both of those are pinned below, so a
///         refactor that switched `convertToUnderlying` onto `previewRedeem` fails here rather
///         than in production, where every valuation of this instrument would revert.
///
///      Pinned to a block whose vault state these assertions were measured against. Do NOT bump it
///      without re-measuring: the loss bounds and the liquidity ceiling are measurements of this
///      state, not invariants of the ERC-4626 standard.
///
///      Run: BASE_RPC_URL=... forge test --mc TokemakBaseUSDForkTest -vv
contract TokemakBaseUSDForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 49_830_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant VAULT_PATH = ".networks.baseMainnet.protocols.tokemak.vaults.baseUSD";

    address internal constant NATIVE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Shares are 18-decimal; the asset (USDC) is 6-decimal.
    uint256 internal constant SHARE_UNIT = 1e18;

    /// @dev Worst observed round-trip cost at FORK_BLOCK, with headroom. Measured: 9bps at $1k,
    ///      8bps at $10k-$100k, 7bps at $1M, falling to 3bps at $8M — the cost *decreases* with
    ///      size because the deposit leg itself supplies the liquidity the exit leg then draws on.
    ///      Asserted as a bound rather than an equality: unlike Avantis' published 50bp
    ///      `collateralHealthFee`, this is autopool exit accounting and is not a protocol constant.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 15;

    /// @dev Shares that cannot be redeemed against the *unperturbed* vault at FORK_BLOCK. Found by
    ///      bisection: 3_645_490 shares quote, 3_645_491 revert — about $3.95M of a $4.90M vault
    ///      (~80.5%). Note this bound does not constrain a deposit-then-exit round trip, which
    ///      brings its own liquidity; it binds a holder exiting a position after others have drawn
    ///      the destinations down. `min_position_usd` has no notion of per-instrument exit
    ///      capacity, so this is a sizing caveat carried in the listing, not something the stack
    ///      currently enforces.
    uint256 internal constant ABOVE_CEILING_SHARES = 3_700_000 * SHARE_UNIT;
    uint256 internal constant BELOW_CEILING_SHARES = 3_000_000 * SHARE_UNIT;

    ERC4626Adapter internal adapter;
    address internal vault;
    address internal usdc;
    bytes32 internal marketId;

    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);

        vault = vm.readFile(CONFIG_PATH).readAddress(VAULT_PATH);
        usdc = IERC4626(vault).asset();
        marketId = bytes32(uint256(uint160(vault)));

        adapter = AdapterProxyLib.deployNamed(address(this), "Tokemak");
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(usdc), vault);

        user = makeAddr("tokemakUser");
        recipient = makeAddr("tokemakRecipient");
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(usdc, user, amount);
        vm.startPrank(user);
        IERC20(usdc).approve(address(adapter), amount);
        adapter.deposit(marketId, amount, user);
        vm.stopPrank();

        shares = IERC20(vault).balanceOf(user);
    }

    function _withdrawAll(uint256 shares) internal returns (uint256 withdrawn) {
        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);
        withdrawn = adapter.withdraw(marketId, shares, recipient);
    }

    function _lossBps(uint256 depositAmount, uint256 withdrawn) internal pure returns (uint256) {
        if (withdrawn >= depositAmount) return 0;
        return ((depositAmount - withdrawn) * 10_000) / depositAmount;
    }

    /// @notice `registerMarket` asserts `IERC4626(vault).asset() == currency`, so a wrong config
    ///         entry fails at registration rather than at first deposit. This pins that the
    ///         configured vault really is native-USDC denominated — no bridged variant, no wrapper.
    function test_vaultAssetIsNativeUSDC() public view {
        assertEq(usdc, NATIVE_USDC, "baseUSD must be denominated in native USDC");
    }

    /// @notice The adapter's own identity: what the API surfaces as the protocol, and what
    ///         `max_weight_per_protocol` budgets against. A fallback to "ERC4626 Adapter" would
    ///         silently merge Tokemak's weight cap with every other generic listing.
    function test_adapterName() public view {
        (string memory name, uint256 chainId) = _metadata();
        assertEq(name, "Tokemak", "adapter must not borrow another protocol's identity");
        assertEq(chainId, 8453);
    }

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

    /// @notice The batching invariant: a deposit and its exit must both settle inside one
    ///         transaction, because the paymaster charges after execution and an async redeem has
    ///         no single operation to pay gas out of. This is the check that disqualifies ERC-7540
    ///         vaults (`sUSDai`, every Centrifuge vault) and buffer-limited ones (`yoUSD`).
    function test_depositAndWithdraw_inOneTransaction() public {
        uint256 amount = 10_000e6;
        deal(usdc, address(this), amount);
        IERC20(usdc).approve(address(adapter), amount);

        // One call frame == one transaction.
        adapter.deposit(marketId, amount, address(this));
        uint256 shares = IERC20(vault).balanceOf(address(this));
        IERC20(vault).transfer(address(adapter), shares);
        uint256 withdrawn = adapter.withdraw(marketId, shares, recipient);

        assertGt(withdrawn, 0, "redeem returned 0 in the same tx: exit is async, not adapter-legal");
        assertLe(_lossBps(amount, withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "same-tx round trip cost more than expected");
    }

    /// @notice No depth cliff, no partial fill, and above all no silent zero — including at sizes
    ///         well past the vault's own TVL. The top size here is ~163% of `totalAssets`.
    function test_roundTripNeverReturnsZero() public {
        uint256[6] memory sizes = [uint256(1_000e6), 10_000e6, 100_000e6, 1_000_000e6, 4_000_000e6, 8_000_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            uint256 shares = _deposit(sizes[i]);
            uint256 withdrawn = _withdrawAll(shares);

            assertGt(withdrawn, 0, "silent zero at this size: shares burned, nothing returned");
            assertLe(_lossBps(sizes[i], withdrawn), MAX_ROUND_TRIP_LOSS_BPS, "loss exceeds the expected spread");

            vm.revertToState(snap);
        }
    }

    /// @notice **The load-bearing test.** Past its liquidity ceiling `baseUSD` must revert, not
    ///         return zero, because `ERC4626Adapter.withdraw` has no `assetsWithdrawn == 0` guard.
    ///         A zero return here is the `yoUSD` / `syrupUSDC` failure mode and would make this
    ///         instrument unsafe to list.
    function test_exitAboveAvailableLiquidityReverts() public {
        (bool ok, bytes memory ret) =
            vault.call(abi.encodeWithSelector(ITokemakPreview.previewRedeem.selector, ABOVE_CEILING_SHARES));

        assertFalse(ok, "expected a revert past the liquidity ceiling, not a return value");
        assertGt(ret.length, 0, "reverted without data: cannot distinguish capacity from failure");

        // Strip the Error(string) selector, then decode the payload rather than slicing it — the
        // string is zero-padded to a 32-byte word, so a raw slice carries trailing NULs.
        assertEq(bytes4(ret), bytes4(0x08c379a0), "expected a string revert reason");
        bytes memory payload = new bytes(ret.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = ret[i + 4];
        }
        assertEq(abi.decode(payload, (string)), "insufficient liquidity", "capacity bound changed shape");
    }

    /// @notice The other half of the ceiling: just under it the vault still quotes a real exit, so
    ///         the revert above is a genuine capacity bound and not a blanket failure.
    function test_exitBelowCeilingStillQuotes() public {
        uint256 realisable = ITokemakPreview(vault).previewRedeem(BELOW_CEILING_SHARES);
        assertGt(realisable, 0, "ceiling constants are stale: nothing redeems below the bound");
    }

    /// @notice The valuation path the router and registry actually use must be STATICCALL-safe.
    ///         `ERC4626Adapter.convertToUnderlying` is declared `view`, so if it ever moved onto a
    ///         state-mutating vault function every valuation of this instrument would revert.
    function test_convertToUnderlyingIsStaticcallSafe() public view {
        uint256 marked = adapter.convertToUnderlying(marketId, 1_000 * SHARE_UNIT);
        assertGt(marked, 0, "valuation path returned zero");
    }

    /// @notice Pins the ERC-4626 non-conformance rather than leaving it as folklore: `previewRedeem`
    ///         writes storage, so a STATICCALL to it reverts. This is why {ITokemakPreview}
    ///         redeclares it non-view, and why the adapter must keep valuing through
    ///         `convertToAssets`.
    function test_previewRedeemIsNotStaticcallSafe() public {
        (bool ok,) =
            vault.staticcall(abi.encodeWithSelector(ITokemakPreview.previewRedeem.selector, 1_000 * SHARE_UNIT));
        assertFalse(ok, "previewRedeem became view-safe: the adapter comment above is now stale");

        // The same call as a CALL succeeds, proving the revert is the static context, not the input.
        assertGt(ITokemakPreview(vault).previewRedeem(1_000 * SHARE_UNIT), 0, "previewRedeem broken outright");
    }

    /// @notice `convertToAssets` marks the position above what it realises, by the exit spread.
    ///         Every lending vault on the shelf has these two equal; the two non-lending ones
    ///         (`avUSDC`, `baseUSD`) do not, and the allocator's `cost_estimate` does not model it.
    function test_convertToUnderlyingOverstatesTheRealisableExit() public {
        uint256 shares = 1_000 * SHARE_UNIT;
        uint256 marked = adapter.convertToUnderlying(marketId, shares);
        uint256 realisable = ITokemakPreview(vault).previewRedeem(shares);

        assertGt(marked, realisable, "expected convertToAssets to sit above previewRedeem");
        assertLe(_lossBps(marked, realisable), MAX_ROUND_TRIP_LOSS_BPS, "valuation gap wider than the exit spread");
    }

    /// @notice An adapter deployed without `setAuthorizedCaller(router)` ships a market where
    ///         deposits succeed and every exit reverts. `RegisterInstruments.s.sol` asserts against
    ///         that state; this proves the failure it is guarding.
    function test_withdrawRevertsForUnauthorizedCaller() public {
        uint256 shares = _deposit(1_000e6);
        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        adapter.withdraw(marketId, shares, recipient);
    }

    function _metadata() internal view returns (string memory name, uint256 chainId) {
        AdapterBaseUpgradeable.AdapterMetadata memory m = adapter.getAdapterMetadata();
        return (m.name, m.chainId);
    }
}
