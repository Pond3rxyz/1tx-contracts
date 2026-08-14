// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev Share decimals, which `IERC4626` here does not declare. MetaMorpho V1.1 mints
///      `asset decimals + DECIMALS_OFFSET` shares, so a conversion probed at `1e6` reads as a
///      broken vault on exactly the vaults that work.
interface IVaultDecimals {
    function decimals() external view returns (uint8);
}

/// @dev The marker that separates the two Morpho vault generations. MetaMorpho V1.1 exposes the
///      Morpho Blue singleton it allocates through; Morpho Vaults V2 does not, and answers
///      `adaptersLength()` instead. Nothing in the ERC-4626 surface distinguishes them, and both
///      generations reuse names and symbols across the split.
interface IMetaMorphoV11 {
    function MORPHO() external view returns (address);
    function DECIMALS_OFFSET() external view returns (uint8);
}

/// @title MorphoVaultsV11ForkTest
/// @notice Fork tests for the MetaMorpho **V1.1** USDC vaults added to Base from the `screen/`
///         shortlist — and the record of which V1.1 vaults were rejected, and why.
///
/// @dev **The listing rule this file encodes: a V1.1 vault is listable only while Morpho has no
///      V2 successor for the same mandate.** Where a successor exists the curator migrates into
///      it, so listing the V1.1 buys an instrument whose balance is on its way out. That is not a
///      forecast — it is measured, from DeFiLlama TVL series as of 2026-08-13:
///
///      | rejected (V1.1)              | successor                        | 30d TVL | 180d TVL |
///      |------------------------------|----------------------------------|---------|----------|
///      | `0xc1256Ae5` Moonwell Flagship | `0x48a90E85` (listed)          |  -11%   |  **-61%**|
///      | `0xBEEFA7B8` Steakhouse HY     | `0xbeeff7aE` (listed, +316%)   | **-33%**|  **-64%**|
///      | `0x5435BC53` UltraYield        | none found                     | **-43%**|   -61%   |
///
///      UltraYield is the odd one out and is rejected on the other half of the same concern: no
///      successor, but $388k draining at 43% a month is decay rather than migration. Restoring it
///      is a config line plus a key here.
///
///      The three that are listed have no V2 counterpart on Base, and their curators are not
///      abandoning the generation — Gauntlet has shipped V2 vaults for Prime and Frontier while
///      its V1.1 Prime vault still holds $428M and grew 37% over 180 days.
///
///      Same-name collisions are the trap this guards. Both Moonwell Flagship vaults are called
///      "Moonwell Flagship USDC" and both mint `mwUSDC`, and the one already in config is the
///      **$10k V2 seed** while the V1.1 holds $9.77M — so picking by name or symbol picks the
///      wrong contract in either direction. Monad's V1/V2 `hyperUSDCa` ($23 vs $58M, see
///      {MonadInstrumentsForkTest}) is the same trap with the sizes the other way round.
///
///      The listed vaults sit under `protocols.morpho`, not a new protocol key: the adapter's name
///      is the identity `max_weight_per_protocol` budgets against downstream, and V1.1 and V2 take
///      the same Morpho Blue market risk. Seven MetaMorpho V1.1 vaults (`steakhouseUSDC`,
///      `sparkUSDC`, ...) already sit under that adapter, so the name "Morpho Vaults V2" is a
///      generation label the shelf has never honoured. Splitting them would hand the allocator two
///      Morpho budgets.
///
///      Pinned to a recent Base block. Do NOT bump the shared {AdapterForkTestBase} block.
///
///      Run: BASE_RPC_URL=... forge test --mc MorphoVaultsV11ForkTest -vv
contract MorphoVaultsV11ForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 49_900_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant VAULTS_PATH = ".networks.baseMainnet.protocols.morpho.vaults";

    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Round trips are deposit-then-exit, so the deposit leg funds most of the exit. What is
    ///      left is share rounding and any entry/exit spread. Same bound as the Monad suite.
    uint256 internal constant MAX_ROUND_TRIP_LOSS_BPS = 25;

    /// @dev The smallest listed here held $673k when screened. A vault under this floor is a
    ///      wrong-generation shell, not a small vault.
    uint256 internal constant MIN_CREDIBLE_TVL = 250_000e6;

    MorphoAdapter internal adapter;
    string internal json;
    address internal user;
    address internal recipient;

    /// @dev Config keys (under baseMainnet.protocols.morpho.vaults) for the listed V1.1 vaults.
    string[] internal vaultKeys = ["pangolinsUSDC", "yieldClearstarUSDC", "gauntletUSDCCore"];

    /// @dev V1.1 vaults deliberately NOT listed, per the table above. Asserted absent from config
    ///      so a future batch cannot re-add one without re-opening the decision.
    address[] internal rejected = [
        0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca, // Moonwell Flagship USDC — superseded
        0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F, // Steakhouse High Yield USDC v1.1 — superseded
        0x5435BC53f2C61298167cdB11Cdf0Db2BFa259ca0 // UltraYield USDC — draining, no successor
    ];

    /// @dev The V2 successors of the first two rejections, which config lists instead.
    string[] internal successorKeys = ["moonwellFlagshipUSDC", "steakhouseHighYieldUSDC"];

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        json = vm.readFile(CONFIG_PATH);

        adapter = AdapterProxyLib.deployMorpho(address(this));
        adapter.setAuthorizedCaller(address(this), true);

        user = makeAddr("v11user");
        recipient = makeAddr("v11recipient");
    }

    function _vault(string memory key) internal view returns (address) {
        return json.readAddress(string.concat(VAULTS_PATH, ".", key));
    }

    function _register(address vault) internal returns (bytes32 marketId) {
        marketId = bytes32(uint256(uint160(vault)));
        if (!adapter.hasMarket(marketId)) {
            adapter.registerVault(Currency.wrap(BASE_USDC), vault);
        }
    }

    function _roundTrip(address vault, uint256 amount) internal returns (uint256 withdrawn) {
        bytes32 marketId = _register(vault);

        deal(BASE_USDC, user, amount);
        vm.startPrank(user);
        IERC20(BASE_USDC).approve(address(adapter), amount);
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

    function _isV11(address vault) internal view returns (bool) {
        (bool ok,) = vault.staticcall(abi.encodeCall(IMetaMorphoV11.MORPHO, ()));
        return ok;
    }

    // ============================================
    // Identity — which contract did config pick
    // ============================================

    /// @notice `registerMarket` asserts `asset() == currency`, so a wrong entry fails at
    ///         registration rather than at the first user deposit.
    function test_everyVaultIsDenominatedInBaseUSDC() public view {
        for (uint256 i = 0; i < vaultKeys.length; i++) {
            assertEq(IERC4626(_vault(vaultKeys[i])).asset(), BASE_USDC, string.concat("wrong asset: ", vaultKeys[i]));
        }
    }

    /// @notice The generation guard: each listed vault is MetaMorpho V1.1 *and* holds real money.
    /// @dev Asserted together on purpose. Either alone is satisfiable by the wrong contract — a
    ///      seeded V2 sibling is a real vault with a real asset, it just holds $10k.
    function test_vaultsAreTheV11GenerationAndNotAShell() public view {
        for (uint256 i = 0; i < vaultKeys.length; i++) {
            address vault = _vault(vaultKeys[i]);

            assertTrue(_isV11(vault), string.concat("not a MetaMorpho V1.1 vault: ", vaultKeys[i]));
            assertGt(IMetaMorphoV11(vault).DECIMALS_OFFSET(), 0, string.concat("no decimals offset: ", vaultKeys[i]));
            assertGt(
                IERC4626(vault).totalAssets(),
                MIN_CREDIBLE_TVL,
                string.concat("vault looks like a wrong-generation shell: ", vaultKeys[i])
            );
        }
    }

    /// @notice `convertToUnderlying` values a position and must survive a STATICCALL.
    /// @dev Probed at one *share*, from the vault's own `decimals()`. V1.1 mints 18-decimal shares
    ///      against 6-decimal USDC (`DECIMALS_OFFSET` 12), so probing at `1e6` rounds to zero and
    ///      reads exactly like a silent-zero vault.
    function test_convertToUnderlyingIsStaticcallSafe() public {
        for (uint256 i = 0; i < vaultKeys.length; i++) {
            address vault = _vault(vaultKeys[i]);
            bytes32 marketId = _register(vault);

            uint256 oneShare = 10 ** IVaultDecimals(vault).decimals();
            (bool ok, bytes memory ret) =
                address(adapter).staticcall(abi.encodeCall(ERC4626Adapter.convertToUnderlying, (marketId, oneShare)));

            assertTrue(ok, string.concat("convertToUnderlying reverted under STATICCALL: ", vaultKeys[i]));
            assertGt(abi.decode(ret, (uint256)), 0, string.concat("zero conversion rate: ", vaultKeys[i]));
        }
    }

    // ============================================
    // The V1.1 vaults that are deliberately not listed
    // ============================================

    /// @notice A superseded or draining V1.1 vault must stay out of config.
    /// @dev Enumerates every key under `protocols.morpho.vaults` rather than checking the three
    ///      keys added here, so a later batch re-adding one of these under any name fails.
    function test_supersededV11VaultsAreDeliberatelyAbsent() public view {
        string[] memory keys = vm.parseJsonKeys(json, VAULTS_PATH);

        for (uint256 r = 0; r < rejected.length; r++) {
            for (uint256 k = 0; k < keys.length; k++) {
                assertTrue(
                    _vault(keys[k]) != rejected[r],
                    string.concat("rejected V1.1 vault is back in config under: ", keys[k])
                );
            }
        }
    }

    /// @notice The two rejections that have a successor are represented by that successor, and it
    ///         really is the other generation.
    /// @dev This is what makes the rejection a substitution rather than a hole in the shelf. It
    ///         also pins the trap: `moonwellFlagshipUSDC` in config is the V2 contract, not the
    ///         same-named V1.1 one holding 970x more.
    function test_rejectedVaultsAreRepresentedByTheirV2Successor() public view {
        for (uint256 i = 0; i < successorKeys.length; i++) {
            address successor = _vault(successorKeys[i]);

            assertTrue(successor != address(0), string.concat("successor missing from config: ", successorKeys[i]));
            assertFalse(_isV11(successor), string.concat("successor is not Vaults V2: ", successorKeys[i]));
            assertEq(IERC4626(successor).asset(), BASE_USDC, string.concat("successor asset: ", successorKeys[i]));

            for (uint256 r = 0; r < rejected.length; r++) {
                assertTrue(
                    successor != rejected[r], string.concat("successor is the rejected vault: ", successorKeys[i])
                );
            }
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

    /// @dev $250k is the `screen/` default position size, and the size at which
    ///      `exit_buffer_below_position` fired on all of these. That flag says "fork-test the exit
    ///      at your intended ticket" — this is that test.
    function test_roundTrip_250k() public {
        _assertRoundTripsAtSize(250_000e6);
    }

    /// @notice The property a preview-only screen cannot check: the exit returns funds
    ///         in-transaction, at size, for every vault listed.
    /// @dev `ERC4626Adapter.withdraw` has no `assetsWithdrawn == 0` guard, so a vault that returns
    ///      zero past its buffer burns the caller's shares and returns nothing.
    function _assertRoundTripsAtSize(uint256 amount) internal {
        for (uint256 i = 0; i < vaultKeys.length; i++) {
            uint256 withdrawn = _roundTrip(_vault(vaultKeys[i]), amount);

            assertGt(withdrawn, 0, string.concat("silent zero on exit: ", vaultKeys[i]));
            assertLe(
                _lossBps(amount, withdrawn),
                MAX_ROUND_TRIP_LOSS_BPS,
                string.concat("round-trip loss above bound: ", vaultKeys[i])
            );
        }
    }

    /// @notice MetaMorpho V1.1 reports a real `maxDeposit`, unlike Morpho Vaults V2 which reports
    ///         zero while accepting deposits.
    /// @dev The inverse of {MonadInstrumentsForkTest-test_maxDepositZeroIsNotAFullVault}. Pinned
    ///      because a screen that trusts `maxDeposit` gets opposite answers from the two
    ///      generations, and both answers are wrong in one direction.
    function test_v11ReportsARealDepositCap() public view {
        for (uint256 i = 0; i < vaultKeys.length; i++) {
            address vault = _vault(vaultKeys[i]);
            assertGt(
                IERC4626(vault).maxDeposit(address(this)), 0, string.concat("V1.1 reports no headroom: ", vaultKeys[i])
            );
        }
    }
}
