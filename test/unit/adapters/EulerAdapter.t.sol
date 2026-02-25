// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    Currency,
    CurrencyLibrary
} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract EulerAdapterTest is AdapterTestBase {
    using CurrencyLibrary for Currency;

    EulerAdapter public adapter;
    MockERC4626Vault public mockVault;

    bytes32 public vaultMarketId;

    event VaultRegistered(
        bytes32 indexed marketId,
        Currency currency,
        address vault
    );
    event VaultDeactivated(bytes32 indexed marketId);
    event DepositedToEuler(
        bytes32 indexed marketId,
        uint256 assets,
        uint256 shares,
        address onBehalfOf
    );
    event WithdrawnFromEuler(
        bytes32 indexed marketId,
        uint256 assets,
        uint256 shares,
        address to
    );

    function setUp() public override {
        super.setUp();

        // Deploy mock vault
        mockVault = new MockERC4626Vault(
            address(usdc),
            "Euler Earn USDC",
            "eeUSDC"
        );

        // Deploy adapter
        vm.prank(owner);
        adapter = new EulerAdapter(owner);

        // Pre-compute market ID (vault address based)
        vaultMarketId = _computeVaultMarketId(address(mockVault));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    // ============ registerVault Tests ============

    function test_registerVault_success() public {
        vm.expectEmit(true, false, false, true);
        emit VaultRegistered(vaultMarketId, usdcCurrency, address(mockVault));

        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        assertTrue(adapter.hasMarket(vaultMarketId));
        assertEq(adapter.getYieldToken(vaultMarketId), address(mockVault));
        assertEq(
            Currency.unwrap(adapter.getMarketCurrency(vaultMarketId)),
            address(usdc)
        );
    }

    function test_registerVault_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                user
            )
        );
        adapter.registerVault(usdcCurrency, address(mockVault));
    }

    function test_registerVault_revertsOnNativeCurrency() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerVault(nativeCurrency, address(mockVault));
    }

    function test_registerVault_revertsOnZeroVault() public {
        vm.prank(owner);
        vm.expectRevert(EulerAdapter.InvalidVaultAddress.selector);
        adapter.registerVault(usdcCurrency, address(0));
    }

    function test_registerVault_revertsOnAssetMismatch() public {
        // Create vault for USDT but try to register with USDC currency
        MockERC4626Vault usdtVault = new MockERC4626Vault(
            address(usdt),
            "Euler USDT Vault",
            "eeUSDT"
        );

        vm.prank(owner);
        vm.expectRevert(AdapterBase.AssetMismatch.selector);
        adapter.registerVault(usdcCurrency, address(usdtVault));
    }

    function test_registerVault_revertsIfAlreadyRegistered() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        vm.prank(owner);
        vm.expectRevert(AdapterBase.MarketAlreadyRegistered.selector);
        adapter.registerVault(usdcCurrency, address(mockVault));
    }

    // ============ Market ID Derivation Tests ============

    function test_marketIdDerivation_fromVaultAddress() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        // Market ID should be bytes32(uint256(uint160(vault)))
        bytes32 expectedMarketId = bytes32(
            uint256(uint160(address(mockVault)))
        );
        assertEq(vaultMarketId, expectedMarketId);
        assertTrue(adapter.hasMarket(expectedMarketId));
    }

    function test_multipleVaultsSameCurrency_differentMarketIds() public {
        // Create two vaults for USDC
        MockERC4626Vault vault1 = new MockERC4626Vault(
            address(usdc),
            "Vault 1",
            "v1"
        );
        MockERC4626Vault vault2 = new MockERC4626Vault(
            address(usdc),
            "Vault 2",
            "v2"
        );

        vm.startPrank(owner);
        adapter.registerVault(usdcCurrency, address(vault1));
        adapter.registerVault(usdcCurrency, address(vault2));
        vm.stopPrank();

        bytes32 marketId1 = _computeVaultMarketId(address(vault1));
        bytes32 marketId2 = _computeVaultMarketId(address(vault2));

        // Different market IDs
        assertTrue(marketId1 != marketId2);
        assertTrue(adapter.hasMarket(marketId1));
        assertTrue(adapter.hasMarket(marketId2));
    }

    // ============ deactivateMarket Tests ============

    function test_deactivateMarket_success() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));
        assertTrue(adapter.hasMarket(vaultMarketId));

        vm.expectEmit(true, false, false, false);
        emit VaultDeactivated(vaultMarketId);

        vm.prank(owner);
        adapter.deactivateMarket(vaultMarketId);

        assertFalse(adapter.hasMarket(vaultMarketId));
    }

    function test_deactivateMarket_revertsIfNotActive() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deactivateMarket(vaultMarketId);
    }

    function test_deactivateMarket_revertsOnNonOwner() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                user
            )
        );
        adapter.deactivateMarket(vaultMarketId);
    }

    // ============ deposit Tests ============

    function test_deposit_success() public {
        // Setup
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.expectEmit(true, false, false, true);
        emit DepositedToEuler(
            vaultMarketId,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT,
            recipient
        );

        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, recipient);

        // Check balances
        assertEq(usdc.balanceOf(user), userBalanceBefore - DEPOSIT_AMOUNT);
        assertEq(mockVault.balanceOf(recipient), DEPOSIT_AMOUNT); // 1:1 on first deposit
    }

    function test_deposit_revertsIfMarketNotActive() public {
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(vaultMarketId, 0, recipient);
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ withdraw Tests ============

    function test_withdraw_success() public {
        // Setup: register vault and authorize caller
        vm.startPrank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits first
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, user);

        // Transfer vault shares to adapter (simulating hook behavior)
        vm.prank(user);
        mockVault.transfer(address(adapter), DEPOSIT_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnFromEuler(
            vaultMarketId,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT,
            recipient
        );

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(
            vaultMarketId,
            DEPOSIT_AMOUNT,
            recipient
        );

        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + DEPOSIT_AMOUNT
        );
    }

    function test_withdraw_revertsIfUnauthorized() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsIfMarketNotActive() public {
        vm.startPrank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.startPrank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(vaultMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, address(0));
    }

    // ============ getYieldToken Tests ============

    function test_getYieldToken_returnsVaultAddress() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        assertEq(adapter.getYieldToken(vaultMarketId), address(mockVault));
    }

    function test_getYieldToken_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getYieldToken(vaultMarketId);
    }

    // ============ getMarketCurrency Tests ============

    function test_getMarketCurrency_returnsCorrectCurrency() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        Currency currency = adapter.getMarketCurrency(vaultMarketId);
        assertEq(Currency.unwrap(currency), address(usdc));
    }

    function test_getMarketCurrency_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getMarketCurrency(vaultMarketId);
    }

    // ============ hasMarket Tests ============

    function test_hasMarket_returnsTrueForActiveVault() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        assertTrue(adapter.hasMarket(vaultMarketId));
    }

    function test_hasMarket_returnsFalseForInactiveVault() public view {
        assertFalse(adapter.hasMarket(vaultMarketId));
    }

    function test_hasMarket_returnsFalseAfterDeactivation() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        vm.prank(owner);
        adapter.deactivateMarket(vaultMarketId);

        assertFalse(adapter.hasMarket(vaultMarketId));
    }

    // ============ getAdapterMetadata Tests ============

    function test_getAdapterMetadata_returnsCorrectName() public view {
        EulerAdapter.AdapterMetadata memory metadata = adapter
            .getAdapterMetadata();
        assertEq(metadata.name, "Euler Earn");
    }

    function test_getAdapterMetadata_returnsCorrectChainId() public view {
        EulerAdapter.AdapterMetadata memory metadata = adapter
            .getAdapterMetadata();
        assertEq(metadata.chainId, block.chainid);
    }

    // ============ requiresAllow Tests ============

    function test_requiresAllow_returnsFalse() public view {
        assertFalse(adapter.requiresAllow());
    }

    // ============ ERC-4626 Flow Tests ============

    function test_depositWithdraw_withYieldAccrual() public {
        vm.startPrank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // User deposits
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, user);

        uint256 sharesBefore = mockVault.balanceOf(user);
        assertEq(sharesBefore, DEPOSIT_AMOUNT);

        // Simulate yield (add 10% more assets to vault)
        uint256 yieldAmount = DEPOSIT_AMOUNT / 10;
        usdc.mint(user, yieldAmount);
        _approveTokens(address(usdc), user, address(mockVault), yieldAmount);
        vm.prank(user);
        mockVault.simulateYield(yieldAmount);

        // Transfer shares to adapter
        vm.prank(user);
        mockVault.transfer(address(adapter), sharesBefore);

        // Withdraw - should get more than deposited due to yield
        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(
            vaultMarketId,
            sharesBefore,
            recipient
        );

        // Should receive original + yield
        assertEq(withdrawn, DEPOSIT_AMOUNT + yieldAmount);
        assertEq(usdc.balanceOf(recipient), DEPOSIT_AMOUNT + yieldAmount);
    }

    // ============ Multiple Vaults Tests ============

    function test_multipleVaults() public {
        // Create vaults for different currencies
        MockERC4626Vault usdtVault = new MockERC4626Vault(
            address(usdt),
            "Euler USDT Vault",
            "eeUSDT"
        );

        vm.startPrank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));
        adapter.registerVault(usdtCurrency, address(usdtVault));
        vm.stopPrank();

        bytes32 usdtMarketId = _computeVaultMarketId(address(usdtVault));

        assertTrue(adapter.hasMarket(vaultMarketId));
        assertTrue(adapter.hasMarket(usdtMarketId));
        assertEq(adapter.getYieldToken(vaultMarketId), address(mockVault));
        assertEq(adapter.getYieldToken(usdtMarketId), address(usdtVault));
    }
}
