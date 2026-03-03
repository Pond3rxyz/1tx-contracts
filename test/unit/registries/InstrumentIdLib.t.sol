// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";

contract InstrumentIdLibTest is Test {
    // ============ generateSingleAssetMarketId Tests ============

    function test_singleAssetMarketId_deterministic() public pure {
        Currency currency = Currency.wrap(address(0x1234));
        bytes32 id1 = InstrumentIdLib.generateSingleAssetMarketId(currency);
        bytes32 id2 = InstrumentIdLib.generateSingleAssetMarketId(currency);
        assertEq(id1, id2);
    }

    function test_singleAssetMarketId_differentCurrenciesDifferentIds() public pure {
        Currency a = Currency.wrap(address(0x1));
        Currency b = Currency.wrap(address(0x2));
        assertTrue(InstrumentIdLib.generateSingleAssetMarketId(a) != InstrumentIdLib.generateSingleAssetMarketId(b));
    }

    function test_singleAssetMarketId_matchesKeccak() public pure {
        Currency currency = Currency.wrap(address(0xABCD));
        assertEq(InstrumentIdLib.generateSingleAssetMarketId(currency), keccak256(abi.encode(currency)));
    }

    // ============ generatePairMarketId Tests ============

    function test_pairMarketId_deterministic() public pure {
        Currency a = Currency.wrap(address(0x1));
        Currency b = Currency.wrap(address(0x2));
        assertEq(InstrumentIdLib.generatePairMarketId(a, b), InstrumentIdLib.generatePairMarketId(a, b));
    }

    function test_pairMarketId_isDirectional() public pure {
        Currency a = Currency.wrap(address(0x1));
        Currency b = Currency.wrap(address(0x2));
        assertTrue(InstrumentIdLib.generatePairMarketId(a, b) != InstrumentIdLib.generatePairMarketId(b, a));
    }

    function test_pairMarketId_matchesKeccak() public pure {
        Currency a = Currency.wrap(address(0x1));
        Currency b = Currency.wrap(address(0x2));
        assertEq(InstrumentIdLib.generatePairMarketId(a, b), keccak256(abi.encode(a, b)));
    }

    // ============ generateInstrumentId Tests ============

    function test_instrumentId_embedsChainId() public pure {
        bytes32 id = InstrumentIdLib.generateInstrumentId(8453, address(0x1), bytes32(uint256(1)));
        uint32 extractedChainId = InstrumentIdLib.getInstrumentChainId(id);
        assertEq(extractedChainId, 8453);
    }

    function test_instrumentId_deterministic() public pure {
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(1)));
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(1)));
        assertEq(id1, id2);
    }

    function test_instrumentId_differentChainIdsDifferentIds() public pure {
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(1)));
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(2, address(0x1), bytes32(uint256(1)));
        assertTrue(id1 != id2);
    }

    function test_instrumentId_differentExecutionAddressesDifferentIds() public pure {
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(1)));
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(1, address(0x2), bytes32(uint256(1)));
        assertTrue(id1 != id2);
    }

    function test_instrumentId_differentMarketIdsDifferentIds() public pure {
        bytes32 id1 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(1)));
        bytes32 id2 = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(uint256(2)));
        assertTrue(id1 != id2);
    }

    // ============ getInstrumentChainId Tests ============

    function test_getChainId_ethereum() public pure {
        bytes32 id = InstrumentIdLib.generateInstrumentId(1, address(0x1), bytes32(0));
        assertEq(InstrumentIdLib.getInstrumentChainId(id), 1);
    }

    function test_getChainId_base() public pure {
        bytes32 id = InstrumentIdLib.generateInstrumentId(8453, address(0x1), bytes32(0));
        assertEq(InstrumentIdLib.getInstrumentChainId(id), 8453);
    }

    function test_getChainId_arbitrum() public pure {
        bytes32 id = InstrumentIdLib.generateInstrumentId(42161, address(0x1), bytes32(0));
        assertEq(InstrumentIdLib.getInstrumentChainId(id), 42161);
    }

    function test_getChainId_maxUint32() public pure {
        uint256 maxChain = type(uint32).max;
        bytes32 id = InstrumentIdLib.generateInstrumentId(maxChain, address(0x1), bytes32(0));
        assertEq(InstrumentIdLib.getInstrumentChainId(id), type(uint32).max);
    }

    // ============ Fuzz Tests ============

    function testFuzz_instrumentId_chainIdRoundtrip(uint32 chainId, address exec, bytes32 mktId) public pure {
        bytes32 id = InstrumentIdLib.generateInstrumentId(uint256(chainId), exec, mktId);
        assertEq(InstrumentIdLib.getInstrumentChainId(id), chainId);
    }

    function testFuzz_singleAssetMarketId_deterministic(address token) public pure {
        Currency currency = Currency.wrap(token);
        assertEq(
            InstrumentIdLib.generateSingleAssetMarketId(currency),
            InstrumentIdLib.generateSingleAssetMarketId(currency)
        );
    }
}
