// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract FluidAdapterTest is AdapterTestBase {
    using CurrencyLibrary for Currency;

    FluidAdapter public adapter;
    MockERC4626Vault public mockFToken;

    bytes32 public fTokenMarketId;

    event FTokenRegistered(bytes32 indexed marketId, Currency currency, address fToken);
    event FTokenDeactivated(bytes32 indexed marketId);
    event DepositedToFluid(bytes32 indexed marketId, uint256 assets, uint256 shares, address onBehalfOf);
    event WithdrawnFromFluid(bytes32 indexed marketId, uint256 assets, uint256 shares, address to);

    function setUp() public override {
        super.setUp();

        // Deploy mock fToken (ERC-4626)
        mockFToken = new MockERC4626Vault(address(usdc), "Fluid USDC", "fUSDC");

        // Deploy adapter
        adapter = new FluidAdapter(owner);

        // Pre-compute market ID (fToken address based)
        fTokenMarketId = _computeVaultMarketId(address(mockFToken));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    // ============ registerFToken Tests ============

    function test_registerFToken_success() public {
        vm.expectEmit(true, false, false, true);
        emit FTokenRegistered(fTokenMarketId, usdcCurrency, address(mockFToken));

        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        assertTrue(adapter.hasMarket(fTokenMarketId));
        assertEq(adapter.getYieldToken(fTokenMarketId), address(mockFToken));
        assertEq(Currency.unwrap(adapter.getMarketCurrency(fTokenMarketId)), address(usdc));
    }

    function test_registerFToken_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerFToken(usdcCurrency, address(mockFToken));
    }

    function test_registerFToken_revertsOnNativeCurrency() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerFToken(nativeCurrency, address(mockFToken));
    }

    function test_registerFToken_revertsOnZeroFToken() public {
        vm.prank(owner);
        vm.expectRevert(FluidAdapter.InvalidFTokenAddress.selector);
        adapter.registerFToken(usdcCurrency, address(0));
    }

    function test_registerFToken_revertsOnAssetMismatch() public {
        // Create fToken for USDT but try to register with USDC currency
        MockERC4626Vault usdtFToken = new MockERC4626Vault(address(usdt), "Fluid USDT", "fUSDT");

        vm.expectRevert(AdapterBase.AssetMismatch.selector);
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(usdtFToken));
    }

    function test_registerFToken_revertsIfAlreadyRegistered() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        vm.expectRevert(AdapterBase.MarketAlreadyRegistered.selector);
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
    }

    // ============ Market ID Derivation Tests ============

    function test_marketIdDerivation_fromFTokenAddress() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        // Market ID should be bytes32(uint256(uint160(fToken)))
        bytes32 expectedMarketId = bytes32(uint256(uint160(address(mockFToken))));
        assertEq(fTokenMarketId, expectedMarketId);
        assertTrue(adapter.hasMarket(expectedMarketId));
    }

    function test_multipleFTokensSameCurrency_differentMarketIds() public {
        // Create two fTokens for USDC
        MockERC4626Vault fToken1 = new MockERC4626Vault(address(usdc), "FToken 1", "f1");
        MockERC4626Vault fToken2 = new MockERC4626Vault(address(usdc), "FToken 2", "f2");

        vm.startPrank(owner);
        adapter.registerFToken(usdcCurrency, address(fToken1));
        adapter.registerFToken(usdcCurrency, address(fToken2));
        vm.stopPrank();

        bytes32 marketId1 = _computeVaultMarketId(address(fToken1));
        bytes32 marketId2 = _computeVaultMarketId(address(fToken2));

        // Different market IDs
        assertTrue(marketId1 != marketId2);
        assertTrue(adapter.hasMarket(marketId1));
        assertTrue(adapter.hasMarket(marketId2));
    }

    // ============ deactivateMarket Tests ============

    function test_deactivateMarket_success() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
        assertTrue(adapter.hasMarket(fTokenMarketId));

        vm.expectEmit(true, false, false, false);
        emit FTokenDeactivated(fTokenMarketId);

        vm.prank(owner);
        adapter.deactivateMarket(fTokenMarketId);

        assertFalse(adapter.hasMarket(fTokenMarketId));
    }

    function test_deactivateMarket_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        vm.prank(owner);
        adapter.deactivateMarket(fTokenMarketId);
    }

    function test_deactivateMarket_revertsOnNonOwner() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.deactivateMarket(fTokenMarketId);
    }

    // ============ deposit Tests ============

    function test_deposit_success() public {
        // Setup
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.expectEmit(true, false, false, true);
        emit DepositedToFluid(fTokenMarketId, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, recipient);

        vm.prank(user);
        adapter.deposit(fTokenMarketId, DEPOSIT_AMOUNT, recipient);

        // Check balances
        assertEq(usdc.balanceOf(user), userBalanceBefore - DEPOSIT_AMOUNT);
        assertEq(mockFToken.balanceOf(recipient), DEPOSIT_AMOUNT); // 1:1 on first deposit
    }

    function test_deposit_revertsIfMarketNotActive() public {
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deposit(fTokenMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(fTokenMarketId, 0, recipient);
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(fTokenMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ withdraw Tests ============

    function test_withdraw_success() public {
        // Setup: register fToken and authorize caller
        vm.startPrank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits first
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(fTokenMarketId, DEPOSIT_AMOUNT, user);

        // Transfer fToken shares to adapter (simulating hook behavior)
        vm.prank(user);
        mockFToken.transfer(address(adapter), DEPOSIT_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnFromFluid(fTokenMarketId, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, recipient);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(fTokenMarketId, DEPOSIT_AMOUNT, recipient);

        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + DEPOSIT_AMOUNT);
    }

    function test_withdraw_revertsIfUnauthorized() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        vm.prank(user);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        adapter.withdraw(fTokenMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsIfMarketNotActive() public {
        vm.startPrank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.withdraw(fTokenMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.startPrank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(fTokenMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.withdraw(fTokenMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ getYieldToken Tests ============

    function test_getYieldToken_returnsFTokenAddress() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        assertEq(adapter.getYieldToken(fTokenMarketId), address(mockFToken));
    }

    function test_getYieldToken_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getYieldToken(fTokenMarketId);
    }

    // ============ getMarketCurrency Tests ============

    function test_getMarketCurrency_returnsCorrectCurrency() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        Currency currency = adapter.getMarketCurrency(fTokenMarketId);
        assertEq(Currency.unwrap(currency), address(usdc));
    }

    function test_getMarketCurrency_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getMarketCurrency(fTokenMarketId);
    }

    // ============ hasMarket Tests ============

    function test_hasMarket_returnsTrueForActiveFToken() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        assertTrue(adapter.hasMarket(fTokenMarketId));
    }

    function test_hasMarket_returnsFalseForInactiveFToken() public view {
        assertFalse(adapter.hasMarket(fTokenMarketId));
    }

    function test_hasMarket_returnsFalseAfterDeactivation() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        vm.prank(owner);
        adapter.deactivateMarket(fTokenMarketId);

        assertFalse(adapter.hasMarket(fTokenMarketId));
    }

    // ============ getAdapterMetadata Tests ============

    function test_getAdapterMetadata_returnsCorrectName() public view {
        FluidAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.name, "Fluid Lending");
    }

    function test_getAdapterMetadata_returnsCorrectChainId() public view {
        FluidAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();
        assertEq(metadata.chainId, block.chainid);
    }

    // ============ requiresAllow Tests ============

    function test_requiresAllow_returnsFalse() public view {
        assertFalse(adapter.requiresAllow());
    }

    // ============ ERC-4626 Flow Tests ============

    function test_depositWithdraw_withYieldAccrual() public {
        vm.startPrank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(fTokenMarketId, DEPOSIT_AMOUNT, user);

        uint256 sharesBefore = mockFToken.balanceOf(user);
        assertEq(sharesBefore, DEPOSIT_AMOUNT);

        // Simulate yield (add 10% more assets to fToken)
        uint256 yieldAmount = DEPOSIT_AMOUNT / 10;
        usdc.mint(user, yieldAmount);
        _approveTokens(address(usdc), user, address(mockFToken), yieldAmount);
        vm.prank(user);
        mockFToken.simulateYield(yieldAmount);

        // Transfer shares to adapter
        vm.prank(user);
        mockFToken.transfer(address(adapter), sharesBefore);

        // Withdraw - should get more than deposited due to yield
        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(fTokenMarketId, sharesBefore, recipient);

        // Should receive original + yield
        assertEq(withdrawn, DEPOSIT_AMOUNT + yieldAmount);
        assertEq(usdc.balanceOf(recipient), DEPOSIT_AMOUNT + yieldAmount);
    }

    // ============ Multiple FTokens Tests ============

    function test_multipleFTokens() public {
        // Create fTokens for different currencies
        MockERC4626Vault usdtFToken = new MockERC4626Vault(address(usdt), "Fluid USDT", "fUSDT");

        vm.startPrank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));
        adapter.registerFToken(usdtCurrency, address(usdtFToken));
        vm.stopPrank();

        bytes32 usdtMarketId = _computeVaultMarketId(address(usdtFToken));

        assertTrue(adapter.hasMarket(fTokenMarketId));
        assertTrue(adapter.hasMarket(usdtMarketId));
        assertEq(adapter.getYieldToken(fTokenMarketId), address(mockFToken));
        assertEq(adapter.getYieldToken(usdtMarketId), address(usdtFToken));
    }
}
