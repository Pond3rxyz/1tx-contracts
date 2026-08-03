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

/// @title AvantisAvUSDCForkTest
/// @notice Fork tests for the Avantis LP tranche vault `avUSDC` on Base.
/// @dev The vault address is read from `script/config/NetworkConfig.json`, the same source
///      `script/RegisterInstruments.s.sol` registers from.
///
///      `avUSDC` is the first non-lending instrument on the shelf, and the first where a vault's
///      `previewRedeem` and `convertToAssets` disagree. The other ERC-4626 fork suites assert a
///      generic 1% tolerance, which would swallow that difference silently — these tests pin the
///      exit fee to an exact figure instead, so a change in Avantis' fee policy fails the suite
///      rather than passing unnoticed.
///
///      Pinned to the block the 2026-08-03 exit-path verification was run against
///      (`avusdc-exit-verification.md`). Do NOT bump it without re-running that analysis: the
///      fee and capacity assertions below are measurements of this state, not invariants of the
///      ERC-4626 standard.
///
///      Run: BASE_RPC_URL=... forge test --mc AvantisAvUSDCForkTest -vv
contract AvantisAvUSDCForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 49_487_469;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant VAULT_PATH = ".networks.baseMainnet.protocols.avantis.vaults.avUSDC";

    /// @dev Avantis' `collateralHealthFee`, in basis points. It is charged *on top of* the amount
    ///      the redeemer receives, not deducted from it — `getWithdrawalFeesRaw(x)` returns
    ///      `x * 50 / 10_000` while `getWithdrawalFeesTotal(x)` returns `x * 10_000 / 10_050`.
    ///      So a round trip nets `1 / 1.005` of the deposit: 49.75 bps, not 50.
    uint256 internal constant EXIT_FEE_BPS = 50;

    /// @dev Slack for the vault's own share rounding. A round trip converts assets → shares →
    ///      assets, so it rounds twice; the fee itself is exact.
    uint256 internal constant ROUNDING_SLACK = 10;

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

        adapter = AdapterProxyLib.deployNamed(address(this), "Avantis");
        adapter.setAuthorizedCaller(address(this), true);
        adapter.registerMarket(Currency.wrap(usdc), vault);

        user = makeAddr("avUser");
        recipient = makeAddr("avRecipient");
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(usdc, user, amount);
        vm.startPrank(user);
        IERC20(usdc).approve(address(adapter), amount);
        adapter.deposit(marketId, amount, user);
        vm.stopPrank();

        shares = IERC20(vault).balanceOf(user);
    }

    /// @notice The adapter's own identity — this is what the API surfaces as the protocol, and
    ///         what `max_weight_per_protocol` budgets against. A rename silently re-buckets the
    ///         instrument, so it is asserted rather than assumed.
    /// @dev Also the regression test for the name now living in storage rather than bytecode: if
    ///      `initializeNamed` stopped taking effect this would fall back to "ERC4626 Adapter",
    ///      and Avantis would quietly share a protocol budget with every other generic listing.
    function test_adapterName() public view {
        (string memory name, uint256 chainId) = _metadata();
        assertEq(name, "Avantis", "adapter must not borrow another protocol's identity");
        assertEq(chainId, 8453);
    }

    function test_depositThenWithdraw() public {
        uint256 amount = 10_000e6;
        uint256 shares = _deposit(amount);
        assertGt(shares, 0, "no shares minted");

        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);
        uint256 withdrawn = adapter.withdraw(marketId, shares, recipient);

        assertEq(IERC20(usdc).balanceOf(recipient), withdrawn, "recipient did not receive the reported amount");
        assertApproxEqAbs(withdrawn, _netOfExitFee(amount), ROUNDING_SLACK, "exit did not net exactly the fee");
    }

    /// @notice The batching invariant: a deposit and its exit must both settle inside one
    ///         transaction, because the paymaster charges after execution and an async redeem has
    ///         no single operation to pay gas out of. This is the check that disqualifies
    ///         ERC-7540 vaults (`sUSDai`) and buffer-limited ones (`yoUSD`).
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
        assertApproxEqAbs(
            withdrawn, _netOfExitFee(amount), ROUNDING_SLACK, "same-tx round trip cost more than the exit fee"
        );
    }

    /// @notice Exits are size-independent — no depth cliff, no partial fill, no silent zero.
    function test_exitFeeIsFlatAcrossSizes() public {
        uint256[4] memory sizes = [uint256(1_000e6), 100_000e6, 1_000_000e6, 10_000_000e6];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            uint256 shares = _deposit(sizes[i]);
            vm.prank(user);
            IERC20(vault).transfer(address(adapter), shares);
            uint256 withdrawn = adapter.withdraw(marketId, shares, recipient);

            assertApproxEqAbs(withdrawn, _netOfExitFee(sizes[i]), ROUNDING_SLACK, "exit fee is not flat at this size");

            vm.revertToState(snap);
        }
    }

    /// @notice Documents the known valuation gap, so it stays tracked instead of drifting.
    ///         `ERC4626Adapter.convertToUnderlying` uses `convertToAssets`, which for `avUSDC`
    ///         sits above the realizable `previewRedeem` by exactly the exit fee. Every lending
    ///         vault on the shelf has these two equal; this one does not.
    function test_convertToUnderlyingOverstatesByTheExitFee() public view {
        uint256 shares = 1_000e6;
        uint256 marked = adapter.convertToUnderlying(marketId, shares);
        uint256 realizable = IERC4626(vault).previewRedeem(shares);

        assertGt(marked, realizable, "expected convertToAssets to sit above previewRedeem");
        // Allow 1 unit for the vault's own rounding on top of the fee.
        assertApproxEqAbs(realizable, _netOfExitFee(marked), 1, "gap is not the exit fee");
    }

    /// @notice An adapter deployed without `setAuthorizedCaller(router)` ships a market where
    ///         deposits succeed and every exit reverts. `RegisterInstruments.s.sol` asserts
    ///         against that state; this proves the failure it is guarding.
    function test_withdrawRevertsForUnauthorizedCaller() public {
        uint256 shares = _deposit(1_000e6);
        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        adapter.withdraw(marketId, shares, recipient);
    }

    function _netOfExitFee(uint256 gross) internal pure returns (uint256) {
        return (gross * 10_000) / (10_000 + EXIT_FEE_BPS);
    }

    function _metadata() internal view returns (string memory name, uint256 chainId) {
        AdapterBaseUpgradeable.AdapterMetadata memory m = adapter.getAdapterMetadata();
        return (m.name, m.chainId);
    }
}
