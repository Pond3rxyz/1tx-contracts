// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {PortfolioStrategy} from "../../../src/hooks/PortfolioStrategy.sol";
import {IPortfolioStrategy} from "../../../src/interfaces/IPortfolioStrategy.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";

import {MockPoolManager} from "../../mocks/MockPoolManager.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract PortfolioVaultTest is Test {
    using CurrencyLibrary for Currency;

    // Contracts
    PortfolioVault public vault;
    PortfolioStrategy public strategy;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    MockPoolManager public mockPM;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    // Tokens
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20 public aUsdc;
    MockERC20 public aUsdt;

    // Currencies
    Currency public usdcCurrency;
    Currency public usdtCurrency;

    // IDs
    bytes32 public usdcMarketId;
    bytes32 public usdtMarketId;
    bytes32 public usdcInstrumentId;
    bytes32 public usdtInstrumentId;

    // Addresses
    address public owner;
    address public user;
    address public hookAddr;
    address public executionAddress;

    // Constants
    uint256 public constant INITIAL_BALANCE = 1_000_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        hookAddr = makeAddr("hook");
        executionAddress = makeAddr("executionAddress");

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);

        usdcCurrency = Currency.wrap(address(usdc));
        usdtCurrency = Currency.wrap(address(usdt));

        mockPM = new MockPoolManager();

        // Deploy registries via proxies
        InstrumentRegistry irImpl = new InstrumentRegistry();
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner))
            )
        );

        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner))
            )
        );

        // Deploy Aave adapter + register markets
        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        mockAavePool.setReserveData(address(usdt), address(aUsdt));
        usdc.mint(address(mockAavePool), INITIAL_BALANCE);
        usdt.mint(address(mockAavePool), INITIAL_BALANCE);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.startPrank(owner);
        aaveAdapter.registerMarket(usdcCurrency);
        aaveAdapter.registerMarket(usdtCurrency);
        vm.stopPrank();

        // Compute IDs
        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdtMarketId = keccak256(abi.encode(usdtCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        usdtInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdtMarketId);

        // Register instruments
        vm.startPrank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));
        instrumentRegistry.registerInstrument(executionAddress, usdtMarketId, address(aaveAdapter));
        vm.stopPrank();

        // Register swap pools
        (Currency c0, Currency c1) = _orderCurrencies(usdcCurrency, usdtCurrency);
        PoolKey memory swapPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        vm.startPrank(owner);
        swapPoolRegistry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, swapPoolKey);
        swapPoolRegistry.registerDefaultSwapPool(usdtCurrency, usdcCurrency, swapPoolKey);
        vm.stopPrank();

        // Set 1:1 pool price for stablecoin pair (sqrtPriceX96 = 2^96 means price = 1.0)
        mockPM.setPoolPrice(swapPoolKey, uint160(1 << 96));

        // Fund mock PM
        usdt.mint(address(mockPM), INITIAL_BALANCE);
        usdc.mint(address(mockPM), INITIAL_BALANCE);

        // Deploy strategy (UUPS proxy)
        _deployStrategy();

        // Deploy vault
        _deployVault(_singleAllocation(usdcInstrumentId, 10000));
    }

    // ============ Helpers ============

    function _orderCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    function _singleAllocation(bytes32 instrumentId, uint16 weight)
        internal
        pure
        returns (PortfolioVault.Allocation[] memory)
    {
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: instrumentId, weightBps: weight});
        return allocs;
    }

    function _dualAllocation(bytes32 id1, uint16 w1, bytes32 id2, uint16 w2)
        internal
        pure
        returns (PortfolioVault.Allocation[] memory)
    {
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](2);
        allocs[0] = PortfolioVault.Allocation({instrumentId: id1, weightBps: w1});
        allocs[1] = PortfolioVault.Allocation({instrumentId: id2, weightBps: w2});
        return allocs;
    }

    function _deployStrategy() internal {
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, owner)
                )
            )
        );

        // Authorize strategy on adapter (strategy is the msg.sender to adapters now)
        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(strategy));
    }

    function _deployVault(PortfolioVault.Allocation[] memory allocs) internal {
        vault = new PortfolioVault(
            PortfolioVault.InitParams({
                initialOwner: owner,
                name: "Test Portfolio",
                symbol: "tPORT",
                stable: usdcCurrency,
                poolManager: IPoolManager(address(mockPM)),
                instrumentRegistry: instrumentRegistry,
                swapPoolRegistry: swapPoolRegistry,
                strategy: IPortfolioStrategy(address(strategy)),
                allocations: allocs
            })
        );

        // Set hookAddr as the authorized hook
        vm.prank(owner);
        vault.setHook(hookAddr);
    }

    function _deployCapitalAsHook(uint256 amount) internal {
        usdc.mint(address(vault), amount);
        vm.prank(hookAddr);
        vault.deployCapital(amount);
    }

    function _mintSharesAsHook(address to, uint256 amount) internal {
        vm.prank(hookAddr);
        vault.mintShares(to, amount);
    }

    function _withdrawCapitalAsHook(uint256 stableNeeded) internal returns (uint256 stableOut) {
        vm.prank(hookAddr);
        stableOut = vault.withdrawCapital(stableNeeded);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsNameAndSymbol() public view {
        assertEq(vault.name(), "Test Portfolio");
        assertEq(vault.symbol(), "tPORT");
    }

    function test_constructor_setsState() public view {
        assertEq(vault.asset(), address(usdc));
        assertEq(address(vault.poolManager()), address(mockPM));
        assertEq(address(vault.instrumentRegistry()), address(instrumentRegistry));
        assertEq(address(vault.swapPoolRegistry()), address(swapPoolRegistry));
        assertEq(address(vault.strategy()), address(strategy));
        assertEq(vault.hook(), hookAddr);
    }

    function test_constructor_setsAllocations() public view {
        assertEq(vault.getAllocationsLength(), 1);
        PortfolioVault.Allocation[] memory allocs = vault.getAllocations();
        assertEq(allocs[0].instrumentId, usdcInstrumentId);
        assertEq(allocs[0].weightBps, 10000);
    }

    // ============ setHook Tests ============

    function test_setHook_revertsIfAlreadySet() public {
        vm.prank(owner);
        vm.expectRevert(PortfolioVault.HookAlreadySet.selector);
        vault.setHook(makeAddr("newHook"));
    }

    function test_setHook_revertsOnZeroAddress() public {
        PortfolioVault fresh = new PortfolioVault(
            PortfolioVault.InitParams({
                initialOwner: owner,
                name: "Fresh",
                symbol: "FR",
                stable: usdcCurrency,
                poolManager: IPoolManager(address(mockPM)),
                instrumentRegistry: instrumentRegistry,
                swapPoolRegistry: swapPoolRegistry,
                strategy: IPortfolioStrategy(address(strategy)),
                allocations: _singleAllocation(usdcInstrumentId, 10000)
            })
        );

        vm.prank(owner);
        vm.expectRevert(PortfolioVault.InvalidHookAddress.selector);
        fresh.setHook(address(0));
    }

    function test_setHook_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setHook(makeAddr("newHook"));
    }

    // ============ deployCapital Tests ============

    function test_deployCapital_depositsToLending() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function test_deployCapital_totalAssetsUpdated() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    function test_deployCapital_revertsIfNotHook() public {
        vm.prank(user);
        vm.expectRevert(PortfolioVault.OnlyHook.selector);
        vault.deployCapital(DEPOSIT_AMOUNT);
    }

    function test_deployCapital_emitsEvent() public {
        usdc.mint(address(vault), DEPOSIT_AMOUNT);
        vm.expectEmit(false, false, false, true);
        emit PortfolioVault.Allocated(DEPOSIT_AMOUNT);
        vm.prank(hookAddr);
        vault.deployCapital(DEPOSIT_AMOUNT);
    }

    // ============ mintShares Tests ============

    function test_mintShares_mintsToRecipient() public {
        _mintSharesAsHook(user, 1000e6);
        assertEq(vault.balanceOf(user), 1000e6);
        assertEq(vault.totalSupply(), 1000e6);
    }

    function test_mintShares_revertsIfNotHook() public {
        vm.prank(user);
        vm.expectRevert(PortfolioVault.OnlyHook.selector);
        vault.mintShares(user, 1000e6);
    }

    // ============ burnShares Tests ============

    function test_burnShares_burnsFromAddress() public {
        _mintSharesAsHook(user, 1000e6);

        vm.prank(hookAddr);
        vault.burnShares(user, 400e6);

        assertEq(vault.balanceOf(user), 600e6);
        assertEq(vault.totalSupply(), 600e6);
    }

    function test_burnShares_emitsEvent() public {
        _mintSharesAsHook(user, 1000e6);

        vm.expectEmit(true, false, false, true);
        emit PortfolioVault.SharesBurned(user, 400e6);
        vm.prank(hookAddr);
        vault.burnShares(user, 400e6);
    }

    function test_burnShares_revertsIfNotHook() public {
        _mintSharesAsHook(user, 1000e6);

        vm.prank(user);
        vm.expectRevert(PortfolioVault.OnlyHook.selector);
        vault.burnShares(user, 400e6);
    }

    function test_burnShares_revertsOnInsufficientBalance() public {
        _mintSharesAsHook(user, 1000e6);

        vm.prank(hookAddr);
        vm.expectRevert(); // ERC20 underflow
        vault.burnShares(user, 2000e6);
    }

    // ============ withdrawCapital Tests ============

    function test_withdrawCapital_returnsStable() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);

        assertEq(stableOut, DEPOSIT_AMOUNT);
    }

    function test_withdrawCapital_sendsToHook() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 hookBalBefore = usdc.balanceOf(hookAddr);
        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);

        assertEq(usdc.balanceOf(hookAddr), hookBalBefore + stableOut);
    }

    function test_withdrawCapital_partialWithdraw() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT / 2);

        assertApproxEqRel(stableOut, DEPOSIT_AMOUNT / 2, 1e15);
    }

    function test_withdrawCapital_revertsIfNotHook() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(PortfolioVault.OnlyHook.selector);
        vault.withdrawCapital(DEPOSIT_AMOUNT);
    }

    function test_withdrawCapital_emitsEvent() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        vm.prank(hookAddr);
        vm.expectEmit(false, false, false, true);
        emit PortfolioVault.Deallocated(DEPOSIT_AMOUNT);
        vault.withdrawCapital(DEPOSIT_AMOUNT);
    }

    function test_withdrawCapital_zeroNav_returnsZero() public {
        // No capital deployed — totalAssets() == 0
        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);
        assertEq(stableOut, 0);
    }

    function test_withdrawCapital_zeroNav_doesNotBrickVault() public {
        // Call withdrawCapital with zero NAV
        _withdrawCapitalAsHook(DEPOSIT_AMOUNT);

        // Vault should still be functional — deployCapital should work
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    function test_withdrawCapital_zeroNav_thenDeploy_thenWithdraw() public {
        // Full cycle: withdraw on empty → deploy → withdraw
        _withdrawCapitalAsHook(1000e6);

        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);
        assertEq(stableOut, DEPOSIT_AMOUNT);
    }

    // ============ ERC-4626 View Tests ============

    function test_previewDeposit_beforeAnyDeposit() public view {
        uint256 shares = vault.previewDeposit(DEPOSIT_AMOUNT);
        assertGt(shares, 0);
    }

    function test_convertToAssets_roundtrip() public {
        // Simulate a full buy: deploy capital first, THEN calculate shares based on new NAV
        uint256 sharesBefore = vault.previewDeposit(DEPOSIT_AMOUNT);
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, sharesBefore);

        uint256 shares = vault.balanceOf(user);
        uint256 assets = vault.convertToAssets(shares);
        assertApproxEqRel(assets, DEPOSIT_AMOUNT, 1e15);
    }

    function test_totalAssets_emptyVault() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_previewMint_roundsUp() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        // previewMint should round up (ceil) — costs more assets
        uint256 shares = 333e6;
        uint256 assetsNeeded = vault.previewMint(shares);
        uint256 assetsFloor = vault.convertToAssets(shares);
        assertGe(assetsNeeded, assetsFloor);
    }

    function test_previewWithdraw_roundsUp() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        // previewWithdraw should round up (ceil) — costs more shares
        uint256 assets = 333e6;
        uint256 sharesNeeded = vault.previewWithdraw(assets);
        uint256 sharesFloor = vault.convertToShares(assets);
        assertGe(sharesNeeded, sharesFloor);
    }

    function test_previewMint_zeroShares_returnsZero() public view {
        assertEq(vault.previewMint(0), 0);
    }

    function test_previewWithdraw_zeroAssets_returnsZero() public view {
        assertEq(vault.previewWithdraw(0), 0);
    }

    // ============ Effective Total Supply Tests ============

    function test_effectiveTotalSupply_excludesPMShares() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        // Mint shares directly to PM (simulates dead shares from sells)
        _mintSharesAsHook(address(mockPM), 500e6);

        // convertToAssets should use effective supply (excluding PM shares)
        uint256 assetsPerShare = vault.convertToAssets(1000e6);

        // With effective supply = 1000e6, NAV = DEPOSIT_AMOUNT
        assertApproxEqRel(assetsPerShare, DEPOSIT_AMOUNT, 1e15);
    }

    function test_effectiveTotalSupply_allSharesInPM_returnsZero() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        // Mint shares only to PM
        _mintSharesAsHook(address(mockPM), 1000e6);

        // Effective supply is 0, so convertToShares uses only virtual values
        uint256 shares = vault.convertToShares(DEPOSIT_AMOUNT);
        assertGt(shares, 0);
    }

    // ============ setAllocations Tests ============

    function test_setAllocations_updatesWeights() public {
        PortfolioVault.Allocation[] memory newAllocs = _dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000);

        vm.prank(owner);
        vault.setAllocations(newAllocs);

        PortfolioVault.Allocation[] memory result = vault.getAllocations();
        assertEq(result.length, 2);
        assertEq(result[0].weightBps, 6000);
        assertEq(result[1].weightBps, 4000);
    }

    function test_setAllocations_revertsIfNotOwner() public {
        PortfolioVault.Allocation[] memory newAllocs = _singleAllocation(usdcInstrumentId, 10000);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setAllocations(newAllocs);
    }

    function test_setAllocations_revertsIfWeightsDontSum() public {
        PortfolioVault.Allocation[] memory bad = _singleAllocation(usdcInstrumentId, 5000);

        vm.prank(owner);
        vm.expectRevert(PortfolioVault.WeightsMustSumTo10000.selector);
        vault.setAllocations(bad);
    }

    function test_setAllocations_revertsIfEmpty() public {
        PortfolioVault.Allocation[] memory empty = new PortfolioVault.Allocation[](0);

        vm.prank(owner);
        vm.expectRevert(PortfolioVault.InvalidAllocationsLength.selector);
        vault.setAllocations(empty);
    }

    function test_setAllocations_revertsIfTooMany() public {
        PortfolioVault.Allocation[] memory tooMany = new PortfolioVault.Allocation[](11);
        for (uint256 i = 0; i < 11; i++) {
            tooMany[i] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 909});
        }

        vm.prank(owner);
        vm.expectRevert(PortfolioVault.TooManyAllocations.selector);
        vault.setAllocations(tooMany);
    }

    function test_setAllocations_revertsOnUnregisteredInstrument() public {
        bytes32 fakeId = keccak256("fake");
        PortfolioVault.Allocation[] memory bad = _singleAllocation(fakeId, 10000);

        vm.prank(owner);
        vm.expectRevert(InstrumentRegistry.InstrumentNotRegistered.selector);
        vault.setAllocations(bad);
    }

    function test_setAllocations_emitsEvent() public {
        PortfolioVault.Allocation[] memory newAllocs = _singleAllocation(usdcInstrumentId, 10000);

        vm.expectEmit(false, false, false, true);
        emit PortfolioVault.AllocationsUpdated(1);
        vm.prank(owner);
        vault.setAllocations(newAllocs);
    }

    // ============ Dual Allocation Tests ============

    function test_deployCapital_dualAllocation_splitsCorrectly() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000));

        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        assertEq(aUsdc.balanceOf(address(vault)), (DEPOSIT_AMOUNT * 6000) / 10000);
        assertEq(aUsdt.balanceOf(address(vault)), (DEPOSIT_AMOUNT * 4000) / 10000);
    }

    function test_withdrawCapital_dualAllocation_withdrawsProportionally() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000));

        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);

        assertApproxEqRel(stableOut, DEPOSIT_AMOUNT, 1e15);
    }

    function test_totalAssets_dualAllocation_sumsAll() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000));

        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // Both allocations contribute to totalAssets (1:1 mock aTokens)
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    // ============ Rebalance Tests ============

    function test_rebalance_emitsEvent() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 5000, usdtInstrumentId, 5000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // Change weights to 70/30
        vm.prank(owner);
        vault.setAllocations(_dualAllocation(usdcInstrumentId, 7000, usdtInstrumentId, 3000));

        // Fund pools for withdrawals
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, false);
        emit PortfolioVault.Rebalanced();
        vm.prank(owner);
        vault.rebalance();
    }

    function test_rebalance_zeroNav_noop() public {
        // No capital deployed — rebalance should be a no-op
        vm.prank(owner);
        vault.rebalance();
        assertEq(vault.totalAssets(), 0);
    }

    function test_rebalance_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.rebalance();
    }

    // ============ unlockCallback Tests ============

    function test_unlockCallback_revertsOnNonPoolManager() public {
        vm.prank(user);
        vm.expectRevert(PortfolioVault.CallerNotPoolManager.selector);
        vault.unlockCallback("");
    }

    // ============ strategyTransfer Tests ============

    function test_strategyTransfer_revertsIfNotStrategy() public {
        vm.prank(user);
        vm.expectRevert(PortfolioVault.OnlyStrategy.selector);
        vault.strategyTransfer(address(usdc), user, 100);
    }

    // ============ Slippage Protection Tests ============

    function test_setMaxSlippageBps_updatesValue() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(200);
        assertEq(vault.maxSlippageBps(), 200);
    }

    function test_setMaxSlippageBps_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setMaxSlippageBps(200);
    }

    function test_setMaxSlippageBps_revertsIfTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(PortfolioVault.InvalidSlippageBps.selector);
        vault.setMaxSlippageBps(10001);
    }

    function test_setMaxSlippageBps_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PortfolioVault.MaxSlippageUpdated(200);
        vm.prank(owner);
        vault.setMaxSlippageBps(200);
    }

    function test_maxSlippageBps_defaultValue() public view {
        assertEq(vault.maxSlippageBps(), 100); // 1% default
    }

    function test_setMaxSlippageBps_allowsZero() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(0);
        assertEq(vault.maxSlippageBps(), 0);
    }

    // ============ Hook Approval Revocation Tests ============

    function test_revokeHookApproval_revokesApproval() public {
        uint256 allowanceBefore = usdc.allowance(address(vault), hookAddr);
        assertEq(allowanceBefore, type(uint256).max);

        vm.prank(owner);
        vault.revokeHookApproval();

        uint256 allowanceAfter = usdc.allowance(address(vault), hookAddr);
        assertEq(allowanceAfter, 0);
    }

    function test_revokeHookApproval_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.revokeHookApproval();
    }

    function test_revokeHookApproval_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit PortfolioVault.HookApprovalRevoked();
        vm.prank(owner);
        vault.revokeHookApproval();
    }

    // ============ Cross-Currency NAV Tests ============

    function test_totalAssets_crossCurrency_convertsToStable() public {
        // Deploy with dual allocation (USDC 60% + USDT 40%)
        _deployVault(_dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000));

        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // With 1:1 pool price, totalAssets should equal DEPOSIT_AMOUNT
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    // ============ Adapter convertToUnderlying Tests ============

    function test_totalAssets_usesAdapterConversion() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // With Aave's 1:1 aToken, totalAssets should match deposit
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }
}
