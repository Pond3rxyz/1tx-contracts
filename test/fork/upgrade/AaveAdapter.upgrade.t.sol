// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {AaveAdapterV1} from "./legacy/AaveAdapterV1.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title AaveAdapter upgrade tests (V1 snapshot -> current)
/// @dev Validates the storage layout of the current AaveAdapter against the V1 snapshot, then
///      upgrades a V1 proxy in place and asserts markets + authorizedCallers survive intact.
///      Requires a full build: `forge clean && forge build && forge test --mc AaveAdapterUpgradeTest`.
contract AaveAdapterUpgradeTest is Test {
    AaveAdapterV1 public proxy;
    MockAavePool public pool;
    MockERC20 public usdc;
    MockERC20 public aUsdc;

    address public owner = makeAddr("owner");
    address public caller = makeAddr("router");

    Currency public currency;
    bytes32 public marketId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        pool = new MockAavePool();
        pool.setReserveData(address(usdc), address(aUsdc));

        currency = Currency.wrap(address(usdc));
        marketId = keccak256(abi.encode(currency));

        AaveAdapterV1 impl = new AaveAdapterV1();
        proxy = AaveAdapterV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(AaveAdapterV1.initialize, (address(pool), owner))))
        );

        vm.startPrank(owner);
        proxy.registerMarket(currency);
        proxy.setAuthorizedCaller(caller, true);
        vm.stopPrank();
    }

    function test_validateUpgrade_referenceV1() public {
        Options memory opts;
        opts.referenceContract = "AaveAdapterV1.sol:AaveAdapterV1";
        Upgrades.validateUpgrade("AaveAdapter.sol", opts);
    }

    function test_upgradeFromV1_preservesState() public {
        assertTrue(proxy.hasMarket(marketId), "market missing before upgrade");
        assertTrue(proxy.authorizedCallers(caller), "caller missing before upgrade");

        AaveAdapter newImpl = new AaveAdapter();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        AaveAdapter upgraded = AaveAdapter(address(proxy));
        assertEq(address(upgraded.AAVE_POOL()), address(pool), "AAVE_POOL shifted");
        assertTrue(upgraded.hasMarket(marketId), "market lost across upgrade");
        assertEq(upgraded.getYieldToken(marketId), address(aUsdc), "yieldToken shifted");
        assertEq(Currency.unwrap(upgraded.getMarketCurrency(marketId)), address(usdc), "currency shifted");
        assertTrue(upgraded.authorizedCallers(caller), "authorizedCaller lost across upgrade");
        assertEq(upgraded.owner(), owner, "owner shifted");
    }

    /// @notice A proxy that predates the stored adapter name keeps reporting a real name.
    /// @dev The whole risk of moving the name into storage: Base, Arbitrum and Monad all run
    ///      proxies initialized through {AaveAdapter-initialize}, so that slot is empty on every
    ///      one of them. Without the fallback in `_adapterName()` they would start reporting `""`
    ///      as their protocol identity the moment the implementation is swapped — and that string
    ///      is what `max_weight_per_protocol` budgets against downstream.
    function test_upgradeFromV1_nameFallsBackRatherThanEmptying() public {
        AaveAdapter newImpl = new AaveAdapter();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        assertEq(
            AaveAdapter(address(proxy)).getAdapterMetadata().name,
            "Aave V3",
            "live Aave proxy lost its name across the upgrade"
        );
    }
}
