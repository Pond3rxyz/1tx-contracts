// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {AdapterBaseUpgradeable as AdapterBase} from "../../../src/adapters/base/AdapterBaseUpgradeable.sol";
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
        adapter = AdapterProxyLib.deployAave(address(mockPool), owner);

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
        AaveAdapter impl = new AaveAdapter();
        vm.expectRevert(AaveAdapter.InvalidPoolAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AaveAdapter.initialize, (address(0), owner)));
    }

    // ============ Protocol Identity Tests ============

    /// @notice A proxy initialized through {initialize} reports the historical literal.
    /// @dev The fallback in `_adapterName()`. Base, Arbitrum and Monad all run proxies that took
    ///      this path before the stored name existed, so their name slot is empty; without the
    ///      fallback they would report `""` as their protocol identity after an implementation
    ///      swap, and that string is what `max_weight_per_protocol` budgets against downstream.
    function test_getAdapterMetadata_defaultsToAaveV3() public view {
        assertEq(adapter.getAdapterMetadata().name, "Aave V3");
        assertEq(adapter.getAdapterMetadata().chainId, block.chainid);
    }

    /// @notice The generic path: one contract, identity supplied at init. This is what makes an
    ///         Aave *fork* — Neverland on Monad — listable as its own protocol rather than
    ///         exposure silently booked against Aave's risk budget.
    function test_initializeNamed_setsProtocolIdentity() public {
        AaveAdapter named = AdapterProxyLib.deployAaveNamed(address(mockPool), owner, "Neverland");

        assertEq(named.getAdapterMetadata().name, "Neverland");
        // registerInstrument on the deployed registry requires this to match, so it is asserted
        // rather than assumed on the new path.
        assertEq(named.getAdapterMetadata().chainId, block.chainid);
        assertEq(address(named.AAVE_POOL()), address(mockPool));
        assertEq(named.owner(), owner);
    }

    /// @notice The name is set once. It is the protocol identity a weight cap budgets against, so
    ///         there is no setter and re-initialization must not offer a way around that.
    function test_initializeNamed_cannotBeReinitialized() public {
        AaveAdapter named = AdapterProxyLib.deployAaveNamed(address(mockPool), owner, "Neverland");

        vm.expectRevert();
        named.initializeNamed(address(mockPool), owner, "Aave V3");

        vm.expectRevert();
        named.initialize(address(mockPool), owner);

        assertEq(named.getAdapterMetadata().name, "Neverland", "identity was overwritten");
    }

    /// @notice The zero-pool guard is not skipped on the named path.
    function test_initializeNamed_revertsOnZeroPoolAddress() public {
        AaveAdapter impl = new AaveAdapter();
        vm.expectRevert(AaveAdapter.InvalidPoolAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AaveAdapter.initializeNamed, (address(0), owner, "Neverland")));
    }

    /// @notice Two proxies over one implementation carry different identities and different pools.
    /// @dev This is the property that lets Aave and an Aave fork coexist on one chain.
    ///      `marketId = keccak256(abi.encode(currency))` has no pool in its preimage, so the same
    ///      asset keys to the same id on both — safe only because `markets` is per-proxy storage,
    ///      and unsafe the moment a fork's reserves are registered on Aave's own adapter.
    function test_twoNamedProxiesDoNotShareIdentityOrPool() public {
        MockAavePool forkPool = new MockAavePool();
        forkPool.setReserveData(address(usdc), address(aUsdc));

        AaveAdapter aave = AdapterProxyLib.deployAaveNamed(address(mockPool), owner, "Aave V3");
        AaveAdapter forkAdapter = AdapterProxyLib.deployAaveNamed(address(forkPool), owner, "Neverland");

        assertEq(aave.getAdapterMetadata().name, "Aave V3");
        assertEq(forkAdapter.getAdapterMetadata().name, "Neverland", "second proxy took the first's identity");
        assertEq(address(aave.AAVE_POOL()), address(mockPool));
        assertEq(address(forkAdapter.AAVE_POOL()), address(forkPool), "second proxy points at the wrong pool");

        vm.startPrank(owner);
        aave.registerMarket(usdcCurrency);
        forkAdapter.registerMarket(usdcCurrency);
        vm.stopPrank();

        assertTrue(aave.hasMarket(usdcMarketId), "market missing on the Aave proxy");
        assertTrue(forkAdapter.hasMarket(usdcMarketId), "market missing on the fork proxy");
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
        adapter.setAuthorizedCaller(authorizedCaller, true);
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
        adapter.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        adapter.withdraw(usdcMarketId, DEPOSIT_AMOUNT, recipient);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency);
        adapter.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        adapter.withdraw(usdcMarketId, 0, recipient);
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        vm.startPrank(owner);
        adapter.registerMarket(usdcCurrency);
        adapter.setAuthorizedCaller(authorizedCaller, true);
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

    function test_hasMarket_returnsFalseForInactiveMarket() public view {
        assertFalse(adapter.hasMarket(usdcMarketId));
    }

    function test_hasMarket_returnsFalseAfterDeactivation() public {
        vm.prank(owner);
        adapter.registerMarket(usdcCurrency);

        vm.prank(owner);
        adapter.deactivateMarket(usdcMarketId);

        assertFalse(adapter.hasMarket(usdcMarketId));
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
