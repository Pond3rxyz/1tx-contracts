// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev Share decimals, which `IERC4626` here does not declare. Needed because share and asset
///      decimals differ on these vaults, and probing a conversion at the wrong unit reads as a
///      broken vault.
interface IVaultDecimals {
    function decimals() external view returns (uint8);
}

/// @dev Euler's vault surface beyond ERC-4626. `cash()` is the balance actually held by the vault
///      as opposed to lent out, and it — not `totalAssets()` — is what bounds an exit.
interface IEulerVault {
    function cash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
}

/// @title MonadInstrumentsForkTest
/// @notice Fork tests for every instrument `script/config/NetworkConfig.json` lists on Monad.
///
/// @dev The chain-onboarding checklist ends with "a fork test through the real adapter", on the
///      grounds that everything above it in the list is a view function and view functions are
///      what the near-misses all passed. This is that test for Monad, run before the chain is
///      deployed rather than after — none of these vaults had been exercised through
///      `ERC4626Adapter` when they were screened.
///
///      Vault addresses are read from config, the same source `RegisterInstruments.s.sol`
///      registers from, so adding a Monad vault to config without it surviving a round trip fails
///      here. Two traps this pins, both found on Monad specifically:
///
///      1. **Vault generation.** Morpho's V1 `hyperUSDCa` on Monad holds $23; the Vaults-V2
///         contract of the same name holds ~$58M. Querying the wrong GraphQL collection returns
///         the shell. {test_vaultsHoldRealAssets} is the guard — a shell fails the TVL floor.
///      2. **Utilisation.** Euler `eUSDC-12` advertises 14.57% precisely because it is 100%
///         utilised and nobody can exit. It is deliberately absent from config, and
///         {test_excludedEulerVaultIsStillUnexitable} documents why so the exclusion is not
///         quietly reverted by someone reading the APY.
///
///      Pinned to a block these numbers were measured against. Do NOT bump it without
///      re-measuring: the loss bounds are measurements of this state, not standard invariants.
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc MonadInstrumentsForkTest -vv
contract MonadInstrumentsForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 95_300_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant NET_PATH = ".networks.monadMainnet";

    /// @dev Verified live against rpc.monad.xyz.
    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    /// @dev Euler `eUSDC-12`: $1.43M borrowed against ~1 unit of cash. Not in config, asserted
    ///      unexitable below.
    address internal constant EXCLUDED_EULER_VAULT = 0x1905EDDF5943ef6C92Ccf1469bd40fC2cB4A77b0;

    /// @dev Round trips are deposit-then-exit, so the deposit leg supplies most of the liquidity
    ///      the exit leg draws on. What remains is share-rounding and any entry/exit spread. A
    ///      bound rather than an equality — none of these vaults publishes a fee constant.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    /// @dev DeFiLlama's Monad TVLs were $1.9M-$59M. A vault below this is a wrong-generation shell
    ///      (see the V1/V2 `hyperUSDCa` trap), not a small vault.
    uint256 internal constant MIN_CREDIBLE_TVL = 500_000e6;

    ERC4626Adapter internal adapter;
    address internal usdc;

    string internal config;
    string[] internal names;
    address[] internal vaults;

    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);

        config = vm.readFile(CONFIG_PATH);
        usdc = NATIVE_USDC;

        _loadVaults(".protocols.morpho.vaults");
        _loadVaults(".protocols.eulerEarn.vaults");
        assertGt(vaults.length, 0, "no Monad vaults in config");

        adapter = AdapterProxyLib.deployNamed(address(this), "Monad Test");
        adapter.setAuthorizedCaller(address(this), true);

        user = makeAddr("monadUser");
        recipient = makeAddr("monadRecipient");
    }

    /// @dev Mirrors `RegisterInstruments._vaultListPath`: enumerate the config keys rather than
    ///      naming vaults here, so a listing added to config is automatically covered.
    function _loadVaults(string memory listSuffix) internal {
        string memory listPath = string.concat(NET_PATH, listSuffix);
        if (!vm.keyExistsJson(config, listPath)) return;

        string[] memory keys = vm.parseJsonKeys(config, listPath);
        for (uint256 i = 0; i < keys.length; i++) {
            names.push(keys[i]);
            vaults.push(vm.parseJsonAddress(config, string.concat(listPath, ".", keys[i])));
        }
    }

    function _roundTrip(address vault, uint256 amount) internal returns (uint256 withdrawn) {
        bytes32 marketId = bytes32(uint256(uint160(vault)));
        if (!adapter.hasMarket(marketId)) {
            adapter.registerMarket(Currency.wrap(usdc), vault);
        }

        deal(usdc, user, amount);
        vm.startPrank(user);
        IERC20(usdc).approve(address(adapter), amount);
        adapter.deposit(marketId, amount, user);
        vm.stopPrank();

        uint256 shares = IERC20(vault).balanceOf(user);
        assertGt(shares, 0, "deposit minted no shares");

        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);
        withdrawn = adapter.withdraw(marketId, shares, recipient);
    }

    function _lossBps(uint256 deposited, uint256 withdrawn) internal pure returns (uint256) {
        if (withdrawn >= deposited) return 0;
        return ((deposited - withdrawn) * 10_000) / deposited;
    }

    // ============================================
    // Listability
    // ============================================

    /// @notice `registerMarket` asserts `IERC4626(vault).asset() == currency`, so a wrong config
    ///         entry fails at registration rather than at first deposit.
    function test_everyVaultIsDenominatedInNativeUSDC() public view {
        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(IERC4626(vaults[i]).asset(), NATIVE_USDC, string.concat("wrong asset: ", names[i]));
        }
    }

    /// @notice Guards the V1/V2 `hyperUSDCa` trap: same name, different contract, $23 vs $58M.
    function test_vaultsHoldRealAssets() public view {
        for (uint256 i = 0; i < vaults.length; i++) {
            assertGt(
                IERC4626(vaults[i]).totalAssets(),
                MIN_CREDIBLE_TVL,
                string.concat("vault looks like a wrong-generation shell: ", names[i])
            );
        }
    }

    /// @notice `convertToUnderlying` is how the router values a position, and it must survive a
    ///         STATICCALL. Tokemak's `baseUSD` fails this on `previewRedeem`; the check is cheap
    ///         and the failure mode — every valuation of the instrument reverting — is not.
    /// @dev The probe is one *share*, sized from the vault's own `decimals()`, not one USDC.
    ///      Morpho's V2 vaults here mint 18-decimal shares against a 6-decimal asset, so probing
    ///      at `1e6` converts to zero by rounding and reads exactly like a broken vault. That is
    ///      the same false positive that made Spark `sUSDC` look like a silent zero when it was
    ///      probed at `1e6` instead of `1e18`.
    function test_convertToUnderlyingIsStaticcallSafe() public {
        for (uint256 i = 0; i < vaults.length; i++) {
            bytes32 marketId = bytes32(uint256(uint160(vaults[i])));
            if (!adapter.hasMarket(marketId)) {
                adapter.registerMarket(Currency.wrap(usdc), vaults[i]);
            }

            uint256 oneShare = 10 ** IVaultDecimals(vaults[i]).decimals();
            (bool ok, bytes memory ret) =
                address(adapter).staticcall(abi.encodeCall(ERC4626Adapter.convertToUnderlying, (marketId, oneShare)));
            assertTrue(ok, string.concat("convertToUnderlying reverted under STATICCALL: ", names[i]));
            assertGt(abi.decode(ret, (uint256)), 0, string.concat("zero conversion rate: ", names[i]));
        }
    }

    // ============================================
    // Round trips through the real adapter
    // ============================================

    function test_roundTrip_1k() public {
        _assertRoundTripsAtSize(1_000e6);
    }

    function test_roundTrip_10k() public {
        _assertRoundTripsAtSize(10_000e6);
    }

    function test_roundTrip_100k() public {
        _assertRoundTripsAtSize(100_000e6);
    }

    /// @dev The one size that exceeds some of these vaults' own TVL. Kept separate so a failure
    ///      names the size rather than hiding inside a loop over all of them.
    function test_roundTrip_1m() public {
        _assertRoundTripsAtSize(1_000_000e6);
    }

    /// @notice The property that actually matters: an exit returns funds in-transaction, at every
    ///         size, for every listed vault.
    /// @dev `ERC4626Adapter.withdraw` has no `assetsWithdrawn == 0` guard, so a vault that returns
    ///      zero past a buffer — `yoUSD`, Maple `syrupUSDC` — burns the caller's shares and returns
    ///      nothing. Asserting non-zero here is what rules that failure mode out for Monad, and it
    ///      is the check a preview-only screen cannot make.
    function _assertRoundTripsAtSize(uint256 amount) internal {
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 withdrawn = _roundTrip(vaults[i], amount);

            assertGt(withdrawn, 0, string.concat("silent zero on exit: ", names[i]));
            assertLe(
                _lossBps(amount, withdrawn),
                MAX_ROUND_TRIP_LOSS_BPS,
                string.concat("round-trip loss above bound: ", names[i])
            );
        }
    }

    /// @notice `maxDeposit() == 0` does NOT mean a Morpho Vaults V2 vault is full.
    /// @dev The chain-onboarding checklist lists `maxDeposit()` as a rejection check, on the
    ///      strength of Accountable's `aHYPER` reporting 0 because it genuinely was full. Applied
    ///      literally that check rejects **every Morpho Vaults V2 instrument**, including the four
    ///      already live in production on Base — measured 2026-08-12: `steakhousePrimeUSDCV2` and
    ///      `gauntletUSDCPrimeV2` both report `maxDeposit == 0` while MetaMorpho V1.1
    ///      (`steakhouseUSDC`, `sparkUSDC`) and Euler Earn (`eeUSDC`) report real figures. All of
    ///      them accept deposits.
    ///
    ///      So the usable signal is `previewDeposit` plus an actual deposit, not `maxDeposit`.
    ///      This test pins both halves together — the zero *and* the working deposit — so that if
    ///      Morpho ever starts reporting a real cap, the surprise shows up here rather than in a
    ///      screen that silently drops the largest vault on the chain.
    function test_maxDepositZeroIsNotAFullVault() public {
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 maxDep = IERC4626(vaults[i]).maxDeposit(address(this));
            uint256 previewed = IERC4626(vaults[i]).previewDeposit(1e6);

            assertGt(previewed, 0, string.concat("previewDeposit is zero, entry really is shut: ", names[i]));

            // Whatever maxDeposit claims, a real deposit through the adapter must settle.
            uint256 withdrawn = _roundTrip(vaults[i], 10_000e6);
            assertGt(withdrawn, 0, string.concat("deposit path dead despite live preview: ", names[i]));

            if (maxDep == 0) {
                emit log_named_string("maxDeposit reports 0 but deposits work (Morpho V2)", names[i]);
            }
        }
    }

    // ============================================
    // The vault that is deliberately not listed
    // ============================================

    /// @notice Euler `eUSDC-12` is excluded from config because its 14.57% base rate exists
    ///         *because* the vault is fully utilised — `cash()` is a single unit against $1.43M
    ///         borrowed. A high APY on an unexitable vault is the shape this checklist exists to
    ///         catch, so the exclusion is pinned rather than left as a comment in a plan.
    function test_excludedEulerVaultIsStillUnexitable() public view {
        uint256 cash = IEulerVault(EXCLUDED_EULER_VAULT).cash();
        uint256 borrows = IEulerVault(EXCLUDED_EULER_VAULT).totalBorrows();

        assertGt(borrows, 0, "excluded vault has no borrows; re-screen it");
        assertLt(cash, 1_000e6, "excluded vault now holds cash; it may be listable, re-screen it");

        for (uint256 i = 0; i < vaults.length; i++) {
            assertTrue(vaults[i] != EXCLUDED_EULER_VAULT, "unexitable vault was added to config");
        }
    }
}
