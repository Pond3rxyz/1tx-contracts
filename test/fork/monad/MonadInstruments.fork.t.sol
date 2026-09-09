// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";
import {IAavePool} from "../../../src/interfaces/IAavePool.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";

/// @dev Share decimals, which `IERC4626` here does not declare. Needed because share and asset
///      decimals differ on these vaults, and probing a conversion at the wrong unit reads as a
///      broken vault.
interface IVaultDecimals {
    function decimals() external view returns (uint8);
}

/// @dev The aToken surface an Aave-shaped reserve exposes. `POOL()` is what proves a reserve
///      belongs to the pool config claims it does, rather than to the other Aave-shaped pool on
///      the same chain.
interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
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

    uint256 internal constant FORK_BLOCK = 103_280_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant NET_PATH = ".networks.monadMainnet";

    /// @dev Verified live against rpc.monad.xyz.
    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    /// @dev Euler `eUSDC-12`: borrowed against to the hilt. Not in config, asserted unexitable
    ///      below.
    address internal constant EXCLUDED_EULER_VAULT = 0x1905EDDF5943ef6C92Ccf1469bd40fC2cB4A77b0;

    /// @dev Round trips are deposit-then-exit, so the deposit leg supplies most of the liquidity
    ///      the exit leg draws on. What remains is share-rounding and any entry/exit spread. A
    ///      bound rather than an equality — none of these vaults publishes a fee constant.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    /// @dev DeFiLlama's Monad TVLs were $1.9M-$59M. A vault below this is a wrong-generation shell
    ///      (see the V1/V2 `hyperUSDCa` trap), not a small vault.
    uint256 internal constant MIN_CREDIBLE_TVL = 500_000e6;

    /// @dev The ticket `screen/` sizes its exit flags against (`--position-size`), the same figure
    ///      {CurvanceCUSDCForkTest} uses. A vault holding less cash than this cannot return the
    ///      position it is being screened for.
    uint256 internal constant POSITION_SIZE = 250_000e6;

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

    /// @dev Monad is no longer USDC-only. Every USDC-denominated test below iterates through this
    ///      rather than over `vaults` directly, because depositing USDC into an AUSD vault reverts
    ///      `AssetMismatch()` at `registerMarket`.
    function _isNativeUsdcVault(uint256 i) internal view returns (bool) {
        return IERC4626(vaults[i]).asset() == NATIVE_USDC;
    }

    /// @notice Every configured vault must be denominated in a token the config also lists, and
    ///         anything that is not USDC must have a swap route to reach it.
    ///
    /// @dev This replaces a blanket "every Monad vault is USDC" assertion, which `eAUSD16` broke —
    ///      it is the chain's first non-USDC instrument. The blanket form was never the real
    ///      invariant: `registerMarket` asserts `IERC4626(vault).asset() == currency` and
    ///      `RegisterInstruments` reads that currency off the vault, so a non-USDC vault registers
    ///      perfectly well. What actually makes such an instrument *unreachable* is a missing
    ///      route — deposits arrive in USDC and have to be swapped — and `Deploy._registerSwapPools`
    ///      skips a route whose symbols do not resolve without erroring. So the invariant worth
    ///      asserting is: known asset, and a route if it is not the base one.
    function test_everyVaultAssetIsConfiguredAndRoutable() public view {
        for (uint256 i = 0; i < vaults.length; i++) {
            address asset = IERC4626(vaults[i]).asset();
            if (asset == NATIVE_USDC) continue;

            assertTrue(_configListsToken(asset), string.concat("asset is in no token map entry: ", names[i]));
            assertTrue(_configHasRouteFromUsdc(asset), string.concat("non-USDC vault with no swap route: ", names[i]));
        }
    }

    /// @dev Walks `tokens` rather than naming symbols, so a new asset is covered automatically.
    function _configListsToken(address token) internal view returns (bool) {
        string memory tokensPath = string.concat(NET_PATH, ".tokens");
        string[] memory symbols = vm.parseJsonKeys(config, tokensPath);
        for (uint256 i = 0; i < symbols.length; i++) {
            if (vm.parseJsonAddress(config, string.concat(tokensPath, ".", symbols[i])) == token) return true;
        }
        return false;
    }

    /// @dev A route is bidirectional once registered (`Deploy._registerSwapPools` registers both
    ///      directions from one entry), so matching either leg is enough.
    function _configHasRouteFromUsdc(address token) internal view returns (bool) {
        string memory poolsPath = string.concat(NET_PATH, ".swapPools");
        if (!vm.keyExistsJson(config, poolsPath)) return false;

        string memory tokensPath = string.concat(NET_PATH, ".tokens");
        for (uint256 i = 0;; i++) {
            string memory entry = string.concat(poolsPath, "[", vm.toString(i), "]");
            if (!vm.keyExistsJson(config, string.concat(entry, ".tokenIn"))) return false;

            address inAddr = vm.parseJsonAddress(
                config, string.concat(tokensPath, ".", vm.parseJsonString(config, string.concat(entry, ".tokenIn")))
            );
            address outAddr = vm.parseJsonAddress(
                config, string.concat(tokensPath, ".", vm.parseJsonString(config, string.concat(entry, ".tokenOut")))
            );
            if ((inAddr == NATIVE_USDC && outAddr == token) || (outAddr == NATIVE_USDC && inAddr == token)) {
                return true;
            }
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
                // The vault's own asset, not USDC: `registerMarket` asserts they match, and
                // Monad now carries an AUSD-denominated instrument.
                adapter.registerMarket(Currency.wrap(IERC4626(vaults[i]).asset()), vaults[i]);
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
            // USDC-denominated vaults only. A non-USDC instrument round-trips in its own
            // asset, which needs funding this loop cannot do generically — AUSD in particular
            // defeats `deal`. `EulerEAUSD16ForkTest` covers `eAUSD16` at these same sizes.
            if (!_isNativeUsdcVault(i)) continue;

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

            // The preview half applies to every vault; the deposit half is USDC-funded, so it
            // covers the USDC-denominated ones only. `EulerEAUSD16ForkTest` carries the equivalent
            // for `eAUSD16`.
            if (!_isNativeUsdcVault(i)) continue;

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
    ///         *because* the vault is borrowed against to the hilt. A high APY on a vault that
    ///         cannot return the ticket is the shape this checklist exists to catch, so the
    ///         exclusion is pinned rather than left as a comment in a plan.
    /// @dev The bound is the ticket, not a snapshot of `cash()`. At block 95_300_000 cash was a
    ///      single unit against $1.43M borrowed; at FORK_BLOCK it is $71,438 against $1,048,983
    ///      borrowed — 93.6% utilisation, still an order of magnitude short of a $250k exit.
    ///      Measuring against `POSITION_SIZE` keeps the tripwire pointed at the thing that would
    ///      change the listing decision — the vault being able to return the position — instead of
    ///      firing every time a borrower repays.
    function test_excludedEulerVaultIsStillUnexitable() public view {
        uint256 cash = IEulerVault(EXCLUDED_EULER_VAULT).cash();
        uint256 borrows = IEulerVault(EXCLUDED_EULER_VAULT).totalBorrows();

        assertGt(borrows, 0, "excluded vault has no borrows; re-screen it");
        assertLt(cash, POSITION_SIZE, "excluded vault can now return the ticket; it may be listable, re-screen it");

        for (uint256 i = 0; i < vaults.length; i++) {
            assertTrue(vaults[i] != EXCLUDED_EULER_VAULT, "unexitable vault was added to config");
        }
    }
}

/// @title MonadReserveInstrumentsForkTest
/// @notice The same config-vs-chain sweep as above, for the **reserve-shaped** protocols —
///         `networks.monadMainnet.protocols.*` carrying both `pool` and `reserves`.
///
/// @dev {MonadInstrumentsForkTest} above walks vault lists, which is everything
///      `RegisterInstruments.s.sol` can register. It could never cover Aave, because Aave exposes
///      no enumerable vault list — and once `RegisterInstruments.s.sol` grew a branch that makes
///      reserve lists a
///      registrable thing, a `reserves` array that drifts from chain state became a way to ship a
///      broken listing with nothing failing. This is that guard.
///
///      The selection rule is deliberately the same predicate the script uses
///      ({RegisterInstruments-_isReserveShaped}): `pool` **and** `reserves`. So a new Aave
///      fork added to config is covered here the moment it is added, with no edit to this file.
///
///      **The load-bearing assertion is {test_everyReserveBelongsToItsConfiguredPool}.** Monad
///      carries two Aave-shaped pools — Aave V3 and Neverland — and they share reserve symbols.
///      `AaveAdapter` keys markets by `keccak256(abi.encode(currency))` with no pool in the
///      preimage, so a `pool` address that drifted to the other protocol's would register markets
///      that resolve, deposit and withdraw perfectly well against entirely the wrong protocol.
///      Reading `aToken.POOL()` back is what makes that visible.
///
///      Pinned to its own block, separate from the vault sweep above, because each suite's bounds
///      are measurements of its own block and must not be disturbed by the other's re-pin. (The
///      sweep now sits at the later of the two; it was moved forward when its original block aged
///      out of what the RPC retains.)
///
///      Run: MONAD_RPC_URL=https://rpc.monad.xyz forge test --mc MonadReserveInstrumentsForkTest -vv
contract MonadReserveInstrumentsForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 103_060_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant NET_PATH = ".networks.monadMainnet";

    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    string internal config;
    string[] internal protocolKeys;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);
        config = vm.readFile(CONFIG_PATH);

        string memory protocolsPath = string.concat(NET_PATH, ".protocols");
        string[] memory all = vm.parseJsonKeys(config, protocolsPath);
        for (uint256 i = 0; i < all.length; i++) {
            string memory protoPath = string.concat(protocolsPath, ".", all[i]);
            if (!vm.keyExistsJson(config, string.concat(protoPath, ".pool"))) continue;
            if (!vm.keyExistsJson(config, string.concat(protoPath, ".reserves"))) continue;
            protocolKeys.push(all[i]);
        }

        assertGt(protocolKeys.length, 0, "no reserve-shaped protocols in Monad config");
    }

    function _pool(string memory protocolKey) internal view returns (address) {
        return vm.parseJsonAddress(config, string.concat(NET_PATH, ".protocols.", protocolKey, ".pool"));
    }

    function _reserves(string memory protocolKey) internal view returns (string[] memory) {
        return config.readStringArray(string.concat(NET_PATH, ".protocols.", protocolKey, ".reserves"));
    }

    function _token(string memory symbol) internal view returns (address) {
        string memory path = string.concat(NET_PATH, ".tokens.", symbol);
        if (!vm.keyExistsJson(config, path)) return address(0);
        return vm.parseJsonAddress(config, path);
    }

    /// @dev A route is bidirectional once registered, so matching either leg is enough.
    function _configHasRouteFromUsdc(address token) internal view returns (bool) {
        string memory poolsPath = string.concat(NET_PATH, ".swapPools");
        if (!vm.keyExistsJson(config, poolsPath)) return false;

        for (uint256 i = 0;; i++) {
            string memory entry = string.concat(poolsPath, "[", vm.toString(i), "]");
            if (!vm.keyExistsJson(config, string.concat(entry, ".tokenIn"))) return false;

            address inAddr = _token(vm.parseJsonString(config, string.concat(entry, ".tokenIn")));
            address outAddr = _token(vm.parseJsonString(config, string.concat(entry, ".tokenOut")));
            if ((inAddr == NATIVE_USDC && outAddr == token) || (outAddr == NATIVE_USDC && inAddr == token)) {
                return true;
            }
        }
    }

    // ============================================
    // Config resolves against chain state
    // ============================================

    /// @notice Every symbol in a `reserves` list resolves in the same config's `tokens` map.
    /// @dev `RegisterInstruments` skips an unresolvable symbol rather than aborting — one
    ///      `reserves` array covers a protocol across chains that list different assets. That is
    ///      right for the script and wrong as a silent outcome for *this* chain, where every
    ///      symbol was written deliberately. A GHO listing lost to a missing token entry is a
    ///      dry run that reads clean and a shelf with one fewer instrument on it.
    function test_everyReserveSymbolResolvesInTheTokenMap() public view {
        for (uint256 p = 0; p < protocolKeys.length; p++) {
            string[] memory symbols = _reserves(protocolKeys[p]);
            for (uint256 i = 0; i < symbols.length; i++) {
                assertTrue(
                    _token(symbols[i]) != address(0),
                    string.concat("reserve symbol is in no `tokens` entry: ", protocolKeys[p], ".", symbols[i])
                );
            }
        }
    }

    /// @notice **The one that matters.** Every configured reserve is a live reserve *on the pool
    ///         config names*, proven by reading the aToken's own `POOL()` back.
    /// @dev Monad carries two Aave-shaped pools sharing reserve symbols. A `pool` address that
    ///      drifted to the other protocol's would still register, deposit and withdraw — against
    ///      the wrong protocol, under the wrong risk budget. Nothing else in the pipeline notices.
    function test_everyReserveBelongsToItsConfiguredPool() public view {
        for (uint256 p = 0; p < protocolKeys.length; p++) {
            address pool = _pool(protocolKeys[p]);
            string[] memory symbols = _reserves(protocolKeys[p]);

            for (uint256 i = 0; i < symbols.length; i++) {
                string memory label = string.concat(protocolKeys[p], ".", symbols[i]);
                address token = _token(symbols[i]);

                address aToken = IAavePool(pool).getReserveData(token).aTokenAddress;
                assertTrue(aToken != address(0), string.concat("not a reserve on the configured pool: ", label));
                assertEq(
                    IAToken(aToken).UNDERLYING_ASSET_ADDRESS(),
                    token,
                    string.concat("aToken is denominated in a different asset: ", label)
                );
                assertEq(IAToken(aToken).POOL(), pool, string.concat("reserve belongs to another pool: ", label));
            }
        }
    }

    /// @notice A reserve that is frozen or paused is a market where a deposit reverts. Listing one
    ///         ships an instrument the shelf will route to and the chain will refuse.
    function test_everyReserveIsOpenForSupply() public view {
        for (uint256 p = 0; p < protocolKeys.length; p++) {
            address pool = _pool(protocolKeys[p]);
            string[] memory symbols = _reserves(protocolKeys[p]);

            for (uint256 i = 0; i < symbols.length; i++) {
                string memory label = string.concat(protocolKeys[p], ".", symbols[i]);
                uint256 cfg = IAavePool(pool).getReserveData(_token(symbols[i])).configuration;

                assertTrue((cfg >> 56) & 1 == 1, string.concat("reserve is not active: ", label));
                assertTrue((cfg >> 57) & 1 == 0, string.concat("reserve is frozen: ", label));
                assertTrue((cfg >> 60) & 1 == 0, string.concat("reserve is paused: ", label));
            }
        }
    }

    /// @notice A reserve holding no cash is an exit that reverts. This is a floor of one unit, not
    ///         a sizing claim — sizing lives in each market's own fork test, which measures the
    ///         ceiling against the $250k ticket.
    function test_everyReserveHoldsCash() public {
        for (uint256 p = 0; p < protocolKeys.length; p++) {
            address pool = _pool(protocolKeys[p]);
            string[] memory symbols = _reserves(protocolKeys[p]);

            for (uint256 i = 0; i < symbols.length; i++) {
                address token = _token(symbols[i]);
                address aToken = IAavePool(pool).getReserveData(token).aTokenAddress;
                uint256 cash = IERC20(token).balanceOf(aToken);

                emit log_named_uint(
                    string.concat(protocolKeys[p], ".", symbols[i], " cash (whole units)"),
                    cash / (10 ** IVaultDecimals(token).decimals())
                );
                assertGt(cash, 0, string.concat("reserve holds no cash: ", protocolKeys[p], ".", symbols[i]));
            }
        }
    }

    /// @notice A non-USDC reserve needs a swap route, or deposits arriving in USDC cannot reach it.
    /// @dev The reserve-side twin of {MonadInstrumentsForkTest-test_everyVaultAssetIsConfiguredAndRoutable}.
    ///      GHO is the case this was written for: it is the shelf's first 18-decimal instrument and
    ///      the chain's second route.
    function test_everyNonUsdcReserveIsRoutable() public view {
        for (uint256 p = 0; p < protocolKeys.length; p++) {
            string[] memory symbols = _reserves(protocolKeys[p]);
            for (uint256 i = 0; i < symbols.length; i++) {
                address token = _token(symbols[i]);
                if (token == NATIVE_USDC) continue;
                assertTrue(
                    _configHasRouteFromUsdc(token),
                    string.concat("non-USDC reserve with no swap route: ", protocolKeys[p], ".", symbols[i])
                );
            }
        }
    }

    // ============================================
    // The two pools stay two protocols
    // ============================================

    /// @notice Distinct pools, distinct adapter keys, distinct protocol names.
    /// @dev Any collision here is the whole failure `AaveAdapter.initializeNamed` exists to
    ///      prevent: two protocols sharing one adapter proxy, and therefore one
    ///      `max_weight_per_protocol` budget and one set of per-currency market slots.
    function test_reserveProtocolsAreDistinct() public view {
        for (uint256 a = 0; a < protocolKeys.length; a++) {
            for (uint256 b = a + 1; b < protocolKeys.length; b++) {
                assertNotEq(_pool(protocolKeys[a]), _pool(protocolKeys[b]), "two protocols share a pool address");
                assertNotEq(
                    _adapterKey(protocolKeys[a]), _adapterKey(protocolKeys[b]), "two protocols share an adapter key"
                );
            }
        }
    }

    /// @dev Mirrors `RegisterInstruments._resolveReserveAdapter`: the protocol key is the default,
    ///      which
    ///      is how `aave` resolves — it predates the `adapter` block and has none.
    function _adapterKey(string memory protocolKey) internal view returns (string memory) {
        string memory path = string.concat(NET_PATH, ".protocols.", protocolKey, ".adapter.key");
        return vm.keyExistsJson(config, path) ? vm.parseJsonString(config, path) : protocolKey;
    }

    /// @notice Registering the whole configured shelf, exactly as the script would, produces one
    ///         instrument per reserve and no two alike.
    /// @dev The end-to-end proof that config and chain agree. Two things it pins that no view
    ///      function does: `registerMarket` resolves the right aToken through the repo's own
    ///      `IAavePool` for every reserve on both pools, and `generateInstrumentId` separates
    ///      Aave USDC from Neverland USDC — which share a `marketId` and differ only by pool.
    function test_everyConfiguredReserveRegistersToADistinctInstrument() public {
        bytes32[] memory ids = new bytes32[](32);
        uint256 n;

        for (uint256 p = 0; p < protocolKeys.length; p++) {
            address pool = _pool(protocolKeys[p]);
            AaveAdapter adapter = AdapterProxyLib.deployAaveNamed(pool, address(this), protocolKeys[p]);
            string[] memory symbols = _reserves(protocolKeys[p]);

            for (uint256 i = 0; i < symbols.length; i++) {
                address token = _token(symbols[i]);
                Currency currency = Currency.wrap(token);
                bytes32 marketId = keccak256(abi.encode(currency));

                adapter.registerMarket(currency);
                assertEq(
                    adapter.getYieldToken(marketId),
                    IAavePool(pool).getReserveData(token).aTokenAddress,
                    string.concat("adapter resolved a different aToken: ", protocolKeys[p], ".", symbols[i])
                );

                ids[n++] = InstrumentIdLib.generateInstrumentId(block.chainid, pool, marketId);
            }
        }

        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                assertNotEq(ids[i], ids[j], "two configured reserves collide on one instrumentId");
            }
        }
        emit log_named_uint("reserve instruments configured on Monad", n);
    }
}
