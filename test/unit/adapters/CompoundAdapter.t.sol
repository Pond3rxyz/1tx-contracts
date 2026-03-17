// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {CompoundAdapter} from "../../../src/adapters/CompoundAdapter.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {MockCompoundComet} from "../../mocks/MockCompoundComet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract CompoundAdapterTest is AdapterTestBase {
    using CurrencyLibrary for Currency;

    CompoundAdapter public adapter;
    MockCompoundComet public mockComet;

    bytes32 public usdcMarketId;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address yieldToken);
    event MarketDeactivated(bytes32 indexed marketId);
    event DepositedToCompound(bytes32 indexed marketId, uint256 amount, address onBehalfOf);
    event WithdrawnFromCompound(bytes32 indexed marketId, uint256 amount, address to);

    function setUp() public override {
        super.setUp();

        // Deploy mock Comet
        mockComet = new MockCompoundComet(address(usdc));

        // Fund mock comet with USDC for withdrawals
        usdc.mint(address(mockComet), INITIAL_BALANCE);

        // Deploy adapter
        adapter = new CompoundAdapter(owner);

        // Pre-compute market ID
        usdcMarketId = _computeMarketId(usdcCurrency);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    // ============ registerMarket Tests ============

    function test_registerMarket_success() public {
        vm.expectEmit(true, false, false, true);
        emit MarketRegistered(usdcMarketId, usdcCurrency, address(mockComet));

        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        assertTrue(adapter.hasMarket(usdcMarketId));
        assertEq(adapter.getYieldToken(usdcMarketId), address(mockComet));
        assertEq(Currency.unwrap(adapter.getMarketCurrency(usdcMarketId)), address(usdc));
    }

    function test_registerMarket_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerMarket(usdcCurrency, address(mockComet));
    }

    function test_registerMarket_revertsOnNativeCurrency() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerMarket(nativeCurrency, address(mockComet));
    }

    function test_registerMarket_revertsOnZeroYieldToken() public {
        vm.prank(owner);
        vm.expectRevert(CompoundAdapter.InvalidYieldTokenAddress.selector);
        adapter.registerMarket(usdcCurrency, address(0));
    }

    function test_registerMarket_revertsIfAlreadyRegistered() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        vm.expectRevert(AdapterBase.MarketAlreadyRegistered.selector);
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));
    }

    // ============ deactivateMarket Tests ============

    function test_deactivateMarket_success() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));
        assertTrue(adapter.hasMarket(usdcMarketId));

        vm.expectEmit(true, false, false, false);
        emit MarketDeactivated(usdcMarketId);

        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);

        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    function test_deactivateMarket_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);
    }

    function test_deactivateMarket_revertsOnNonOwner() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.deactivateMarket(usdcMarketId);
    }

    // ============ deposit Tests ============

    function test_deposit_success() public {
        // Setup
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.expectEmit(true, false, false, true);
        emit DepositedToCompound(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        // Check balances
        assertEq(usdc.balanceOf(user), userBalanceBefore - DEPOSIT_AMOUNT);
        assertEq(mockComet.balanceOf(recipient), DEPOSIT_AMOUNT); // 1:1 in mock
    }

    function test_deposit_revertsIfMarketNotActive() public {
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(usdcMarketId, 0, recipient);
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ withdraw Tests ============

    function test_withdraw_success() public {
        // Setup: register market and authorize caller
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits first
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, user);

        // Transfer Comet tokens to adapter (simulating hook behavior)
        vm.prank(user);
        mockComet.transfer(address(adapter), DEPOSIT_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnFromCompound(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + DEPOSIT_AMOUNT);
    }

    function test_withdraw_revertsIfUnauthorized() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        vm.prank(user);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsIfMarketNotActive() public {
        vm.startPrank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(usdcMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ getYieldToken Tests ============

    function test_getYieldToken_returnsCorrectComet() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        assertEq(adapter.getYieldToken(usdcMarketId), address(mockComet));
    }

    function test_getYieldToken_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getYieldToken(usdcMarketId);
    }

    // ============ getMarketCurrency Tests ============

    function test_getMarketCurrency_returnsCorrectCurrency() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        Currency currency = adapter.getMarketCurrency(usdcMarketId);
        assertEq(Currency.unwrap(currency), address(usdc));
    }

    function test_getMarketCurrency_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getMarketCurrency(usdcMarketId);
    }

    // ============ hasMarket Tests ============

    function test_hasMarket_returnsTrueForActiveMarket() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        assertTrue(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseForInactiveMarket() public view {
        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseAfterDeactivation() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));

        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);

        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    // ============ getAdapterMetadata Tests ============

    function test_getAdapterMetadata_returnsCorrectName() public view {
        CompoundAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.name, "Compound V3");
    }

    function test_getAdapterMetadata_returnsCorrectChainId() public view {
        CompoundAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.chainId, block.chainid);
    }

    // ============ requiresAllow Tests ============

    function test_requiresAllow_returnsTrue() public view {
        assertTrue(adapter.requiresAllow());
    }

    // ============ Multiple Markets Tests ============

    function test_multipleMarkets() public {
        // Create another comet for USDT
        MockCompoundComet usdtComet = new MockCompoundComet(address(usdt));

        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockComet));
        adapter.registerMarket(usdtCurrency, address(usdtComet));
        vm.stopPrank();

        bytes32 usdtMarketId = _computeMarketId(usdtCurrency);

        assertTrue(adapter.hasMarket(usdcMarketId));
        assertTrue(adapter.hasMarket(usdtMarketId));
        assertEq(adapter.getYieldToken(usdcMarketId), address(mockComet));
        assertEq(adapter.getYieldToken(usdtMarketId), address(usdtComet));
    }
}
