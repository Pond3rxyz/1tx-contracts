// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {InstrumentRegistryV1} from "./legacy/InstrumentRegistryV1.sol";
import {MockLendingAdapter} from "../../mocks/MockLendingAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract InstrumentRegistryUpgradeTest is Test {
    using CurrencyLibrary for Currency;

    InstrumentRegistryV1 public proxy;
    MockLendingAdapter public adapter;
    MockERC20 public usdc;
    MockERC20 public aUsdc;

    address public owner = makeAddr("owner");
    address public executionAddress = makeAddr("executionAddress");

    bytes32 public marketId;
    bytes32 public instrumentId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        adapter = new MockLendingAdapter("Aave V3", block.chainid);
        marketId = keccak256(abi.encode(Currency.wrap(address(usdc))));
        adapter.addMockMarket(marketId, address(aUsdc), Currency.wrap(address(usdc)));

        instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, marketId);

        InstrumentRegistryV1 impl = new InstrumentRegistryV1();
        proxy = InstrumentRegistryV1(
            address(
                new ERC1967Proxy(address(impl), abi.encodeWithSelector(InstrumentRegistryV1.initialize.selector, owner))
            )
        );

        vm.prank(owner);
        proxy.registerInstrument(executionAddress, marketId, address(adapter));
    }

    function test_upgrade_preservesStateAndRegistrationGuards() public {
        InstrumentRegistry.InstrumentInfo memory infoBefore =
            InstrumentRegistry(address(proxy)).getInstrument(instrumentId);

        InstrumentRegistry newImpl = new InstrumentRegistry();

        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        InstrumentRegistry upgraded = InstrumentRegistry(address(proxy));
        InstrumentRegistry.InstrumentInfo memory infoAfter = upgraded.getInstrument(instrumentId);

        assertEq(infoBefore.adapter, address(adapter));
        assertEq(infoBefore.marketId, marketId);
        assertEq(infoAfter.adapter, infoBefore.adapter, "adapter changed across upgrade");
        assertEq(infoAfter.marketId, infoBefore.marketId, "marketId changed across upgrade");
        assertTrue(upgraded.isInstrumentRegistered(instrumentId), "instrument missing after upgrade");

        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InstrumentAlreadyRegistered.selector);
        upgraded.registerInstrument(executionAddress, marketId, address(adapter));

        bytes32 unknownMarketId = keccak256("unknown-market");
        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.MarketNotRegisteredInAdapter.selector);
        upgraded.registerInstrument(executionAddress, unknownMarketId, address(adapter));
    }
}
