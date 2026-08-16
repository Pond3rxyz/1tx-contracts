// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev Harvest's access gate lives on its Controller, not on the vault.
interface IHarvestController {
    function greyList(address target) external view returns (bool);
    function governance() external view returns (address);
}

/// @dev The ERC-20 metadata surface `IERC4626` does not declare.
interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title HarvestFUSDCForkTest
/// @notice Why Harvest Finance's `fUSDC` on Base is **not listable**, pinned so the finding is not
///         rediscovered by the next person who reads its APY.
///
/// @dev `screen/` reported this vault `config_only` on the 2026-08-15 snapshot and it was the best
///      candidate on the board by some distance: $1.90M, 10.64% APY against a 30-day mean of
///      11.56%, 453 days of history, and correlation **+0.012** across 7 pairs against a shelf
///      whose own internal median pair correlation is +0.168. Near-independent of the existing
///      book, which almost nothing on Base is.
///
///      It cannot be listed, and no view function says so. Harvest's vault carries a `defense`
///      modifier that admits a caller only when `msg.sender == tx.origin` — an EOA — or when
///      Harvest's Controller has explicitly whitelisted the caller. `ERC4626Adapter` is a
///      contract, so **every deposit and every withdraw reverts** with
///      `"This smart contract has been grey listed"`. Measured at FORK_BLOCK:
///      `greyList(addr)` returns `true` for every address tried, including EOAs, so the gate is a
///      strict allowlist and the EOA path works only through the `tx.origin` half of the check.
///
///      **This is a class of blocker the screen cannot see, and the reason fork tests are not
///      optional.** `previewDeposit` is a pure conversion and does not revert. `maxDeposit`
///      returns `type(uint256).max`. The probe reads both from an `eth_call` with no meaningful
///      sender, and a static call cannot model `msg.sender != tx.origin` at all. Every signal the
///      screen has says the entry is open. See `screen/README.md`, "Before you call something a
///      find".
///
///      Listing this would require Harvest governance (`0x920b1aCb…`) to whitelist the adapter
///      proxy address — a per-deployment, per-chain external dependency, and one that could be
///      revoked after listing. {test_contractCallersAreGreyListed} is the guard: if Harvest ever
///      opens the gate, it fails and the instrument becomes reconsiderable.
///
///      Pinned to a block these numbers were measured against.
///
///      Run: BASE_RPC_URL=... forge test --mc HarvestFUSDCForkTest -vv
contract HarvestFUSDCForkTest is Test {
    uint256 internal constant FORK_BLOCK = 50_040_000;

    /// @dev Harvest Finance `FARM_USDC`. 6-decimal shares over 6-decimal native USDC.
    address internal constant VAULT = 0xC777031D50F632083Be7080e51E390709062263E;
    address internal constant NATIVE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CONTROLLER = 0xF90FF0F7c8Db52bF1bF869F74226eAD125EFa745;
    address internal constant HARVEST_GOVERNANCE = 0x920b1aCb7618B553324aa0F71620226FA2e09870;

    string internal constant GREYLIST_REVERT = "This smart contract has been grey listed";

    uint256 internal constant SHARE_UNIT = 1e6;

    ERC4626Adapter internal adapter;
    address internal usdc;
    bytes32 internal marketId;

    address internal user;
    address internal recipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);

        usdc = IERC4626(VAULT).asset();
        marketId = bytes32(uint256(uint160(VAULT)));

        adapter = AdapterProxyLib.deployNamed(address(this), "Harvest");
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(usdc), VAULT);

        user = makeAddr("harvestUser");
        recipient = makeAddr("harvestRecipient");
    }

    // ============================================
    // The blocker
    // ============================================

    /// @notice **The finding.** A deposit routed through the adapter — the only way this shelf
    ///         ever deposits — reverts on Harvest's greylist. Not a capacity limit, not a cap: the
    ///         vault refuses contract callers outright.
    function test_adapterCannotDeposit() public {
        uint256 amount = 10_000e6;
        deal(usdc, user, amount);

        vm.startPrank(user, user);
        IERC20(usdc).approve(address(adapter), amount);
        vm.expectRevert(bytes(GREYLIST_REVERT));
        adapter.deposit(marketId, amount, user);
        vm.stopPrank();
    }

    /// @notice The other half, so the revert above is attributable to the caller's *shape* and not
    ///         to the adapter, the approval, or the amount: the identical deposit from an EOA
    ///         succeeds. `vm.prank(eoa, eoa)` sets `msg.sender` and `tx.origin` together, which is
    ///         precisely the condition Harvest's `defense` modifier tests.
    function test_eoaCanDepositDirectly() public {
        uint256 amount = 10_000e6;
        address eoa = makeAddr("harvestEOA");
        deal(usdc, eoa, amount);

        vm.startPrank(eoa, eoa);
        IERC20(usdc).approve(VAULT, amount);
        uint256 shares = IERC4626(VAULT).deposit(amount, eoa);
        vm.stopPrank();

        assertGt(shares, 0, "EOA deposit failed too: the blocker is not the greylist");
    }

    /// @notice The gate is an allowlist, not a blocklist — `greyList` is `true` by default, so
    ///         nothing passes on the contract path until Harvest governance adds it. Pins the
    ///         mechanism rather than the symptom, and fails if Harvest ever opens it.
    function test_contractCallersAreGreyListed() public view {
        assertTrue(
            IHarvestController(CONTROLLER).greyList(address(adapter)),
            "adapter is no longer grey listed: Harvest opened the gate, reconsider this instrument"
        );
        assertEq(
            IHarvestController(CONTROLLER).governance(),
            HARVEST_GOVERNANCE,
            "controller governance moved: the whitelisting counterparty changed"
        );
    }

    /// @notice Exits are gated by the same modifier, so this is not a deposit-only inconvenience
    ///         that could be worked around by funding the position another way. A position taken
    ///         by an EOA could not be exited through the adapter.
    function test_adapterCannotWithdrawEither() public {
        uint256 shares = 1_000 * SHARE_UNIT;
        // Give the adapter shares directly, so the only thing under test is the exit leg.
        deal(VAULT, address(adapter), shares);

        vm.expectRevert(bytes(GREYLIST_REVERT));
        adapter.withdraw(marketId, shares, recipient);
    }

    // ============================================
    // What was true, and stays pinned
    // ============================================

    /// @notice `registerMarket` asserts `IERC4626(vault).asset() == currency`. The vault really is
    ///         native-USDC denominated — the listing case was sound; only the gate stops it.
    function test_vaultAssetIsNativeUSDC() public view {
        assertEq(usdc, NATIVE_USDC, "fUSDC must be denominated in native USDC, not a bridged variant");
    }

    /// @notice This vault's `symbol()` is `fUSDC`, which is also Fluid's fToken symbol, and Fluid
    ///         is already listed on Base. Matching an instrument by symbol rather than address is
    ///         how §2b's production bug shipped, so the address is pinned to all three metadata
    ///         fields: a copy-paste between the two entries fails here.
    function test_vaultIdentity() public view {
        assertEq(IERC20Metadata(VAULT).symbol(), "fUSDC", "symbol changed: re-check which fUSDC this is");
        assertEq(IERC20Metadata(VAULT).name(), "FARM_USDC", "name changed: this may not be the Harvest vault");
        assertEq(IERC20Metadata(VAULT).decimals(), 6, "share decimals changed");
    }

    /// @notice The signals that made this look listable, pinned so the contrast is on the record:
    ///         entry is uncapped and the conversion surface is clean. Everything a static probe
    ///         can reach says yes.
    function test_staticSurfaceLooksListable() public view {
        assertEq(IERC4626(VAULT).maxDeposit(address(adapter)), type(uint256).max, "maxDeposit is no longer uncapped");
        assertGt(IERC4626(VAULT).previewDeposit(10_000e6), 0, "previewDeposit stopped quoting");
        assertGt(IERC4626(VAULT).convertToAssets(SHARE_UNIT), SHARE_UNIT, "share price fell below par");
    }
}
