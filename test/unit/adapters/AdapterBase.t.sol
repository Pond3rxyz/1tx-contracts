// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterBaseUpgradeable as AdapterBase} from "../../../src/adapters/base/AdapterBaseUpgradeable.sol";
import {ILendingAdapter} from "../../../src/interfaces/ILendingAdapter.sol";

/// @title ConcreteAdapter
/// @notice Concrete implementation of AdapterBaseUpgradeable for testing
contract ConcreteAdapter is AdapterBase {
    using CurrencyLibrary for Currency;

    mapping(bytes32 => bool) public activeMarkets;

    function initialize(address initialOwner) external initializer {
        __AdapterBase_init(initialOwner);
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
        view
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

    event AuthorizedCallerUpdated(address indexed caller, bool allowed);

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        authorizedCaller = makeAddr("authorizedCaller");

        ConcreteAdapter impl = new ConcreteAdapter();
        adapter = ConcreteAdapter(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(ConcreteAdapter.initialize, (owner))))
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    // ============ setAuthorizedCaller Tests ============

    function test_setAuthorizedCaller_authorizesCaller() public {
        vm.expectEmit(true, false, false, true);
        emit AuthorizedCallerUpdated(authorizedCaller, true);

        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, true);

        assertTrue(adapter.authorizedCallers(authorizedCaller));
    }

    function test_setAuthorizedCaller_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.InvalidAuthorizedCaller.selector);
        adapter.setAuthorizedCaller(address(0), true);
    }

    function test_setAuthorizedCaller_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.setAuthorizedCaller(authorizedCaller, true);
    }

    function test_setAuthorizedCaller_removesCaller() public {
        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, true);
        assertTrue(adapter.authorizedCallers(authorizedCaller));

        vm.expectEmit(true, false, false, true);
        emit AuthorizedCallerUpdated(authorizedCaller, false);

        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, false);

        assertFalse(adapter.authorizedCallers(authorizedCaller));
    }

    function test_setAuthorizedCaller_revertsOnRemoveByNonOwner() public {
        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.setAuthorizedCaller(authorizedCaller, false);
    }

    // ============ onlyAuthorizedCaller Modifier Tests ============

    function test_onlyAuthorizedCaller_success() public {
        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, true);

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
        adapter.setAuthorizedCaller(authorizedCaller, true);
        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, false);

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

    // ============ Multiple Authorized Callers Tests ============

    function test_multipleAuthorizedCallers() public {
        address caller1 = makeAddr("caller1");
        address caller2 = makeAddr("caller2");
        address caller3 = makeAddr("caller3");

        vm.startPrank(owner);
        adapter.setAuthorizedCaller(caller1, true);
        adapter.setAuthorizedCaller(caller2, true);
        adapter.setAuthorizedCaller(caller3, true);
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
        adapter.setAuthorizedCaller(authorizedCaller, true);

        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, true);

        assertTrue(adapter.authorizedCallers(authorizedCaller));
    }

    function test_removingNonExistentCallerIsNoOp() public {
        assertFalse(adapter.authorizedCallers(authorizedCaller));

        vm.prank(owner);
        adapter.setAuthorizedCaller(authorizedCaller, false);

        assertFalse(adapter.authorizedCallers(authorizedCaller));
    }
}
