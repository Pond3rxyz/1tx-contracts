// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    Currency,
    CurrencyLibrary
} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {CompoundAdapter} from "../../../src/adapters/CompoundAdapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";
import {MockCompoundComet} from "../../mocks/MockCompoundComet.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";

/// @title AdapterFuzzTest
/// @notice Fuzz tests for all adapter implementations
contract AdapterFuzzTest is Test {
    using CurrencyLibrary for Currency;

    // Common
    address public owner;
    address public authorizedCaller;
    MockERC20 public usdc;
    Currency public usdcCurrency;
    bytes32 public usdcMarketId;

    // Aave
    AaveAdapter public aaveAdapter;
    MockAavePool public mockPool;
    MockERC20 public aUsdc;

    // Compound
    CompoundAdapter public compoundAdapter;
    MockCompoundComet public mockComet;

    // Morpho
    MorphoAdapter public morphoAdapter;
    MockERC4626Vault public mockMorphoVault;
    bytes32 public morphoMarketId;

    // Fluid
    FluidAdapter public fluidAdapter;
    MockERC4626Vault public mockFToken;
    bytes32 public fluidMarketId;

    uint256 constant MAX_DEPOSIT = 1_000_000_000e6; // 1B tokens
    uint256 constant INITIAL_BALANCE = 10_000_000_000e6; // 10B tokens for fuzz testing

    function setUp() public {
        owner = makeAddr("owner");
        authorizedCaller = makeAddr("authorizedCaller");

        // Deploy mock token
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdcCurrency = Currency.wrap(address(usdc));
        usdcMarketId = keccak256(abi.encode(usdcCurrency));

        // Setup Aave
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        mockPool = new MockAavePool();
        mockPool.setReserveData(address(usdc), address(aUsdc));
        usdc.mint(address(mockPool), INITIAL_BALANCE);

        vm.prank(owner);
        aaveAdapter = new AaveAdapter(address(mockPool), owner);
        vm.startPrank(owner);
        aaveAdapter.registerMarket(usdcCurrency);
        aaveAdapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // Setup Compound
        mockComet = new MockCompoundComet(address(usdc));
        usdc.mint(address(mockComet), INITIAL_BALANCE);

        vm.prank(owner);
        compoundAdapter = new CompoundAdapter(owner);
        vm.startPrank(owner);
        compoundAdapter.registerMarket(usdcCurrency, address(mockComet));
        compoundAdapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // Setup Morpho
        mockMorphoVault = new MockERC4626Vault(
            address(usdc),
            "Morpho USDC",
            "mvUSDC"
        );
        morphoMarketId = bytes32(uint256(uint160(address(mockMorphoVault))));

        vm.prank(owner);
        morphoAdapter = new MorphoAdapter(owner);
        vm.startPrank(owner);
        morphoAdapter.registerVault(usdcCurrency, address(mockMorphoVault));
        morphoAdapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        // Setup Fluid
        mockFToken = new MockERC4626Vault(address(usdc), "Fluid USDC", "fUSDC");
        fluidMarketId = bytes32(uint256(uint160(address(mockFToken))));

        vm.prank(owner);
        fluidAdapter = new FluidAdapter(owner);
        vm.startPrank(owner);
        fluidAdapter.registerFToken(usdcCurrency, address(mockFToken));
        fluidAdapter.addAuthorizedCaller(authorizedCaller);
        vm.stopPrank();
    }

    // ============ Amount Fuzzing Tests ============

    function testFuzz_aaveDeposit_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(aaveAdapter), amount);

        vm.prank(user);
        aaveAdapter.deposit(usdcMarketId, amount, user);

        assertEq(aUsdc.balanceOf(user), amount);
    }

    function testFuzz_compoundDeposit_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(compoundAdapter), amount);

        vm.prank(user);
        compoundAdapter.deposit(usdcMarketId, amount, user);

        assertEq(mockComet.balanceOf(user), amount);
    }

    function testFuzz_morphoDeposit_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(morphoAdapter), amount);

        vm.prank(user);
        morphoAdapter.deposit(morphoMarketId, amount, user);

        assertEq(mockMorphoVault.balanceOf(user), amount);
    }

    function testFuzz_fluidDeposit_amountBounds(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(fluidAdapter), amount);

        vm.prank(user);
        fluidAdapter.deposit(fluidMarketId, amount, user);

        assertEq(mockFToken.balanceOf(user), amount);
    }

    // ============ Recipient Address Fuzzing Tests ============

    function testFuzz_aaveDeposit_toRecipient(address recipient) public {
        vm.assume(recipient != address(0));

        uint256 amount = 1000e6;
        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(aaveAdapter), amount);

        vm.prank(user);
        aaveAdapter.deposit(usdcMarketId, amount, recipient);

        assertEq(aUsdc.balanceOf(recipient), amount);
    }

    function testFuzz_compoundDeposit_toRecipient(address recipient) public {
        vm.assume(recipient != address(0));

        uint256 amount = 1000e6;
        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(compoundAdapter), amount);

        vm.prank(user);
        compoundAdapter.deposit(usdcMarketId, amount, recipient);

        assertEq(mockComet.balanceOf(recipient), amount);
    }

    function testFuzz_morphoDeposit_toRecipient(address recipient) public {
        vm.assume(recipient != address(0));

        uint256 amount = 1000e6;
        address user = makeAddr("user");
        usdc.mint(user, amount);

        vm.prank(user);
        usdc.approve(address(morphoAdapter), amount);

        vm.prank(user);
        morphoAdapter.deposit(morphoMarketId, amount, recipient);

        assertEq(mockMorphoVault.balanceOf(recipient), amount);
    }

    // ============ Invalid Market ID Fuzzing Tests ============

    function testFuzz_aave_invalidMarketId_reverts(
        bytes32 randomMarketId
    ) public {
        vm.assume(randomMarketId != usdcMarketId);

        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        vm.prank(user);
        usdc.approve(address(aaveAdapter), 1000e6);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        aaveAdapter.deposit(randomMarketId, 1000e6, user);
    }

    function testFuzz_compound_invalidMarketId_reverts(
        bytes32 randomMarketId
    ) public {
        vm.assume(randomMarketId != usdcMarketId);

        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        vm.prank(user);
        usdc.approve(address(compoundAdapter), 1000e6);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        compoundAdapter.deposit(randomMarketId, 1000e6, user);
    }

    function testFuzz_morpho_invalidMarketId_reverts(
        bytes32 randomMarketId
    ) public {
        vm.assume(randomMarketId != morphoMarketId);

        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        vm.prank(user);
        usdc.approve(address(morphoAdapter), 1000e6);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        morphoAdapter.deposit(randomMarketId, 1000e6, user);
    }

    function testFuzz_fluid_invalidMarketId_reverts(
        bytes32 randomMarketId
    ) public {
        vm.assume(randomMarketId != fluidMarketId);

        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        vm.prank(user);
        usdc.approve(address(fluidAdapter), 1000e6);

        vm.prank(user);
        vm.expectRevert(AdapterBase.MarketNotActive.selector);
        fluidAdapter.deposit(randomMarketId, 1000e6, user);
    }

    // ============ Multiple Deposits/Withdraws Sequence Tests ============

    function testFuzz_aave_multipleDepositsWithdraws(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 10);
        address user = makeAddr("user");

        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < numOps; i++) {
            uint256 amount = bound(
                uint256(keccak256(abi.encode(seed, i))),
                1e6,
                10_000e6
            );

            usdc.mint(user, amount);

            vm.prank(user);
            usdc.approve(address(aaveAdapter), amount);

            vm.prank(user);
            aaveAdapter.deposit(usdcMarketId, amount, user);

            totalDeposited += amount;
        }

        assertEq(aUsdc.balanceOf(user), totalDeposited);

        // Withdraw all
        vm.prank(user);
        aUsdc.transfer(address(aaveAdapter), totalDeposited);

        vm.prank(authorizedCaller);
        uint256 withdrawn = aaveAdapter.withdraw(
            usdcMarketId,
            totalDeposited,
            user
        );

        assertEq(withdrawn, totalDeposited);
        assertEq(usdc.balanceOf(user), totalDeposited);
    }

    function testFuzz_morpho_multipleDepositsWithYield(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 5);
        address user = makeAddr("user");

        uint256 totalShares = 0;

        for (uint256 i = 0; i < numOps; i++) {
            uint256 amount = bound(
                uint256(keccak256(abi.encode(seed, i))),
                1e6,
                10_000e6
            );

            usdc.mint(user, amount);

            vm.prank(user);
            usdc.approve(address(morphoAdapter), amount);

            vm.prank(user);
            morphoAdapter.deposit(morphoMarketId, amount, user);

            totalShares = mockMorphoVault.balanceOf(user);

            // Simulate small yield between deposits
            uint256 yieldAmount = amount / 100; // 1% yield
            if (yieldAmount > 0) {
                usdc.mint(user, yieldAmount);
                vm.prank(user);
                usdc.approve(address(mockMorphoVault), yieldAmount);
                vm.prank(user);
                mockMorphoVault.simulateYield(yieldAmount);
            }
        }

        assertTrue(totalShares > 0);

        // Withdraw all shares
        vm.prank(user);
        mockMorphoVault.transfer(address(morphoAdapter), totalShares);

        vm.prank(authorizedCaller);
        uint256 withdrawn = morphoAdapter.withdraw(
            morphoMarketId,
            totalShares,
            user
        );

        // Should receive more than shares due to accumulated yield
        assertTrue(withdrawn >= totalShares);
    }

    // ============ Unauthorized Caller Fuzzing Tests ============

    function testFuzz_aave_unauthorizedWithdraw_reverts(address caller) public {
        vm.assume(caller != authorizedCaller);
        vm.assume(caller != address(0));

        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        vm.prank(user);
        usdc.approve(address(aaveAdapter), 1000e6);

        vm.prank(user);
        aaveAdapter.deposit(usdcMarketId, 1000e6, user);

        vm.prank(user);
        aUsdc.transfer(address(aaveAdapter), 1000e6);

        vm.prank(caller);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        aaveAdapter.withdraw(usdcMarketId, 1000e6, user);
    }

    function testFuzz_compound_unauthorizedWithdraw_reverts(
        address caller
    ) public {
        vm.assume(caller != authorizedCaller);
        vm.assume(caller != address(0));

        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        vm.prank(user);
        usdc.approve(address(compoundAdapter), 1000e6);

        vm.prank(user);
        compoundAdapter.deposit(usdcMarketId, 1000e6, user);

        vm.prank(user);
        mockComet.transfer(address(compoundAdapter), 1000e6);

        vm.prank(caller);
        vm.expectRevert(AdapterBase.UnauthorizedCaller.selector);
        compoundAdapter.withdraw(usdcMarketId, 1000e6, user);
    }

    // ============ Zero Amount Always Reverts ============

    function testFuzz_allAdapters_zeroAmountReverts(address user) public {
        vm.assume(user != address(0));

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        aaveAdapter.deposit(usdcMarketId, 0, user);

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        compoundAdapter.deposit(usdcMarketId, 0, user);

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        morphoAdapter.deposit(morphoMarketId, 0, user);

        vm.prank(user);
        vm.expectRevert(AdapterBase.AmountMustBeGreaterThanZero.selector);
        fluidAdapter.deposit(fluidMarketId, 0, user);
    }

    // ============ Zero Recipient Always Reverts ============

    function testFuzz_allAdapters_zeroRecipientReverts(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        address user = makeAddr("user");
        usdc.mint(user, amount * 5);

        vm.startPrank(user);
        usdc.approve(address(aaveAdapter), amount);
        usdc.approve(address(compoundAdapter), amount);
        usdc.approve(address(morphoAdapter), amount);
        usdc.approve(address(fluidAdapter), amount);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        aaveAdapter.deposit(usdcMarketId, amount, address(0));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        compoundAdapter.deposit(usdcMarketId, amount, address(0));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        morphoAdapter.deposit(morphoMarketId, amount, address(0));

        vm.prank(user);
        vm.expectRevert(AdapterBase.InvalidRecipient.selector);
        fluidAdapter.deposit(fluidMarketId, amount, address(0));
    }
}
