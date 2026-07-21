// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {CompoundAdapter} from "../../../src/adapters/CompoundAdapter.sol";
import {CompoundAdapterV1} from "./legacy/CompoundAdapterV1.sol";
import {MockCompoundComet} from "../../mocks/MockCompoundComet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title CompoundAdapter upgrade tests (V1 snapshot -> current)
/// @dev Validates storage layout against the V1 snapshot, then upgrades a V1 proxy in place and
///      asserts markets + authorizedCallers survive.
///      Requires a full build: `forge clean && forge build && forge test --mc CompoundAdapterUpgradeTest`.
contract CompoundAdapterUpgradeTest is Test {
    CompoundAdapterV1 public proxy;
    MockCompoundComet public comet;
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public caller = makeAddr("router");

    Currency public currency;
    bytes32 public marketId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        comet = new MockCompoundComet(address(usdc));

        currency = Currency.wrap(address(usdc));
        marketId = keccak256(abi.encode(currency));

        CompoundAdapterV1 impl = new CompoundAdapterV1();
        proxy = CompoundAdapterV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(CompoundAdapterV1.initialize, (owner))))
        );

        vm.startPrank(owner);
        proxy.registerMarket(currency, address(comet));
        proxy.setAuthorizedCaller(caller, true);
        vm.stopPrank();
    }

    function test_validateUpgrade_referenceV1() public {
        Options memory opts;
        opts.referenceContract = "CompoundAdapterV1.sol:CompoundAdapterV1";
        Upgrades.validateUpgrade("CompoundAdapter.sol", opts);
    }

    function test_upgradeFromV1_preservesState() public {
        assertTrue(proxy.hasMarket(marketId), "market missing before upgrade");
        assertTrue(proxy.authorizedCallers(caller), "caller missing before upgrade");

        CompoundAdapter newImpl = new CompoundAdapter();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        CompoundAdapter upgraded = CompoundAdapter(address(proxy));
        assertTrue(upgraded.hasMarket(marketId), "market lost across upgrade");
        assertEq(upgraded.getYieldToken(marketId), address(comet), "yieldToken shifted");
        assertEq(Currency.unwrap(upgraded.getMarketCurrency(marketId)), address(usdc), "currency shifted");
        assertTrue(upgraded.authorizedCallers(caller), "authorizedCaller lost across upgrade");
        assertTrue(upgraded.requiresAllow(), "requiresAllow changed");
        assertEq(upgraded.owner(), owner, "owner shifted");
    }
}
