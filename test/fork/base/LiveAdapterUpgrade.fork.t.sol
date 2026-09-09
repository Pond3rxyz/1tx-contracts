// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";

/// @title LiveAdapterUpgradeForkTest
/// @notice Upgrades the **real, live** Base adapter proxies to the current implementations on a
///         fork and asserts nothing observable changes.
/// @dev Moving the adapter name from bytecode into storage (`ERC4626Adapter.initializeNamed`)
///      inserted a field where `__gap[0]` used to be. On every already-deployed proxy that slot is
///      zero, so the new `_adapterName()` reads an empty string — and the API treats the adapter
///      name as the instrument's protocol identity, which `max_weight_per_protocol` budgets
///      against. An adapter that started reporting "" would silently re-bucket every instrument
///      under it.
///
///      `ERC4626Adapter.upgrade.t.sol` covers this against the V1 *snapshot*. This covers it
///      against **production state**: real proxies, real owner, real registered markets.
///
///      Nothing here is required for the Avantis listing — that deploys a fresh proxy and does not
///      touch these. This exists so the answer to "do we have to upgrade the existing adapters?"
///      is backed by evidence: no, and it stays safe whenever they are next upgraded for an
///      unrelated reason.
///
///      Run: BASE_RPC_URL=... forge test --mc LiveAdapterUpgradeForkTest -vv
contract LiveAdapterUpgradeForkTest is Test {
    uint256 internal constant FORK_BLOCK = 49_487_469;

    address internal constant OWNER = 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73;
    address internal constant ROUTER = 0xbFdd5bEdC0cB9B8795A93C2a1fB634012C8F99bC;

    address internal constant MORPHO_PROXY = 0x74980651215862A2c9af32922EB193e31231fCf2;
    address internal constant EULER_PROXY = 0xb795ff600c6856f04B3d52083be2579E95678b05;
    address internal constant FLUID_PROXY = 0xaB1659910AaF12d2274217212A597E9536488D3B;

    // One registered market per adapter, from docs/deployments.md.
    address internal constant MORPHO_VAULT = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183; // Steakhouse USDC
    address internal constant EULER_VAULT = 0x67f062a12f82c3b42d4CA7a35fb26CbAac28008B; // eeUSDC
    address internal constant FLUID_FTOKEN = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169; // fUSDC

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    }

    function _assertUpgradePreservesEverything(
        address proxy,
        address newImpl,
        address vault,
        string memory expectedName
    ) internal {
        ERC4626Adapter adapter = ERC4626Adapter(proxy);
        bytes32 marketId = bytes32(uint256(uint160(vault)));

        // Snapshot production state before touching anything.
        string memory nameBefore = adapter.getAdapterMetadata().name;
        bool hadMarket = adapter.hasMarket(marketId);
        bool routerAuthorized = adapter.authorizedCallers(ROUTER);
        address ownerBefore = adapter.owner();
        address yieldTokenBefore = adapter.getYieldToken(marketId);
        address currencyBefore = Currency.unwrap(adapter.getMarketCurrency(marketId));

        assertEq(nameBefore, expectedName, "live adapter is not the protocol we think it is");
        assertTrue(hadMarket, "sample market is not registered on the live adapter");
        assertTrue(routerAuthorized, "router is not authorized on the live adapter");
        assertEq(ownerBefore, OWNER, "owner is not the expected deployer");

        vm.prank(OWNER);
        adapter.upgradeToAndCall(newImpl, "");

        // The assertion this file exists for.
        assertEq(adapter.getAdapterMetadata().name, expectedName, "adapter identity changed across the upgrade");

        assertEq(adapter.getAdapterMetadata().chainId, 8453, "chainId shifted");
        assertTrue(adapter.hasMarket(marketId), "market lost across the upgrade");
        assertTrue(adapter.authorizedCallers(ROUTER), "router authorization lost across the upgrade");
        assertEq(adapter.owner(), ownerBefore, "owner shifted");
        assertEq(adapter.getYieldToken(marketId), yieldTokenBefore, "yieldToken shifted");
        assertEq(Currency.unwrap(adapter.getMarketCurrency(marketId)), currencyBefore, "currency shifted");
    }

    function test_liveMorphoAdapter_upgradeIsNoOp() public {
        _assertUpgradePreservesEverything(MORPHO_PROXY, address(new MorphoAdapter()), MORPHO_VAULT, "Morpho Vaults V2");
    }

    function test_liveEulerAdapter_upgradeIsNoOp() public {
        _assertUpgradePreservesEverything(EULER_PROXY, address(new EulerAdapter()), EULER_VAULT, "Euler Earn");
    }

    function test_liveFluidAdapter_upgradeIsNoOp() public {
        _assertUpgradePreservesEverything(FLUID_PROXY, address(new FluidAdapter()), FLUID_FTOKEN, "Fluid Lending");
    }

    /// @notice The counter-example that shows the subclass overrides are load-bearing.
    /// @dev Upgrading a live proxy to the *generic* adapter drops it to the default name, because
    ///      its stored-name slot is empty. This is not a bug in the fallback — it is why
    ///      MorphoAdapter/EulerAdapter/FluidAdapter must be kept rather than collapsed into the
    ///      generic contract now that naming is dynamic. Retire them only by first setting the
    ///      stored name, which today has no setter by design.
    function test_upgradingLiveProxyToGenericAdapterWouldLoseIdentity() public {
        ERC4626Adapter adapter = ERC4626Adapter(MORPHO_PROXY);
        assertEq(adapter.getAdapterMetadata().name, "Morpho Vaults V2");

        // Deploy before the prank: `vm.prank` applies to the next call *or create*, so a `new`
        // in the argument list consumes it and the upgrade arrives from the default sender.
        address newImpl = address(new ERC4626Adapter());
        vm.prank(OWNER);
        adapter.upgradeToAndCall(newImpl, "");

        assertEq(
            adapter.getAdapterMetadata().name,
            "ERC4626 Adapter",
            "expected the generic default: the stored name slot is empty on pre-existing proxies"
        );
    }
}
