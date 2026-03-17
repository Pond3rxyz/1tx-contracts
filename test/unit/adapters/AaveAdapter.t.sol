// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract AaveAdapterTest is AdapterTestBase {
    using CurrencyLibrary for Currency;

    AaveAdapter public adapter;
    MockAavePool public mockPool;
    MockERC20 public aUsdc;

    bytes32 public usdcMarketId;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address yieldToken);
    event MarketDeactivated(bytes32 indexed marketId);
    event DepositedToAave(bytes32 indexed marketId, uint256 amount, address onBehalfOf);
    event WithdrawnFromAave(bytes32 indexed marketId, uint256 amount, address to);

    function setUp() public override {
        super.setUp();

        // Deploy mock aToken
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        // Deploy mock pool
        mockPool = new MockAavePool();
        mockPool.setReserveData(address(usdc), address(aUsdc));

        // Fund the mock pool with USDC for withdrawals
        usdc.mint(address(mockPool), INITIAL_BALANCE);

        // Deploy adapter
        adapter = new AaveAdapter(address(mockPool), owner);

        // Pre-compute market ID
        usdcMarketId = _computeMarketId(usdcCurrency);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsPoolAddress() public view {
        assertEq(address(adapter.AAVE_POOL()), address(mockPool));
    }

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    function test_constructor_revertsOnZeroPoolAddress() public {
        vm.expectRevert(AaveAdapter.InvalidPoolAddress.selector);
        new AaveAdapter(address(0), owner);
    }

    // ============ registerMarket Tests ============

    function test_registerMarket_success() public {
        vm.expectEmit(true, false, false, true);
        emit MarketRegistered(usdcMarketId, usdcCurrency, address(aUsdc));

        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        assertTrue(adapter.hasMarket(usdcMarketId));
        assertEq(adapter.getYieldToken(usdcMarketId), address(aUsdc));
        assertEq(Currency.unwrap(adapter.getMarketCurrency(usdcMarketId)), address(usdc));
    }

    function test_registerMarket_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerMarket(usdcCurrency);
    }

    function test_registerMarket_revertsOnNativeCurrency() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerMarket(nativeCurrency);
    }

    function test_registerMarket_revertsIfReserveNotFound() public {
        // Create a token not configured in the mock pool
        MockERC20 unknownToken = new MockERC20("Unknown", "UNK", 18);
        Currency unknownCurrency = Currency.wrap(address(unknownToken));

        vm.expectRevert(AaveAdapter.ReserveNotFound.selector);
        vm.prank(owner);
        adapter.registerMarket(unknownCurrency);
    }

    function test_registerMarket_revertsIfAlreadyRegistered() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        vm.expectRevert(AdapterBase.MarketAlreadyRegistered.selector);
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);
    }

    // ============ deactivateMarket Tests ============

    function test_deactivateMarket_success() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);
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
        adapter.registerMarket(usdcCurrency);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.deactivateMarket(usdcMarketId);
    }

    // ============ deposit Tests ============

    function test_deposit_success() public {
        // Setup
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.expectEmit(true, false, false, true);
        emit DepositedToAave(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        // Check balances
        assertEq(usdc.balanceOf(user), userBalanceBefore - DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(recipient), DEPOSIT_AMOUNT); // 1:1 in mock
    }

    function test_deposit_revertsIfMarketNotActive() public {
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(usdcMarketId, 0, recipient);
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ withdraw Tests ============

    function test_withdraw_success() public {
        // Setup: register market and authorize caller
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits first
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(usdcMarketId, DEPOSIT_AMOUNT, user);

        // Transfer aTokens to adapter (simulating hook behavior)
        vm.prank(user);
        aUsdc.transfer(address(adapter), DEPOSIT_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnFromAave(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);

        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + DEPOSIT_AMOUNT);
    }

    function test_withdraw_revertsIfUnauthorized() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

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
        adapter.registerMarket(usdcCurrency);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(usdcMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ getYieldToken Tests ============

    function test_getYieldToken_returnsCorrectAToken() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        assertEq(adapter.getYieldToken(usdcMarketId), address(aUsdc));
    }

    function test_getYieldToken_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getYieldToken(usdcMarketId);
    }

    // ============ getMarketCurrency Tests ============

    function test_getMarketCurrency_returnsCorrectCurrency() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

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
        adapter.registerMarket(usdcCurrency);

        assertTrue(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseForInactiveMarket() public {
        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseAfterDeactivation() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);

        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    // ============ getAdapterMetadata Tests ============

    function test_getAdapterMetadata_returnsCorrectName() public view {
        AaveAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.name, "Aave V3");
    }

    function test_getAdapterMetadata_returnsCorrectChainId() public view {
        AaveAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.chainId, block.chainid);
    }

    // ============ requiresAllow Tests ============

    function test_requiresAllow_returnsFalse() public view {
        assertFalse(adapter.requiresAllow());
    }

    // ============ Multiple Markets Tests ============

    function test_multipleMarkets() public {
        // Setup USDT in mock pool
        MockERC20 aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);
        mockPool.setReserveData(address(usdt), address(aUsdt));

        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency);
        adapter.registerMarket(usdtCurrency);
        vm.stopPrank();

        bytes32 usdtMarketId = _computeMarketId(usdtCurrency);

        assertTrue(adapter.hasMarket(usdcMarketId));
        assertTrue(adapter.hasMarket(usdtMarketId));
        assertEq(adapter.getYieldToken(usdcMarketId), address(aUsdc));
        assertEq(adapter.getYieldToken(usdtMarketId), address(aUsdt));
    }
}
