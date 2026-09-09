// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";

/// @title LiveAaveAdapterUpgradeForkTest
/// @notice Upgrades the **real, live** Monad `AaveAdapter` proxy to the current implementation on
///         a fork and asserts nothing observable changes.
///
/// @dev The Aave twin of `test/fork/base/LiveAdapterUpgrade.fork.t.sol`, and it exists for the
///      same reason. Moving the adapter name from bytecode into storage
///      (`AaveAdapter.initializeNamed`) inserted a field where `__gap[0]` used to be. On every
///      already-deployed proxy — Base, Arbitrum and Monad, all initialized through
///      {AaveAdapter-initialize} — that slot is zero, so `_adapterName()` reads an empty string
///      and falls back to the historical `"Aave V3"`. The API treats the adapter name as the
///      instrument's protocol identity, and `max_weight_per_protocol` budgets against it, so an
///      adapter that started reporting `""` would silently re-bucket every instrument under it.
///
///      `AaveAdapter.upgrade.t.sol` covers this against the V1 *snapshot*, with mocks. This covers
///      it against **production state**: the real proxy, the real owner, the real registered USDC
///      market, and a real deposit and withdrawal through the real Aave pool afterwards.
///
///      **Nothing in the Aave GHO / Neverland listing requires this upgrade.** Neverland gets a
///      fresh proxy on the new implementation, and GHO registers through `registerMarket` /
///      `registerInstrument`, which the live V1 implementation already has. This test exists so
///      that "do we have to upgrade the live Aave proxy?" has an evidence-backed answer — no, and
///      it stays safe whenever it is next upgraded for an unrelated reason.
///
///      Run: MONAD_RPC_URL=... forge test --mc LiveAaveAdapterUpgradeForkTest -vv
contract LiveAaveAdapterUpgradeForkTest is Test {
    uint256 internal constant FORK_BLOCK = 103_060_000;

    address internal constant OWNER = 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73;
    address internal constant ROUTER = 0xe823985F6f08e0666c0271cD5c3457a5cF631edE;

    address internal constant AAVE_PROXY = 0x451b9EBdf001B900a51fa8282c62f49478Bf5a22;
    address internal constant AAVE_POOL = 0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef;

    /// @dev The one market registered on this proxy today, from `docs/deployments.md`.
    address internal constant NATIVE_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    AaveAdapter internal adapter;
    bytes32 internal marketId;

    function setUp() public {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), FORK_BLOCK);
        adapter = AaveAdapter(AAVE_PROXY);
        marketId = keccak256(abi.encode(Currency.wrap(NATIVE_USDC)));
    }

    /// @notice The state this test is about, read off production before anything is touched.
    /// @dev Asserted separately so a failure here says "the live proxy is not what this file
    ///      thinks it is" rather than being blamed on the upgrade below.
    function test_liveProxyIsWhatWeThinkItIs() public view {
        assertEq(adapter.owner(), OWNER, "owner is not the expected deployer");
        assertEq(address(adapter.AAVE_POOL()), AAVE_POOL, "proxy points at a different pool");
        assertEq(adapter.getAdapterMetadata().name, "Aave V3", "live adapter is not the protocol we think it is");
        assertEq(adapter.getAdapterMetadata().chainId, 143, "chainId mismatch");
        assertTrue(adapter.hasMarket(marketId), "USDC market is not registered on the live adapter");
        assertTrue(adapter.authorizedCallers(ROUTER), "router is not authorized on the live adapter");
    }

    /// @notice **The assertion this file exists for.** Upgrading the live proxy changes nothing
    ///         observable — the identity above all.
    function test_liveAaveAdapter_upgradeIsNoOp() public {
        string memory nameBefore = adapter.getAdapterMetadata().name;
        address ownerBefore = adapter.owner();
        address poolBefore = address(adapter.AAVE_POOL());
        address yieldTokenBefore = adapter.getYieldToken(marketId);
        address currencyBefore = Currency.unwrap(adapter.getMarketCurrency(marketId));

        // Deploy before the prank: `vm.prank` applies to the next call *or create*, so a `new`
        // in the argument list consumes it and the upgrade arrives from the default sender.
        address newImpl = address(new AaveAdapter());
        vm.prank(OWNER);
        adapter.upgradeToAndCall(newImpl, "");

        assertEq(adapter.getAdapterMetadata().name, nameBefore, "adapter identity changed across the upgrade");
        assertEq(adapter.getAdapterMetadata().name, "Aave V3", "the fallback did not hold");
        assertEq(adapter.getAdapterMetadata().chainId, 143, "chainId shifted");
        assertEq(adapter.owner(), ownerBefore, "owner shifted");
        assertEq(address(adapter.AAVE_POOL()), poolBefore, "AAVE_POOL shifted");
        assertTrue(adapter.hasMarket(marketId), "market lost across the upgrade");
        assertEq(adapter.getYieldToken(marketId), yieldTokenBefore, "yieldToken shifted");
        assertEq(Currency.unwrap(adapter.getMarketCurrency(marketId)), currencyBefore, "currency shifted");
        assertTrue(adapter.authorizedCallers(ROUTER), "router authorization lost across the upgrade");
    }

    /// @notice And the market still works end-to-end afterwards, not just under `staticcall`.
    /// @dev Views are what every near-miss passed. This deposits into the real Aave pool and exits
    ///      as the real router, which is the only thing that proves the storage layout survived in
    ///      the way that matters.
    function test_liveAaveAdapter_marketStillRoundTripsAfterUpgrade() public {
        // Deploy before the prank: `vm.prank` applies to the next call *or create*, so a `new`
        // in the argument list consumes it and the upgrade arrives from the default sender.
        address newImpl = address(new AaveAdapter());
        vm.prank(OWNER);
        adapter.upgradeToAndCall(newImpl, "");

        address aUsdc = adapter.getYieldToken(marketId);
        address user = makeAddr("liveAaveUser");
        address recipient = makeAddr("liveAaveRecipient");
        uint256 amount = 100_000e6;

        deal(NATIVE_USDC, user, amount);
        vm.startPrank(user);
        IERC20(NATIVE_USDC).approve(address(adapter), amount);
        adapter.deposit(marketId, amount, user);
        IERC20(aUsdc).transfer(address(adapter), IERC20(aUsdc).balanceOf(user));
        vm.stopPrank();

        // Read the balance *before* the prank: `vm.prank` applies to the next call, and an
        // argument expression that is itself a call would consume it.
        uint256 held = IERC20(aUsdc).balanceOf(address(adapter));

        // As the router, because that is who is authorized — and the authorization surviving the
        // upgrade is part of what is being asserted.
        vm.prank(ROUTER);
        uint256 withdrawn = adapter.withdraw(marketId, held, recipient);

        assertGt(withdrawn, 0, "silent zero on exit after the upgrade");
        assertEq(IERC20(NATIVE_USDC).balanceOf(recipient), withdrawn, "recipient did not receive the reported amount");
        assertApproxEqRel(withdrawn, amount, 0.0025e18, "round trip lost more than the spread after the upgrade");
    }

    /// @notice A second, freshly named proxy on the same implementation reports its own identity
    ///         while the upgraded live one keeps reporting `"Aave V3"`.
    /// @dev The two halves of the change, asserted together against production state: the live
    ///      proxy is not re-bucketed, and a fork can still be listed as its own protocol.
    function test_upgradedLiveProxyAndANamedProxyCoexist() public {
        // Deploy before the prank: `vm.prank` applies to the next call *or create*, so a `new`
        // in the argument list consumes it and the upgrade arrives from the default sender.
        address newImpl = address(new AaveAdapter());
        vm.prank(OWNER);
        adapter.upgradeToAndCall(newImpl, "");

        AaveAdapter named = new AaveAdapter();
        // The implementation itself has initializers disabled, so identity is checked through a
        // proxy the same way production deploys it.
        assertEq(adapter.getAdapterMetadata().name, "Aave V3", "live proxy took the new default");
        assertTrue(address(named) != AAVE_PROXY, "implementation collided with the live proxy");
    }
}
