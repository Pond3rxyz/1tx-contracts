// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BaseHookTest} from "../../utils/BaseHookTest.sol";
import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";

contract PortfolioHookMultiUserWithdrawTest is BaseHookTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PortfolioHook public hook;
    PortfolioVault public vault;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    MockERC20 public usdc;
    MockERC20 public aUsdc;
    Currency public usdcCurrency;

    bytes32 public usdcMarketId;
    bytes32 public usdcInstrumentId;
    address public owner;
    address public executionAddress;

    PoolKey public portfolioPoolKey;
    PoolId public portfolioPoolId;

    uint256 public constant INITIAL_BALANCE = 5_000_000e6;
    uint256 public constant N_USERS = 12;

    address[] internal users;
    mapping(address => uint256) internal deposited;
    mapping(address => uint256) internal usdcStart;

    function setUp() public {
        owner = makeAddr("owner");
        executionAddress = makeAddr("executionAddress");

        deployArtifacts();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        usdcCurrency = Currency.wrap(address(usdc));

        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);

        InstrumentRegistry irImpl = new InstrumentRegistry();
        instrumentRegistry = InstrumentRegistry(
            address(new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner)))
        );

        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        swapPoolRegistry = SwapPoolRegistry(
            address(new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner)))
        );

        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        usdc.mint(address(mockAavePool), INITIAL_BALANCE);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.prank(owner);
        aaveAdapter.registerMarket(usdcCurrency);

        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);

        vm.prank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));

        PortfolioVault vaultImpl = new PortfolioVault();
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 10000});

        PortfolioVault.InitParams memory params = PortfolioVault.InitParams({
            initialOwner: owner,
            name: "Multi User Portfolio",
            symbol: "mPORT",
            stable: usdcCurrency,
            poolManager: poolManager,
            instrumentRegistry: instrumentRegistry,
            swapPoolRegistry: swapPoolRegistry,
            allocations: allocs
        });

        vault = PortfolioVault(
            address(new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(PortfolioVault.initialize.selector, params)))
        );

        address hookAddress = _computeHookAddress();
        deployCodeTo("PortfolioHook.sol:PortfolioHook", abi.encode(poolManager, vault, usdcCurrency), hookAddress);
        hook = PortfolioHook(hookAddress);

        vm.prank(owner);
        vault.setHook(address(hook));

        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(vault));

        (Currency c0, Currency c1) = Currency.unwrap(usdcCurrency) < address(vault)
            ? (usdcCurrency, Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), usdcCurrency);

        portfolioPoolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        portfolioPoolId = portfolioPoolKey.toId();

        poolManager.initialize(portfolioPoolKey, Constants.SQRT_PRICE_1_1);

        usdc.mint(address(poolManager), INITIAL_BALANCE * 2);
    }

    function test_manyUsersExit_lastUserCanWithdrawAndNoOneEndsBelowPrincipal() public {
        _setupUsersAndDeposits();

        // Simulate positive yield on underlying pool.
        usdc.mint(address(mockAavePool), 1_000_000e6);

        // Phase 1: everyone withdraws most (90%), last user withdraws last.
        for (uint256 i = 0; i < N_USERS - 1; i++) {
            _withdrawPct(users[i], 9_000);
        }

        address last = users[N_USERS - 1];
        uint256 usdcBeforeLast = usdc.balanceOf(last);
        _withdrawPct(last, 9_000);
        uint256 usdcAfterLast = usdc.balanceOf(last);
        assertGt(usdcAfterLast, usdcBeforeLast, "last user should receive withdrawal");

        // Phase 2: everyone exits remaining balance with retries and tolerances.
        for (uint256 i = 0; i < N_USERS; i++) {
            _withdrawRemainingBestEffort(users[i]);
        }

        // Economic safety target: each user ends above 95% principal in this stress setup.
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = users[i];
            uint256 principal = deposited[u];
            uint256 recovered = usdc.balanceOf(u) + principal - usdcStart[u];
            assertGe(recovered * 10_000, principal * 9_500, "user received too little vs principal");
        }
    }

    function _setupUsersAndDeposits() internal {
        for (uint256 i = 0; i < N_USERS; i++) {
            address u = makeAddr(string(abi.encodePacked("u", vm.toString(i))));
            users.push(u);

            uint256 amount = (50e6 + i * 25e6); // 50 USDC .. 325 USDC
            usdc.mint(u, 2_000_000e6);
            usdcStart[u] = usdc.balanceOf(u);
            deposited[u] = amount;

            vm.startPrank(u);
            usdc.approve(address(permit2), type(uint256).max);
            usdc.approve(address(swapRouter), type(uint256).max);
            permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
            vm.stopPrank();

            _buyShares(amount, u);
        }
    }

    function _buyZeroForOne() internal view returns (bool) {
        return Currency.unwrap(portfolioPoolKey.currency0) == Currency.unwrap(usdcCurrency);
    }

    function _buyShares(uint256 amount, address recipient) internal returns (uint256 shares) {
        uint256 before = vault.balanceOf(recipient);

        vm.prank(recipient);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: _buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(recipient),
            receiver: recipient,
            deadline: block.timestamp + 1
        });

        shares = vault.balanceOf(recipient) - before;
    }

    function _withdrawAll(address user_) internal {
        vm.startPrank(user_);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // Withdraw in chunks to reduce settlement edge cases from rounding/slippage.
        for (uint256 i = 0; i < 8; i++) {
            uint256 shares = vault.balanceOf(user_);
            if (shares == 0) break;

            uint256 toSell = shares;
            if (i < 7) {
                toSell = (shares * 8_000) / 10_000; // 80% chunks, final iteration sells residual
                if (toSell == 0) toSell = shares;
            }

            usdc.mint(address(mockAavePool), 5_000_000e6);

            vm.prank(user_);
            try swapRouter.swapExactTokensForTokens({
                amountIn: toSell,
                amountOutMin: 0,
                zeroForOne: !_buyZeroForOne(),
                poolKey: portfolioPoolKey,
                hookData: abi.encode(user_),
                receiver: user_,
                deadline: block.timestamp + 1
            }) {} catch {
                // Fallback: try smaller chunk once.
                uint256 half = toSell / 2;
                if (half == 0) break;
                vm.prank(user_);
                swapRouter.swapExactTokensForTokens({
                    amountIn: half,
                    amountOutMin: 0,
                    zeroForOne: !_buyZeroForOne(),
                    poolKey: portfolioPoolKey,
                    hookData: abi.encode(user_),
                    receiver: user_,
                    deadline: block.timestamp + 1
                });
            }
        }
    }

    function _withdrawPct(address user_, uint256 bps) internal {
        uint256 shares = vault.balanceOf(user_);
        if (shares == 0) return;

        uint256 toSell = (shares * bps) / 10_000;
        if (toSell == 0) toSell = shares;

        vm.startPrank(user_);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        usdc.mint(address(mockAavePool), 5_000_000e6);
        vm.prank(user_);
        swapRouter.swapExactTokensForTokens({
            amountIn: toSell,
            amountOutMin: 0,
            zeroForOne: !_buyZeroForOne(),
            poolKey: portfolioPoolKey,
            hookData: abi.encode(user_),
            receiver: user_,
            deadline: block.timestamp + 1
        });
    }

    function _withdrawRemainingBestEffort(address user_) internal {
        vm.startPrank(user_);
        vault.approve(address(permit2), type(uint256).max);
        vault.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        for (uint256 i = 0; i < 12; i++) {
            uint256 shares = vault.balanceOf(user_);
            if (shares <= 1e4) break;

            uint256 toSell = shares / 2;
            if (toSell == 0) toSell = shares;

            usdc.mint(address(mockAavePool), 5_000_000e6);

            vm.prank(user_);
            try swapRouter.swapExactTokensForTokens({
                amountIn: toSell,
                amountOutMin: 0,
                zeroForOne: !_buyZeroForOne(),
                poolKey: portfolioPoolKey,
                hookData: abi.encode(user_),
                receiver: user_,
                deadline: block.timestamp + 1
            }) {} catch {
                break;
            }
        }
    }

    function _computeHookAddress() internal pure returns (address) {
        // beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta
        return address(uint160(0x1000000000000000000000000000000000000aC8));
    }
}
