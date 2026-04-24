// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {MockLendingAdapter} from "../../mocks/MockLendingAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract InstrumentRegistryTest is Test {
    using CurrencyLibrary for Currency;

    InstrumentRegistry public registry;
    MockLendingAdapter public adapter;
    MockERC20 public usdc;
    MockERC20 public aUsdc;

    address public owner;
    address public user;
    address public executionAddress;

    bytes32 public marketId;
    bytes32 public instrumentId;

    event InstrumentRegistered(
        bytes32 indexed instrumentId,
        address indexed adapter,
        uint256 chainId,
        address executionAddress,
        bytes32 marketId
    );
    event InstrumentUnregistered(bytes32 indexed instrumentId);

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        executionAddress = makeAddr("executionAddress");

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        // Deploy mock adapter (matching current chain)
        adapter = new MockLendingAdapter("Aave V3", block.chainid);

        // Compute market ID and register in adapter
        marketId = keccak256(abi.encode(Currency.wrap(address(usdc))));
        adapter.addMockMarket(marketId, address(aUsdc), Currency.wrap(address(usdc)));

        // Deploy registry via proxy
        InstrumentRegistry impl = new InstrumentRegistry();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner));
        registry = InstrumentRegistry(address(proxy));

        // Pre-compute expected instrument ID
        instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, marketId);
    }

    // ============ Initialize Tests ============

    function test_initialize_setsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        registry.initialize(user);
    }

    // ============ registerInstrument Tests ============

    function test_registerInstrument_success() public {
        vm.expectEmit(true, true, false, true);
        emit InstrumentRegistered(instrumentId, address(adapter), block.chainid, executionAddress, marketId);

        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        assertTrue(registry.isInstrumentRegistered(instrumentId));
    }

    function test_registerInstrument_storesCorrectData() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        InstrumentRegistry.InstrumentInfo memory info = registry.getInstrument(instrumentId);
        assertEq(info.adapter, address(adapter));
        assertEq(info.marketId, marketId);
    }

    function test_registerInstrument_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        registry.registerInstrument(executionAddress, marketId, address(adapter));
    }

    function test_registerInstrument_revertsOnZeroAdapter() public {
        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InvalidAdapterAddress.selector);
        registry.registerInstrument(executionAddress, marketId, address(0));
    }

    function test_registerInstrument_revertsOnZeroExecutionAddress() public {
        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InvalidExecutionAddress.selector);
        registry.registerInstrument(address(0), marketId, address(adapter));
    }

    function test_registerInstrument_revertsIfMarketNotInAdapter() public {
        bytes32 unknownMarketId = keccak256("unknown");

        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.MarketNotRegisteredInAdapter.selector);
        registry.registerInstrument(executionAddress, unknownMarketId, address(adapter));
    }

    function test_registerInstrument_revertsIfAlreadyRegistered() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InstrumentAlreadyRegistered.selector);
        registry.registerInstrument(executionAddress, marketId, address(adapter));
    }

    function test_registerInstrument_generatesCorrectInstrumentId() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        // Verify the instrument ID matches the library's output
        bytes32 expectedId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, marketId);
        assertTrue(registry.isInstrumentRegistered(expectedId));
    }

    function test_registerInstrument_multipleInstruments() public {
        // Register first instrument
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        // Setup second instrument (USDT)
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        MockERC20 aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);
        bytes32 usdtMarketId = keccak256(abi.encode(Currency.wrap(address(usdt))));
        adapter.addMockMarket(usdtMarketId, address(aUsdt), Currency.wrap(address(usdt)));

        bytes32 usdtInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdtMarketId);

        vm.prank(owner);
        registry.registerInstrument(executionAddress, usdtMarketId, address(adapter));

        assertTrue(registry.isInstrumentRegistered(instrumentId));
        assertTrue(registry.isInstrumentRegistered(usdtInstrumentId));
    }

    // ============ unregisterInstrument Tests ============

    function test_unregisterInstrument_success() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));
        assertTrue(registry.isInstrumentRegistered(instrumentId));

        vm.expectEmit(true, false, false, false);
        emit InstrumentUnregistered(instrumentId);

        vm.prank(owner);
        registry.unregisterInstrument(instrumentId);

        assertFalse(registry.isInstrumentRegistered(instrumentId));
    }

    function test_unregisterInstrument_revertsOnNonOwner() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        registry.unregisterInstrument(instrumentId);
    }

    function test_unregisterInstrument_revertsIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        registry.unregisterInstrument(instrumentId);
    }

    function test_unregisterInstrument_canReRegisterAfterUnregister() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        vm.prank(owner);
        registry.unregisterInstrument(instrumentId);
        assertFalse(registry.isInstrumentRegistered(instrumentId));

        // Re-register should succeed
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));
        assertTrue(registry.isInstrumentRegistered(instrumentId));
    }

    // ============ getInstrument Tests ============

    function test_getInstrument_returnsCorrectInfo() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        InstrumentRegistry.InstrumentInfo memory info = registry.getInstrument(instrumentId);
        assertEq(info.adapter, address(adapter));
        assertEq(info.marketId, marketId);
    }

    function test_getInstrument_revertsIfNotRegistered() public {
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        registry.getInstrument(instrumentId);
    }

    // ============ getInstrumentDirect Tests ============

    function test_getInstrumentDirect_returnsCorrectValues() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        (address adapterAddr, bytes32 mktId) = registry.getInstrumentDirect(instrumentId);
        assertEq(adapterAddr, address(adapter));
        assertEq(mktId, marketId);
    }

    function test_getInstrumentDirect_revertsIfNotRegistered() public {
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        registry.getInstrumentDirect(instrumentId);
    }

    // ============ isInstrumentRegistered Tests ============

    function test_isInstrumentRegistered_returnsTrueWhenRegistered() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        assertTrue(registry.isInstrumentRegistered(instrumentId));
    }

    function test_isInstrumentRegistered_returnsFalseWhenNotRegistered() public view {
        assertFalse(registry.isInstrumentRegistered(instrumentId));
    }

    function test_isInstrumentRegistered_returnsFalseAfterUnregister() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        vm.prank(owner);
        registry.unregisterInstrument(instrumentId);

        assertFalse(registry.isInstrumentRegistered(instrumentId));
    }

    // ============ getInstrumentDetails Tests ============

    function test_getInstrumentDetails_returnsCompleteInfo() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        (address adapterAddr, bytes32 mktId, address yieldToken, uint8 decimals) =
            registry.getInstrumentDetails(instrumentId);

        assertEq(adapterAddr, address(adapter));
        assertEq(mktId, marketId);
        assertEq(yieldToken, address(aUsdc));
        assertEq(decimals, 6);
    }

    function test_getInstrumentDetails_revertsIfNotRegistered() public {
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        registry.getInstrumentDetails(instrumentId);
    }

    function test_getInstrumentDetails_handlesMultipleDecimals() public {
        // Create 18-decimal token
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockERC20 aDai = new MockERC20("Aave DAI", "aDAI", 18);
        bytes32 daiMarketId = keccak256(abi.encode(Currency.wrap(address(dai))));
        adapter.addMockMarket(daiMarketId, address(aDai), Currency.wrap(address(dai)));

        address daiExec = makeAddr("daiExec");
        bytes32 daiInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, daiExec, daiMarketId);

        vm.prank(owner);
        registry.registerInstrument(daiExec, daiMarketId, address(adapter));

        (,,, uint8 decimals) = registry.getInstrumentDetails(daiInstrumentId);
        assertEq(decimals, 18);
    }

    // ============ getInstrumentChainId Tests ============

    function test_getInstrumentChainId_extractsCorrectChainId() public {
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        uint32 chainId = registry.getInstrumentChainId(instrumentId);
        assertEq(chainId, uint32(block.chainid));
    }

    function test_getInstrumentChainId_worksWithDifferentChainIds() public pure {
        // Test with various chain IDs
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(0));
        bytes32 id8453 = InstrumentIdLib.generateInstrumentId(8453, address(0x1), bytes32(0));
        bytes32 id42161 = InstrumentIdLib.generateInstrumentId(42161, address(0x1), bytes32(0));

        assertEq(InstrumentIdLib.getInstrumentChainId(id1), 1);
        assertEq(InstrumentIdLib.getInstrumentChainId(id8453), 8453);
        assertEq(InstrumentIdLib.getInstrumentChainId(id42161), 42161);
    }

    // ============ InstrumentIdLib Tests ============

    function test_instrumentIdLib_singleAssetMarketId() public view {
        bytes32 expected = keccak256(abi.encode(Currency.wrap(address(usdc))));
        assertEq(InstrumentIdLib.generateSingleAssetMarketId(Currency.wrap(address(usdc))), expected);
    }

    function test_instrumentIdLib_pairMarketId() public view {
        Currency collateral = Currency.wrap(address(usdc));
        Currency borrow = Currency.wrap(address(aUsdc));

        bytes32 expected = keccak256(abi.encode(collateral, borrow));
        assertEq(InstrumentIdLib.generatePairMarketId(collateral, borrow), expected);
    }

    function test_instrumentIdLib_pairMarketIdIsDirectional() public view {
        Currency a = Currency.wrap(address(usdc));
        Currency b = Currency.wrap(address(aUsdc));

        bytes32 ab = InstrumentIdLib.generatePairMarketId(a, b);
        bytes32 ba = InstrumentIdLib.generatePairMarketId(b, a);
        assertTrue(ab != ba);
    }

    function test_instrumentIdLib_differentInputsProduceDifferentIds() public pure {
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(1)));
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(1, address(0x2), bytes32(uint256(1)));
        bytes32 id3 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(2)));
        bytes32 id4 = InstrumentIdLib.generateInstrumentId(2, address(0x1), bytes32(uint256(1)));

        assertTrue(id1 != id2);
        assertTrue(id1 != id3);
        assertTrue(id1 != id4);
        assertTrue(id2 != id3);
    }

    function test_instrumentIdLib_deterministicGeneration() public pure {
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(8453, address(0xABC), bytes32(uint256(42)));
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(8453, address(0xABC), bytes32(uint256(42)));
        assertEq(id1, id2);
    }

    // ============ Edge Cases ============

    function test_unregisterInstrument_doesNotAffectOtherInstruments() public {
        // Register two instruments
        vm.prank(owner);
        registry.registerInstrument(executionAddress, marketId, address(adapter));

        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        MockERC20 aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);
        bytes32 usdtMarketId = keccak256(abi.encode(Currency.wrap(address(usdt))));
        adapter.addMockMarket(usdtMarketId, address(aUsdt), Currency.wrap(address(usdt)));

        address exec2 = makeAddr("exec2");
        bytes32 usdtInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, exec2, usdtMarketId);

        vm.prank(owner);
        registry.registerInstrument(exec2, usdtMarketId, address(adapter));

        // Unregister first
        vm.prank(owner);
        registry.unregisterInstrument(instrumentId);

        // Second should still exist
        assertFalse(registry.isInstrumentRegistered(instrumentId));
        assertTrue(registry.isInstrumentRegistered(usdtInstrumentId));
    }

    function test_registerInstrument_differentExecutionAddressesDifferentIds() public {
        address exec1 = makeAddr("exec1");
        address exec2 = makeAddr("exec2");

        bytes32 id1 = InstrumentIdLib.generateInstrumentId(block.chainid, exec1, marketId);
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(block.chainid, exec2, marketId);

        // Should produce different instrument IDs
        assertTrue(id1 != id2);

        // Both should be registerable
        vm.prank(owner);
        registry.registerInstrument(exec1, marketId, address(adapter));

        vm.prank(owner);
        registry.registerInstrument(exec2, marketId, address(adapter));

        assertTrue(registry.isInstrumentRegistered(id1));
        assertTrue(registry.isInstrumentRegistered(id2));
    }
}
