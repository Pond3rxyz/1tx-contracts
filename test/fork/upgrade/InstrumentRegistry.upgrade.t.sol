// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {InstrumentRegistryV1} from "./legacy/InstrumentRegistryV1.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract LegacyMockLendingAdapter {
    struct AdapterMetadata {
        string name;
        uint256 chainId;
    }

    struct MarketInfo {
        bool active;
        address yieldToken;
        Currency currency;
    }

    uint256 public immutable adapterChainId;
    mapping(bytes32 => MarketInfo) public markets;

    constructor(string memory, uint256 _chainId) {
        adapterChainId = _chainId;
    }

    function addMockMarket(bytes32 marketId, address yieldToken, Currency currency) external {
        markets[marketId] = MarketInfo({active: true, yieldToken: yieldToken, currency: currency});
    }

    function getAdapterMetadata() external view returns (AdapterMetadata memory) {
        return AdapterMetadata({name: "Aave V3", chainId: adapterChainId});
    }

    function hasMarket(bytes32 marketId) external view returns (bool) {
        return markets[marketId].active;
    }

    function getYieldToken(bytes32 marketId) external view returns (address) {
        return markets[marketId].yieldToken;
    }
}

contract InstrumentRegistryUpgradeTest is Test {
    using CurrencyLibrary for Currency;

    InstrumentRegistryV1 public proxy;
    LegacyMockLendingAdapter public adapter;
    MockERC20 public usdc;
    MockERC20 public aUsdc;

    address public owner = makeAddr("owner");
    address public executionAddress = makeAddr("executionAddress");

    bytes32 public marketId;
    bytes32 public instrumentId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        adapter = new LegacyMockLendingAdapter("Aave V3", block.chainid);
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
        (address adapterBefore, bytes32 marketIdBefore) = proxy.instruments(instrumentId);

        InstrumentRegistry newImpl = new InstrumentRegistry();

        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        InstrumentRegistry upgraded = InstrumentRegistry(address(proxy));
        (address adapterAfter, bytes32 marketIdAfter) = upgraded.instruments(instrumentId);

        assertEq(adapterBefore, address(adapter));
        assertEq(marketIdBefore, marketId);
        assertEq(adapterAfter, adapterBefore, "adapter changed across upgrade");
        assertEq(marketIdAfter, marketIdBefore, "marketId changed across upgrade");
        assertTrue(adapterAfter != address(0), "instrument missing after upgrade");

        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InstrumentAlreadyRegistered.selector);
        upgraded.registerInstrument(executionAddress, marketId, address(adapter));

        bytes32 unknownMarketId = keccak256("unknown-market");
        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.MarketNotRegisteredInAdapter.selector);
        upgraded.registerInstrument(executionAddress, unknownMarketId, address(adapter));
    }
}
