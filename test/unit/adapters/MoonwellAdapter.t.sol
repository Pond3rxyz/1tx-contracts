// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {MoonwellAdapter} from "../../../src/adapters/MoonwellAdapter.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {MockMToken} from "../../mocks/MockMToken.sol";
import {MockMoonwellComptroller} from "../../mocks/MockMoonwellComptroller.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract MoonwellAdapterTest is AdapterTestBase {
    using CurrencyLibrary for Currency;

    MoonwellAdapter public adapter;
    MockMoonwellComptroller public mockComptroller;
    MockMToken public mockMToken;

    bytes32 public usdcMarketId;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address mToken);
    event MarketDeactivated(bytes32 indexed marketId);
    event DepositedToMoonwell(bytes32 indexed marketId, uint256 amount, address onBehalfOf);
    event WithdrawnFromMoonwell(bytes32 indexed marketId, uint256 amount, address to);

    function setUp() public override {
        super.setUp();

        // Deploy mock mToken
        mockMToken = new MockMToken(address(usdc), "Moonwell USDC", "mUSDC");

        // Deploy mock comptroller and add market
        mockComptroller = new MockMoonwellComptroller();
        mockComptroller.addMarket(address(mockMToken));

        // Fund mock mToken with USDC for withdrawals
        usdc.mint(address(mockMToken), INITIAL_BALANCE);

        // Deploy adapter
        vm.prank(owner);
        adapter = new MoonwellAdapter(address(mockComptroller), owner);

        // Pre-compute market ID
        usdcMarketId = _computeMarketId(usdcCurrency);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsComptroller() public view {
        assertEq(address(adapter.COMPTROLLER()), address(mockComptroller));
    }

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    function test_constructor_revertsOnZeroComptroller() public {
        vm.prank(owner);
        vm.expectRevert(MoonwellAdapter.InvalidComptrollerAddress.selector);
        new MoonwellAdapter(address(0), owner);
    }

    // ============ registerMarket Tests ============

    function test_registerMarket_success() public {
        vm.expectEmit(true, false, false, true);
        emit MarketRegistered(usdcMarketId, usdcCurrency, address(mockMToken));

        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        assertTrue(adapter.hasMarket(usdcMarketId));
        assertEq(adapter.getYieldToken(usdcMarketId), address(mockMToken));
        assertEq(Currency.unwrap(adapter.getMarketCurrency(usdcMarketId)), address(usdc));
    }

    function test_registerMarket_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerMarket(usdcCurrency, address(mockMToken));
    }

    function test_registerMarket_revertsOnNativeCurrency() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerMarket(nativeCurrency, address(mockMToken));
    }

    function test_registerMarket_revertsOnZeroMToken() public {
        vm.prank(owner);
        vm.expectRevert(MoonwellAdapter.InvalidMTokenAddress.selector);
        adapter.registerMarket(usdcCurrency, address(0));
    }

    function test_registerMarket_revertsIfNotListedInComptroller() public {
        // Create an mToken not in comptroller
        MockMToken unlistedMToken = new MockMToken(address(usdc), "Unlisted USDC", "uUSDC");

        vm.prank(owner);
        vm.expectRevert(MoonwellAdapter.MarketNotListedInComptroller.selector);
        adapter.registerMarket(usdcCurrency, address(unlistedMToken));
    }

    function test_registerMarket_revertsOnAssetMismatch() public {
        // Create mToken for USDT but try to register with USDC currency
        MockMToken mUsdt = new MockMToken(address(usdt), "Moonwell USDT", "mUSDT");
        mockComptroller.addMarket(address(mUsdt));

        vm.prank(owner);
        vm.expectRevert(AdapterBase.AssetMismatch.selector);
        adapter.registerMarket(usdcCurrency, address(mUsdt));
    }

    function test_registerMarket_revertsIfAlreadyRegistered() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        vm.prank(owner);
        vm.expectRevert(AdapterBase.MarketAlreadyRegistered.selector);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
    }

    // ============ deactivateMarket Tests ============

    function test_deactivateMarket_success() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        assertTrue(adapter.hasMarket(usdcMarketId));

        vm.expectEmit(true, false, false, false);
        emit MarketDeactivated(usdcMarketId);

        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);

        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    function test_deactivateMarket_revertsIfNotActive() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deactivateMarket(usdcMarketId);
    }

    function test_deactivateMarket_revertsOnNonOwner() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.deactivateMarket(usdcMarketId);
    }

    // ============ deposit Tests ============

    function test_deposit_success() public {
        // Setup
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.expectEmit(true, false, false, true);
        emit DepositedToMoonwell(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        // Check balances
        assertEq(usdc.balanceOf(user), userBalanceBefore - DEPOSIT_AMOUNT);
        assertEq(mockMToken.balanceOf(recipient), DEPOSIT_AMOUNT); // 1:1 exchange rate in mock
    }

    function test_deposit_revertsIfMarketNotActive() public {
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(usdcMarketId, 0, recipient);
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, address(0));
    }

    function test_deposit_revertsOnMintFailure() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        // Set mint to fail
        mockMToken.setMintFail(true, 1);

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MoonwellAdapter.MintFailed.selector, 1));
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    // ============ withdraw Tests ============

    function test_withdraw_success() public {
        // Setup: register market and authorize caller
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits first
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, user);

        // Transfer mTokens to adapter (simulating hook behavior)
        vm.prank(user);
        mockMToken.transfer(address(adapter), DEPOSIT_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnFromMoonwell(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + DEPOSIT_AMOUNT);
    }

    function test_withdraw_revertsIfUnauthorized() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

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
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(usdcMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, address(0));
    }

    function test_withdraw_revertsOnRedeemFailure() public {
        // Setup: register market and authorize caller
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits first
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, user);

        // Transfer mTokens to adapter
        vm.prank(user);
        mockMToken.transfer(address(adapter), DEPOSIT_AMOUNT);

        // Set redeem to fail
        mockMToken.setRedeemFail(true, 2);

        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(MoonwellAdapter.RedeemFailed.selector, 2));
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    // ============ getYieldToken Tests ============

    function test_getYieldToken_returnsCorrectMToken() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        assertEq(adapter.getYieldToken(usdcMarketId), address(mockMToken));
    }

    function test_getYieldToken_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getYieldToken(usdcMarketId);
    }

    // ============ getMarketCurrency Tests ============

    function test_getMarketCurrency_returnsCorrectCurrency() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

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
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        assertTrue(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseForInactiveMarket() public view {
        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseAfterDeactivation() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);

        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    // ============ getAdapterMetadata Tests ============

    function test_getAdapterMetadata_returnsCorrectName() public view {
        MoonwellAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.name, "Moonwell");
    }

    function test_getAdapterMetadata_returnsCorrectChainId() public view {
        MoonwellAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.chainId, block.chainid);
    }

    // ============ requiresAllow Tests ============

    function test_requiresAllow_returnsFalse() public view {
        assertFalse(adapter.requiresAllow());
    }

    // ============ Multiple Markets Tests ============

    function test_multipleMarkets() public {
        // Create another mToken for USDT
        MockMToken mUsdt = new MockMToken(address(usdt), "Moonwell USDT", "mUSDT");
        mockComptroller.addMarket(address(mUsdt));

        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        adapter.registerMarket(usdtCurrency, address(mUsdt));
        vm.stopPrank();

        bytes32 usdtMarketId = _computeMarketId(usdtCurrency);

        assertTrue(adapter.hasMarket(usdcMarketId));
        assertTrue(adapter.hasMarket(usdtMarketId));
        assertEq(adapter.getYieldToken(usdcMarketId), address(mockMToken));
        assertEq(adapter.getYieldToken(usdtMarketId), address(mUsdt));
    }

    // ============ Exchange Rate Tests ============

    function test_deposit_withDifferentExchangeRate() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));

        // Set exchange rate to 2:1 (2 underlying = 1 mToken)
        mockMToken.setExchangeRate(2e18);

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        // Should receive half the mTokens due to 2:1 exchange rate
        assertEq(mockMToken.balanceOf(recipient), DEPOSIT_AMOUNT / 2);
    }

    function test_withdraw_withDifferentExchangeRate() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockMToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits with 1:1 rate
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, user);

        // Change exchange rate to 2:1 (simulating yield accrual)
        mockMToken.setExchangeRate(2e18);

        // Transfer mTokens to adapter
        vm.prank(user);
        mockMToken.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        // Should receive double due to 2:1 exchange rate
        assertEq(withdrawn, DEPOSIT_AMOUNT * 2);
    }
}
