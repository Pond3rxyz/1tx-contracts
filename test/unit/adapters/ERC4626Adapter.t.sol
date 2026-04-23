// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";

contract ERC4626AdapterTest is AdapterTestBase {
    ERC4626Adapter public adapter;
    MockERC4626Vault public mockVault;

    bytes32 public vaultMarketId;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address vault);
    event MarketDeactivated(bytes32 indexed marketId);
    event Deposited(bytes32 indexed marketId, uint256 assets, uint256 shares, address onBehalfOf);
    event Withdrawn(bytes32 indexed marketId, uint256 assets, uint256 shares, address to);

    function setUp() public override {
        super.setUp();

        mockVault = new MockERC4626Vault(address(usdc), "Generic USDC Vault", "gUSDC");
        adapter = new ERC4626Adapter(owner, "Generic ERC4626");
        vaultMarketId = _computeVaultMarketId(address(mockVault));
    }

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    function test_registerMarket_success() public {
        vm.expectEmit(true, false, false, true);
        emit MarketRegistered(vaultMarketId, usdcCurrency, address(mockVault));

        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        assertTrue(adapter.hasMarket(vaultMarketId));
        assertEq(adapter.getYieldToken(vaultMarketId), address(mockVault));
        assertEq(Currency.unwrap(adapter.getMarketCurrency(vaultMarketId)), address(usdc));
    }

    function test_registerMarket_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerMarket(usdcCurrency, address(mockVault));
    }

    function test_registerMarket_revertsOnNativeCurrency() public {
        vm.prank(owner);
        vm.expectRevert(AdapterBase.NativeCurrencyNotSupported.selector);
        adapter.registerMarket(nativeCurrency, address(mockVault));
    }

    function test_registerMarket_revertsOnZeroVault() public {
        vm.prank(owner);
        vm.expectRevert(ERC4626Adapter.InvalidVaultAddress.selector);
        adapter.registerMarket(usdcCurrency, address(0));
    }

    function test_registerMarket_revertsOnAssetMismatch() public {
        MockERC4626Vault usdtVault = new MockERC4626Vault(address(usdt), "Generic USDT Vault", "gUSDT");

        vm.prank(owner);
        vm.expectRevert(AdapterBase.AssetMismatch.selector);
        adapter.registerMarket(usdcCurrency, address(usdtVault));
    }

    function test_registerMarket_revertsIfAlreadyRegistered() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        vm.expectRevert(AdapterBase.MarketAlreadyRegistered.selector);
        adapter.registerMarket(usdcCurrency, address(mockVault));
        vm.stopPrank();
    }

    function test_marketIdDerivation_fromVaultAddress() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        bytes32 expectedMarketId = bytes32(uint256(uint160(address(mockVault))));
        assertEq(vaultMarketId, expectedMarketId);
        assertTrue(adapter.hasMarket(expectedMarketId));
    }

    function test_multipleVaultsSameCurrency_differentMarketIds() public {
        MockERC4626Vault vault1 = new MockERC4626Vault(address(usdc), "Vault 1", "v1");
        MockERC4626Vault vault2 = new MockERC4626Vault(address(usdc), "Vault 2", "v2");

        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(vault1));
        adapter.registerMarket(usdcCurrency, address(vault2));
        vm.stopPrank();

        bytes32 marketId1 = _computeVaultMarketId(address(vault1));
        bytes32 marketId2 = _computeVaultMarketId(address(vault2));

        assertTrue(marketId1 != marketId2);
        assertTrue(adapter.hasMarket(marketId1));
        assertTrue(adapter.hasMarket(marketId2));
    }

    function test_deactivateMarket_success() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        vm.expectEmit(true, false, false, false);
        emit MarketDeactivated(vaultMarketId);

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
        adapter.registerMarket(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.deactivateMarket(vaultMarketId);
    }

    function test_deposit_success() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit Deposited(vaultMarketId, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, recipient);

        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, recipient);

        assertEq(mockVault.balanceOf(recipient), DEPOSIT_AMOUNT);
    }

    function test_deposit_revertsIfMarketNotActive() public {
        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.deposit(vaultMarketId, 0, recipient);
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, address(0));
    }

    function test_withdraw_success() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, user);

        vm.prank(user);
        mockVault.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(vaultMarketId, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, recipient);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, recipient);

        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(recipient), DEPOSIT_AMOUNT);
    }

    function test_withdraw_revertsIfUnauthorized() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));

        vm.prank(user);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsIfMarketNotActive() public {
        vm.prank(owner);
        adapter.addAuthorizedCaller(authorizedCaller);

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(vaultMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        adapter.withdraw(vaultMarketId, DEPOSIT_AMOUNT, address(0));
    }

    function test_getYieldToken_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getYieldToken(vaultMarketId);
    }

    function test_getMarketCurrency_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.getMarketCurrency(vaultMarketId);
    }

    function test_convertToUnderlying_revertsIfNotActive() public {
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.convertToUnderlying(vaultMarketId, DEPOSIT_AMOUNT);
    }

    function test_convertToUnderlying_returnsUnderlyingValue() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, user);

        uint256 yieldAmount = DEPOSIT_AMOUNT / 10;
        usdc.mint(user, yieldAmount);
        _approveTokens(address(usdc), user, address(mockVault), yieldAmount);
        vm.prank(user);
        mockVault.simulateYield(yieldAmount);

        assertEq(adapter.convertToUnderlying(vaultMarketId, DEPOSIT_AMOUNT), DEPOSIT_AMOUNT + yieldAmount);
    }

    function test_getAdapterMetadata_returnsConfiguredName() public view {
        ERC4626Adapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();

        assertEq(metadata.name, "Generic ERC4626");
        assertEq(metadata.chainId, block.chainid);
    }

    function test_requiresAllow_returnsFalse() public view {
        assertFalse(adapter.requiresAllow());
    }

    function test_depositWithdraw_withYieldAccrual() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency, address(mockVault));
        adapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        _approveTokens(address(usdc), user, address(adapter), DEPOSIT_AMOUNT);
        vm.prank(user);
        adapter.deposit(vaultMarketId, DEPOSIT_AMOUNT, user);

        uint256 yieldAmount = DEPOSIT_AMOUNT / 10;
        usdc.mint(user, yieldAmount);
        _approveTokens(address(usdc), user, address(mockVault), yieldAmount);
        vm.prank(user);
        mockVault.simulateYield(yieldAmount);

        uint256 shares = mockVault.balanceOf(user);
        vm.prank(user);
        mockVault.transfer(address(adapter), shares);

        vm.prank(authorizedCaller);
        uint256 withdrawn = adapter.withdraw(vaultMarketId, shares, recipient);

        assertEq(withdrawn, DEPOSIT_AMOUNT + yieldAmount);
        assertEq(usdc.balanceOf(recipient), DEPOSIT_AMOUNT + yieldAmount);
    }
}
