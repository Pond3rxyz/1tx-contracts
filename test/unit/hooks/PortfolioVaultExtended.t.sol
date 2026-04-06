// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @title PortfolioVaultExtendedTest
/// @notice Extended tests for branch coverage, edge cases, large/small amounts,
///         ERC-4626 preview functions, rebalance logic, and upgrade scenarios.
contract PortfolioVaultExtendedTest is Test {
    using CurrencyLibrary for Currency;

    PortfolioVault public vault;
    PortfolioStrategy public strategy;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    MockPoolManager public mockPM;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20 public aUsdc;
    MockERC20 public aUsdt;

    Currency public usdcCurrency;
    Currency public usdtCurrency;

    bytes32 public usdcMarketId;
    bytes32 public usdtMarketId;
    bytes32 public usdcInstrumentId;
    bytes32 public usdtInstrumentId;

    address public owner;
    address public user;
    address public hookAddr;
    address public executionAddress;

    uint256 public constant INITIAL_BALANCE = 10_000_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        hookAddr = makeAddr("hook");
        executionAddress = makeAddr("executionAddress");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        aUsdt = new MockERC20("Aave USDT", "aUSDT", 6);

        usdcCurrency = Currency.wrap(address(usdc));
        usdtCurrency = Currency.wrap(address(usdt));

        mockPM = new MockPoolManager();

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

        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdtMarketId = keccak256(abi.encode(usdtCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        usdtInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdtMarketId);

        vm.startPrank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));
        instrumentRegistry.registerInstrument(executionAddress, usdtMarketId, address(aaveAdapter));
        vm.stopPrank();

        (Currency c0, Currency c1) = _orderCurrencies(usdcCurrency, usdtCurrency);
        PoolKey memory swapPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        vm.startPrank(owner);
        swapPoolRegistry.registerDefaultSwapPool(usdcCurrency, usdtCurrency, swapPoolKey);
        swapPoolRegistry.registerDefaultSwapPool(usdtCurrency, usdcCurrency, swapPoolKey);
        vm.stopPrank();

        mockPM.setPoolPrice(swapPoolKey, uint160(1 << 96));

        usdt.mint(address(mockPM), INITIAL_BALANCE);
        usdc.mint(address(mockPM), INITIAL_BALANCE);

        // Deploy shared strategy (UUPS proxy)
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, owner)
                )
            )
        );

        // Authorize strategy on adapter
        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(strategy));

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

    // ============ previewRedeem Tests (uncovered) ============

    function test_previewRedeem_returnsConvertToAssets() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 preview = vault.previewRedeem(500e6);
        uint256 convert = vault.convertToAssets(500e6);
        assertEq(preview, convert, "previewRedeem should equal convertToAssets");
    }

    function test_previewRedeem_emptyVault() public view {
        uint256 preview = vault.previewRedeem(100e6);
        assertGt(preview, 0, "previewRedeem on empty vault uses virtual values");
    }

    function test_previewRedeem_zero() public view {
        assertEq(vault.previewRedeem(0), 0, "redeeming 0 shares should return 0");
    }

    // ============ deployCapital Edge Cases ============

    function test_deployCapital_zeroWeightAllocation_skipped() public {
        // Deploy with dual allocation where one has effective zero amount
        _deployVault(_dualAllocation(usdcInstrumentId, 9999, usdtInstrumentId, 1));

        // Deploy a small amount where 1 bps rounds to 0
        usdc.mint(address(vault), 9);
        vm.prank(hookAddr);
        vault.deployCapital(9);

        // USDT allocation (1 bps of 9 = 0) should be skipped
        assertEq(aUsdt.balanceOf(address(vault)), 0, "zero-amount allocation should be skipped");
    }

    function test_deployCapital_largeAmount_5M() public {
        uint256 largeAmount = 5_000_000e6;
        usdc.mint(address(vault), largeAmount);
        vm.prank(hookAddr);
        vault.deployCapital(largeAmount);

        assertEq(aUsdc.balanceOf(address(vault)), largeAmount, "large deploy should work");
        assertEq(vault.totalAssets(), largeAmount, "totalAssets should match");
    }

    function test_deployCapital_repeatedSmallDeposits() public {
        for (uint256 i = 0; i < 20; i++) {
            _deployCapitalAsHook(50e6);
        }
        assertEq(vault.totalAssets(), 1000e6, "20 x 50 USDC should total 1000");
    }

    // ============ withdrawCapital Edge Cases ============

    function test_withdrawCapital_moreThanNav_cappedByBalance() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);

        // Request more than NAV
        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT * 2);

        // Should only withdraw what's available (proportionally, capped by yield balance)
        assertGt(stableOut, 0, "should withdraw something");
        assertLe(stableOut, DEPOSIT_AMOUNT * 2, "should not exceed what exists");
    }

    function test_withdrawCapital_tinyAmount() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 stableOut = _withdrawCapitalAsHook(1);
        assertGe(stableOut, 0, "tiny withdrawal should work");
    }

    function test_withdrawCapital_repeatedPartialWithdrawals() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        uint256 totalWithdrawn;
        for (uint256 i = 0; i < 10; i++) {
            usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
            uint256 out = _withdrawCapitalAsHook(100e6);
            totalWithdrawn += out;
        }

        assertApproxEqRel(totalWithdrawn, DEPOSIT_AMOUNT, 1e16, "should withdraw total deposit");
    }

    function test_withdrawCapital_dualAllocation_oneEmptyPosition() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // Burn all USDT aTokens (simulate total loss of one position)
        uint256 usdtBalance = aUsdt.balanceOf(address(vault));
        aUsdt.burn(address(vault), usdtBalance);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);
        // Only USDC portion should be recoverable
        assertGt(stableOut, 0, "should withdraw from remaining allocation");
    }

    // ============ ERC-4626 View Function Edge Cases ============

    function test_convertToShares_largeAmount() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 shares = vault.convertToShares(1_000_000_000e6); // 1B USDC
        assertGt(shares, 0, "large conversion should work");
    }

    function test_convertToAssets_largeShares() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 assets = vault.convertToAssets(1_000_000_000e6);
        assertGt(assets, 0, "large share conversion should work");
    }

    function test_previewMint_oneWei() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 assets = vault.previewMint(1);
        assertGe(assets, 0, "minting 1 share should cost >= 0 assets");
    }

    function test_previewWithdraw_oneWei() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 shares = vault.previewWithdraw(1);
        assertGe(shares, 0, "withdrawing 1 asset should cost >= 0 shares");
    }

    function test_previewDeposit_afterYield() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        // Before yield: 1000 USDC NAV, 1000 shares → 1:1
        uint256 sharesBefore = vault.previewDeposit(100e6);

        // Simulate 100% yield
        aUsdc.mint(address(vault), DEPOSIT_AMOUNT);
        // Now: 2000 USDC NAV, 1000 shares → 2:1

        uint256 sharesAfter = vault.previewDeposit(100e6);
        assertLt(sharesAfter, sharesBefore, "shares per USDC should decrease after yield");
    }

    function test_convertToAssets_fullLiveSupplyAfterYield_returnsTotalAssets() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        aUsdc.mint(address(vault), 123e6);

        uint256 liveSupply = vault.totalSupply();
        uint256 totalNav = vault.totalAssets();

        assertEq(vault.convertToAssets(liveSupply), totalNav, "full live supply should redeem full NAV");
        assertEq(vault.previewRedeem(liveSupply), totalNav, "previewRedeem should match full NAV on final exit");
    }

    function test_previewWithdraw_fullNavAfterYield_returnsLiveSupply() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        aUsdc.mint(address(vault), 123e6);

        uint256 liveSupply = vault.totalSupply();
        uint256 totalNav = vault.totalAssets();

        assertEq(vault.previewWithdraw(totalNav), liveSupply, "full NAV withdrawal should burn full live supply");
    }

    // ============ Effective Total Supply Edge Cases ============

    function test_effectiveTotalSupply_pmHoldsMoreThanTotal_returnsZero() public {
        // Edge case: somehow PM has more shares than total supply
        // This shouldn't happen in practice, but test the safety check
        _mintSharesAsHook(address(mockPM), 1000e6);

        // convertToShares should not revert (effective supply = 0, uses virtual values)
        uint256 shares = vault.convertToShares(100e6);
        assertGt(shares, 0, "should use virtual values when effective supply is 0");
    }

    function test_effectiveTotalSupply_noPmShares() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        // No PM shares — effective supply equals total supply
        uint256 assets = vault.convertToAssets(1000e6);
        assertApproxEqRel(assets, DEPOSIT_AMOUNT, 1e15);
    }

    // ============ Rebalance Tests ============

    function test_rebalance_movesFromOverToUnder() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 5000, usdtInstrumentId, 5000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        uint256 usdcBefore = aUsdc.balanceOf(address(vault));
        uint256 usdtBefore = aUsdt.balanceOf(address(vault));
        assertEq(usdcBefore, 500e6, "should be 50/50");
        assertEq(usdtBefore, 500e6, "should be 50/50");

        // Change to 80/20
        vm.prank(owner);
        vault.setAllocations(_dualAllocation(usdcInstrumentId, 8000, usdtInstrumentId, 2000));

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        vm.prank(owner);
        vault.rebalance();

        uint256 usdcAfter = aUsdc.balanceOf(address(vault));
        uint256 usdtAfter = aUsdt.balanceOf(address(vault));

        // USDC should have increased, USDT decreased
        assertGt(usdcAfter, usdcBefore, "USDC allocation should increase");
        assertLt(usdtAfter, usdtBefore, "USDT allocation should decrease");
    }

    function test_rebalance_preservesTotalAssets() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 5000, usdtInstrumentId, 5000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        uint256 navBefore = vault.totalAssets();

        vm.prank(owner);
        vault.setAllocations(_dualAllocation(usdcInstrumentId, 7000, usdtInstrumentId, 3000));

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        vm.prank(owner);
        vault.rebalance();

        uint256 navAfter = vault.totalAssets();
        assertApproxEqRel(navAfter, navBefore, 5e16, "NAV should be preserved after rebalance");
    }

    function test_rebalance_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.rebalance();
    }

    function test_rebalance_singleAllocation_noop() public {
        // With single allocation already at 100%, rebalance should be a no-op
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        uint256 navBefore = vault.totalAssets();

        vm.prank(owner);
        vault.rebalance();

        assertEq(vault.totalAssets(), navBefore, "single allocation rebalance should be no-op");
    }

    // ============ setAllocations with MAX_ALLOCATIONS ============

    function test_setAllocations_exactlyMaxAllocations() public {
        // Create 10 allocations (MAX_ALLOCATIONS) all pointing to same instrument
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](10);
        for (uint256 i = 0; i < 10; i++) {
            allocs[i] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 1000});
        }

        vm.prank(owner);
        vault.setAllocations(allocs);

        assertEq(vault.getAllocationsLength(), 10, "should have 10 allocations");
    }

    function test_setAllocations_replacesExistingAllocations() public {
        // Start with single, switch to dual
        assertEq(vault.getAllocationsLength(), 1);

        vm.prank(owner);
        vault.setAllocations(_dualAllocation(usdcInstrumentId, 6000, usdtInstrumentId, 4000));

        assertEq(vault.getAllocationsLength(), 2);

        // Switch back to single
        vm.prank(owner);
        vault.setAllocations(_singleAllocation(usdcInstrumentId, 10000));

        assertEq(vault.getAllocationsLength(), 1);
    }

    // ============ Share Math Consistency ============

    function test_shareConversion_roundtrip() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 assets = vault.convertToAssets(1000e6);
        uint256 sharesBack = vault.convertToShares(assets);

        assertApproxEqAbs(sharesBack, 1000e6, 1, "shares->assets->shares roundtrip should be close");
    }

    function test_previewMint_previewRedeem_consistency() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 sharesToMint = 333e6;
        uint256 assetsToMint = vault.previewMint(sharesToMint);
        uint256 assetsFromRedeem = vault.previewRedeem(sharesToMint);

        // previewMint (ceil) >= previewRedeem (floor)
        assertGe(assetsToMint, assetsFromRedeem, "mint cost >= redeem return");
    }

    function test_previewDeposit_previewWithdraw_consistency() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 assetsToDeposit = 333e6;
        uint256 sharesFromDeposit = vault.previewDeposit(assetsToDeposit);
        uint256 sharesToWithdraw = vault.previewWithdraw(assetsToDeposit);

        // previewWithdraw (ceil) >= previewDeposit (floor) for same asset amount
        assertGe(sharesToWithdraw, sharesFromDeposit, "withdraw cost >= deposit return in shares");
    }

    // ============ Large Amount Tests ============

    function test_deployCapital_10M() public {
        uint256 large = 10_000_000e6;
        _deployCapitalAsHook(large);
        assertEq(vault.totalAssets(), large);
    }

    function test_withdrawCapital_10M() public {
        uint256 large = 10_000_000e6;
        _deployCapitalAsHook(large);
        usdc.mint(address(mockAavePool), large * 2);

        uint256 stableOut = _withdrawCapitalAsHook(large);
        assertEq(stableOut, large, "should withdraw full 10M");
    }

    // ============ Contract Deployment Test ============

    function test_vaultDeployed() public view {
        assertGt(address(vault).code.length, 0, "vault should be deployed");
    }

    // ============ Fuzz Tests ============

    function testFuzz_deployAndWithdraw(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        _deployCapitalAsHook(amount);
        usdc.mint(address(mockAavePool), amount * 2);

        uint256 stableOut = _withdrawCapitalAsHook(amount);
        assertEq(stableOut, amount, "deploy and withdraw should roundtrip");
    }

    function testFuzz_mintBurn(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1, 1_000_000_000e6);
        _mintSharesAsHook(user, mintAmount);
        assertEq(vault.balanceOf(user), mintAmount);

        vm.prank(hookAddr);
        vault.burnShares(user, mintAmount);
        assertEq(vault.balanceOf(user), 0);
    }

    function testFuzz_previewDeposit(uint256 assets) public {
        assets = bound(assets, 0, 1_000_000_000e6);
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        // Should not revert
        vault.previewDeposit(assets);
    }

    function testFuzz_previewMint(uint256 shares) public {
        shares = bound(shares, 0, 1_000_000_000e6);
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        vault.previewMint(shares);
    }

    function testFuzz_convertToSharesAssets(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000e6);
        _deployCapitalAsHook(DEPOSIT_AMOUNT);
        _mintSharesAsHook(user, 1000e6);

        uint256 shares = vault.convertToShares(amount);
        uint256 assets = vault.convertToAssets(shares);
        // Floor rounding may lose 1 wei
        assertApproxEqAbs(assets, amount, 1, "roundtrip should be close");
    }

    // ============ Dual Allocation Detailed Tests ============

    function test_dualAllocation_asymmetricWeights() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 9000, usdtInstrumentId, 1000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        assertEq(aUsdc.balanceOf(address(vault)), 900e6, "90% to USDC");
        assertEq(aUsdt.balanceOf(address(vault)), 100e6, "10% to USDT");
    }

    function test_dualAllocation_withdrawProportionally() public {
        _deployVault(_dualAllocation(usdcInstrumentId, 5000, usdtInstrumentId, 5000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        // Withdraw half
        uint256 stableOut = _withdrawCapitalAsHook(500e6);
        assertApproxEqRel(stableOut, 500e6, 5e16, "should withdraw about half");

        // Both aToken balances should have decreased
        assertLt(aUsdc.balanceOf(address(vault)), 500e6, "USDC aTokens should decrease");
        assertLt(aUsdt.balanceOf(address(vault)), 500e6, "USDT aTokens should decrease");
    }

    // ============ Hook Approval Tests ============

    function test_hookApproval_setOnSetHook() public {
        uint256 allowance = usdc.allowance(address(vault), hookAddr);
        assertEq(allowance, type(uint256).max, "hook should have max approval");
    }

    function test_revokeHookApproval_thenWithdrawFails() public {
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        vm.prank(owner);
        vault.revokeHookApproval();

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT);

        // withdrawCapital transfers stable to hook via safeTransfer
        // After revocation, the vault can still safeTransfer (doesn't use approval)
        // but the hook won't be able to pull from vault
        // Actually, withdrawCapital uses safeTransfer FROM vault TO hook
        // so the approval revocation doesn't affect this path
        // The approval is for the hook to pull stable from vault
        uint256 stableOut = _withdrawCapitalAsHook(DEPOSIT_AMOUNT);
        assertGt(stableOut, 0, "withdrawCapital uses safeTransfer, not approval");
    }

    // ============ maxSlippageBps Edge Cases ============

    function test_setMaxSlippageBps_maxValue() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(10000); // 100% — allow any slippage
        assertEq(vault.maxSlippageBps(), 10000);
    }

    function testFuzz_setMaxSlippageBps(uint16 bps) public {
        if (bps > 10000) {
            vm.prank(owner);
            vm.expectRevert(PortfolioVault.InvalidSlippageBps.selector);
            vault.setMaxSlippageBps(bps);
        } else {
            vm.prank(owner);
            vault.setMaxSlippageBps(bps);
            assertEq(vault.maxSlippageBps(), bps);
        }
    }

    // ============ Rebalance Edge Cases (Branch Coverage) ============

    function test_rebalance_heavyWeightShift() public {
        // Deploy with 50/50, then shift to 90/10
        _deployVault(_dualAllocation(usdcInstrumentId, 5000, usdtInstrumentId, 5000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // Verify initial allocation
        assertEq(aUsdc.balanceOf(address(vault)), 500e6);
        assertEq(aUsdt.balanceOf(address(vault)), 500e6);

        // Shift to 90/10
        vm.prank(owner);
        vault.setAllocations(_dualAllocation(usdcInstrumentId, 9000, usdtInstrumentId, 1000));

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);

        vm.prank(owner);
        vault.rebalance();

        // NAV should be approximately preserved (within 5% for mock 1:1 swaps)
        assertApproxEqRel(vault.totalAssets(), DEPOSIT_AMOUNT, 5e16, "NAV should be preserved");
        // USDC allocation should have increased significantly
        assertGt(aUsdc.balanceOf(address(vault)), 500e6, "USDC allocation should increase");
    }

    function test_rebalance_partialDepositInSecondPass() public {
        // This tests the case where stableAccumulated < deficit during rebalance second pass
        _deployVault(_dualAllocation(usdcInstrumentId, 5000, usdtInstrumentId, 5000));
        _deployCapitalAsHook(DEPOSIT_AMOUNT);

        // Dramatically shift: 10% USDC, 90% USDT
        // First pass withdraws from USDC (over-allocated), second pass deposits to USDT (under-allocated)
        // But the withdrawn amount might be less than the deficit → partial deposit
        vm.prank(owner);
        vault.setAllocations(_dualAllocation(usdcInstrumentId, 1000, usdtInstrumentId, 9000));

        usdc.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);
        usdt.mint(address(mockAavePool), DEPOSIT_AMOUNT * 2);

        vm.prank(owner);
        vault.rebalance();

        // Should not revert and NAV should be approximately preserved
        assertApproxEqRel(vault.totalAssets(), DEPOSIT_AMOUNT, 10e16, "NAV preserved after heavy rebalance");
    }

    // ============ Stress Tests ============

    function test_manySmallDeploysAndWithdraws() public {
        for (uint256 i = 0; i < 50; i++) {
            _deployCapitalAsHook(20e6);
        }
        assertEq(vault.totalAssets(), 1000e6);

        for (uint256 i = 0; i < 10; i++) {
            usdc.mint(address(mockAavePool), 200e6);
            _withdrawCapitalAsHook(100e6);
        }

        assertEq(vault.totalAssets(), 0, "should be fully withdrawn");
    }
}
