// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {ILendingAdapter} from "../../../src/interfaces/ILendingAdapter.sol";

/// @title ConcreteAdapter
/// @notice Concrete implementation of AdapterBase for testing
contract ConcreteAdapter is AdapterBase {
    using CurrencyLibrary for Currency;

    mapping(bytes32 => bool) public activeMarkets;

    constructor(address initialOwner) AdapterBase(initialOwner) {}

    function getAdapterMetadata() external pure override returns (AdapterMetadata memory) {
        return AdapterMetadata({name: "Test Adapter", chainId: 1});
    }

    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return activeMarkets[marketId];
    }

    function deposit(bytes32, uint256 amount, address recipient)
        external
        override
        validDepositWithdrawParams(amount, recipient)
    {}

    function withdraw(bytes32, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256)
    {
        return amount;
    }

    function getYieldToken(bytes32) external pure override returns (address) {
        return address(0);
    }

    function getMarketCurrency(bytes32) external pure override returns (Currency) {
        return CurrencyLibrary.ADDRESS_ZERO;
    }

    // Test helper: register a market with validCurrency check
    function registerMarket(Currency currency) external validCurrency(currency) {
        bytes32 marketId = keccak256(abi.encode(currency));
        activeMarkets[marketId] = true;
    }
}

contract AdapterBaseTest is Test {
    ConcreteAdapter public adapter;

    address public owner;
    address public user;
    address public authorizedCaller;

    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        authorizedCaller = makeAddr("authorizedCaller");

        vm.prank(owner);
        adapter = new ConcreteAdapter(owner);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    // ============ addAuthorizedCaller Tests ============

    function test_addAuthorizedCaller_success() public {
        vm.expectEmit(true, false, false, false);
        emit AuthorizedCallerAdded(authorizedCaller);

        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);

        assertTrue(adapter.authorizedCallers(authorizedCaller));
    }

    function test_addAuthorizedCaller_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.InvalidAuthorizedCaller.selector);
        adapter.addAuthorizedCaller(address(0));
    }

    function test_addAuthorizedCaller_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.addAuthorizedCaller(authorizedCaller);
    }

    // ============ removeAuthorizedCaller Tests ============

    function test_removeAuthorizedCaller_success() public {
        // First add the caller
        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);
        assertTrue(adapter.authorizedCallers(authorizedCaller));

        // Now remove
        vm.expectEmit(true, false, false, false);
        emit AuthorizedCallerRemoved(authorizedCaller);

        vm.prank(owner);
        adapter.removeAuthorizedCaller(authorizedCaller);

        assertFalse(adapter.authorizedCallers(authorizedCaller));
    }

    function test_removeAuthorizedCaller_revertsOnNonOwner() public {
        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.removeAuthorizedCaller(authorizedCaller);
    }

    // ============ onlyAuthorizedCaller Modifier Tests ============

    function test_onlyAuthorizedCaller_success() public {
        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);

        bytes32 marketId = keccak256("test");
        vm.prank(authorizedCaller);
        uint256 result = adapter.withdraw(marketId, 1000, user);
        assertEq(result, 1000);
    }

    function test_onlyAuthorizedCaller_revertsOnUnauthorized() public {
        bytes32 marketId = keccak256("test");

        vm.prank(user);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        adapter.withdraw(marketId, 1000, user);
    }

    function test_onlyAuthorizedCaller_revertsForRemovedCaller() public {
        // Add and then remove
        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.prank(owner);
        adapter.removeAuthorizedCaller(authorizedCaller);

        bytes32 marketId = keccak256("test");
        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        adapter.withdraw(marketId, 1000, user);
    }

    // ============ validDepositWithdrawParams Modifier Tests ============

    function test_validDepositWithdrawParams_success() public {
        bytes32 marketId = keccak256("test");
        // Should not revert
        adapter.deposit(marketId, 1000, user);
    }

    function test_validDepositWithdrawParams_revertsOnZeroAmount() public {
        bytes32 marketId = keccak256("test");

        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(marketId, 0, user);
    }

    function test_validDepositWithdrawParams_revertsOnZeroRecipient() public {
        bytes32 marketId = keccak256("test");

        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(marketId, 1000, address(0));
    }

    function test_validDepositWithdrawParams_revertsOnBothZero() public {
        bytes32 marketId = keccak256("test");

        // Zero amount check comes first
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(marketId, 0, address(0));
    }

    // ============ validCurrency Modifier Tests ============

    function test_validCurrency_success() public {
        address token = makeAddr("token");
        Currency currency = Currency.wrap(token);

        // Should not revert
        adapter.registerMarket(currency);
    }

    function test_validCurrency_revertsOnNativeCurrency() public {
        Currency nativeCurrency = CurrencyLibrary.ADDRESS_ZERO;

        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerMarket(nativeCurrency);
    }

    // ============ requiresAllow Tests ============

    function test_requiresAllow_returnsFalseByDefault() public view {
        assertFalse(adapter.requiresAllow());
    }

    // ============ Multiple Authorized Callers Tests ============

    function test_multipleAuthorizedCallers() public {
        address caller1 = makeAddr("caller1");
        address caller2 = makeAddr("caller2");
        address caller3 = makeAddr("caller3");

        vm.startPrank(owner);
        adapter.addAuthorizedCaller(caller1);
        adapter.addAuthorizedCaller(caller2);
        adapter.addAuthorizedCaller(caller3);
        vm.stopPrank();

        assertTrue(adapter.authorizedCallers(caller1));
        assertTrue(adapter.authorizedCallers(caller2));
        assertTrue(adapter.authorizedCallers(caller3));

        // All can withdraw
        bytes32 marketId = keccak256("test");

        vm.prank(caller1);
        assertEq(adapter.withdraw(marketId, 100, user), 100);

        vm.prank(caller2);
        assertEq(adapter.withdraw(marketId, 200, user), 200);

        vm.prank(caller3);
        assertEq(adapter.withdraw(marketId, 300, user), 300);
    }

    function test_addingCallerTwiceIsIdempotent() public {
        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);

        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);

        assertTrue(adapter.authorizedCallers(authorizedCaller));
    }

    function test_removingNonExistentCallerIsNoOp() public {
        assertFalse(adapter.authorizedCallers(authorizedCaller));

        vm.prank(owner);
        adapter.removeAuthorizedCaller(authorizedCaller);

        assertFalse(adapter.authorizedCallers(authorizedCaller));
    }
}
