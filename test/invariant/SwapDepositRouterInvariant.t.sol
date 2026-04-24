// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SwapDepositRouter} from "../../src/SwapDepositRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../src/registries/SwapPoolRegistry.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {CCTPBridge} from "../../src/CCTPBridge.sol";
import {InstrumentIdLib} from "../../src/libraries/InstrumentIdLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

contract SwapDepositRouterHandler is Test {
    SwapDepositRouter public router;
    MockERC20 public usdc;
    MockERC20 public aUsdc;
    bytes32 public usdcInstrumentId;
    address public user;
    address public feeRecipient;
    address public referralWallet;

    uint256 public totalGrossAmount;
    uint256 public totalProtocolFees;
    uint256 public totalReferralFees;

    constructor(
        SwapDepositRouter _router,
        MockERC20 _usdc,
        MockERC20 _aUsdc,
        bytes32 _usdcInstrumentId,
        address _feeRecipient
    ) {
        router = _router;
        usdc = _usdc;
        aUsdc = _aUsdc;
        usdcInstrumentId = _usdcInstrumentId;
        feeRecipient = _feeRecipient;
        user = makeAddr("invariantUser");
        referralWallet = makeAddr("referralWallet");

        usdc.mint(user, type(uint128).max);
        aUsdc.mint(user, type(uint128).max);

        vm.prank(user);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(user);
        aUsdc.approve(address(router), type(uint256).max);
    }

    function buyWithRef(uint256 amount, uint16 referralFeeBps) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        referralFeeBps = uint16(bound(referralFeeBps, 0, 500)); // MAX_REFERRAL_FEE_BPS

        uint16 protocolFeeBps = router.protocolFeeBps();
        if (protocolFeeBps + referralFeeBps > 1000) return; // Skip invalid configs

        totalGrossAmount += amount;

        uint256 expectedProtocolFee = (amount * protocolFeeBps) / 10_000;
        uint256 expectedReferralFee = (amount * referralFeeBps) / 10_000;

        totalProtocolFees += expectedProtocolFee;
        totalReferralFees += expectedReferralFee;

        vm.prank(user);
        router.buy(usdcInstrumentId, amount, 0, false, 0, referralFeeBps, referralWallet);
    }

    function sellWithRef(uint256 yieldAmount, uint16 referralFeeBps) public {
        yieldAmount = bound(yieldAmount, 1e6, 1_000_000e6);
        referralFeeBps = uint16(bound(referralFeeBps, 0, 500));

        // Ensure user has enough aTokens
        if (aUsdc.balanceOf(user) < yieldAmount) return;

        uint16 protocolFeeBps = router.protocolFeeBps();
        if (protocolFeeBps + referralFeeBps > 1000) return;

        // Gross output is same as yieldAmount in our mock with no swap/rate changes
        uint256 grossOutputAmount = yieldAmount;
        totalGrossAmount += grossOutputAmount;

        uint256 expectedProtocolFee = (grossOutputAmount * protocolFeeBps) / 10_000;
        uint256 expectedReferralFee = (grossOutputAmount * referralFeeBps) / 10_000;

        totalProtocolFees += expectedProtocolFee;
        totalReferralFees += expectedReferralFee;

        vm.prank(user);
        router.sell(usdcInstrumentId, yieldAmount, 0, referralFeeBps, referralWallet);
    }
}

contract SwapDepositRouterInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;

    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    MockPoolManager public mockPM;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    MockERC20 public usdc;
    MockERC20 public aUsdc;
    Currency public usdcCurrency;

    bytes32 public usdcInstrumentId;
    address public owner;
    address public feeRecipient;

    SwapDepositRouterHandler public handler;

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        usdcCurrency = Currency.wrap(address(usdc));

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
        usdc.mint(address(mockAavePool), 10_000_000e6); // Initial liquidity

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.prank(owner);
        aaveAdapter.registerMarket(usdcCurrency);

        SwapDepositRouter routerImpl = new SwapDepositRouter();
        router = SwapDepositRouter(
            address(
                new ERC1967Proxy(
                    address(routerImpl),
                    abi.encodeWithSelector(
                        SwapDepositRouter.initialize.selector,
                        owner,
                        mockPM,
                        instrumentRegistry,
                        swapPoolRegistry,
                        usdcCurrency
                    )
                )
            )
        );

        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(router));

        bytes32 usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdcInstrumentId =
            InstrumentIdLib.generateInstrumentId(block.chainid, makeAddr("executionAddress"), usdcMarketId);

        vm.prank(owner);
        instrumentRegistry.registerInstrument(makeAddr("executionAddress"), usdcMarketId, address(aaveAdapter));

        vm.prank(owner);
        router.setFeeConfig(100, feeRecipient); // 1%

        handler = new SwapDepositRouterHandler(router, usdc, aUsdc, usdcInstrumentId, feeRecipient);

        targetContract(address(handler));
    }

    function invariant_noStableDustInRouter() public {
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds USDC dust");
        assertEq(aUsdc.balanceOf(address(router)), 0, "Router holds aUSDC dust");
    }

    function invariant_feeAccountingExact() public {
        assertEq(usdc.balanceOf(feeRecipient), handler.totalProtocolFees(), "Protocol fee mismatch");
        assertEq(usdc.balanceOf(handler.referralWallet()), handler.totalReferralFees(), "Referral fee mismatch");
    }

    function invariant_feesNotExceedingMax() public {
        uint256 combinedFees = usdc.balanceOf(feeRecipient) + usdc.balanceOf(handler.referralWallet());
        // Max fee is 10% combined (1000 bps)
        assertTrue(combinedFees <= (handler.totalGrossAmount() * 1000) / 10000, "Combined fees exceeded max allowed");
    }
}
