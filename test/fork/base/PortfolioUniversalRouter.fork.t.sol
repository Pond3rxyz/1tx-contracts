// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
import {IUniversalRouter} from "../../../src/interfaces/IUniversalRouter.sol";
import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {PortfolioStrategy} from "../../../src/hooks/PortfolioStrategy.sol";
import {IPortfolioStrategy} from "../../../src/interfaces/IPortfolioStrategy.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";

/// @title PortfolioUniversalRouterForkTest
/// @notice Fork tests for PortfolioHook swaps via the on-chain Universal Router
/// @dev Validates that the real Universal Router at 0x6fF5... can execute V4 swaps
///      through the PortfolioHook using the execute(commands, inputs, deadline) interface.
contract PortfolioUniversalRouterForkTest is Test {
    using stdJson for string;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";

    /// @dev Universal Router command byte for V4 swaps
    uint8 internal constant V4_SWAP = 0x10;

    // Infrastructure
    IPermit2 public permit2;
    IPoolManager public poolManager;
    IUniversalRouter public universalRouter;

    // Portfolio contracts
    PortfolioHook public hook;
    PortfolioVault public vault;
    PortfolioStrategy public strategy;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;

    // Tokens / Pool
    address public usdc;
    Currency public usdcCurrency;
    PoolKey public portfolioPoolKey;
    PoolId public portfolioPoolId;

    // Addresses
    address public owner;
    address public user;
    address public executionAddress;

    uint256 public constant DEPOSIT_AMOUNT = 1000e6;
    bool internal forkActive;

    bytes32 public usdcInstrumentId;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        forkActive = true;
        vm.createSelectFork(rpcUrl);

        string memory json = vm.readFile(CONFIG_PATH);
        string memory networkPath = ".networks.baseMainnet";

        owner = makeAddr("owner");
        user = makeAddr("user");
        executionAddress = makeAddr("portfolioExec");

        vm.deal(owner, 100 ether);
        vm.deal(user, 100 ether);

        usdc = json.readAddress(string.concat(networkPath, ".tokens.USDC"));
        usdcCurrency = Currency.wrap(usdc);

        // Load real on-chain infrastructure
        string memory v4Path = string.concat(networkPath, ".uniswapV4");
        permit2 = IPermit2(json.readAddress(string.concat(v4Path, ".permit2")));
        poolManager = IPoolManager(json.readAddress(string.concat(v4Path, ".poolManager")));
        universalRouter = IUniversalRouter(json.readAddress(string.concat(v4Path, ".swapRouter")));

        console2.log("Universal Router:", address(universalRouter));
        console2.log("Pool Manager:", address(poolManager));

        _deployPortfolio(json, networkPath);
    }

    function _deployPortfolio(string memory json, string memory networkPath) internal {
        // Deploy registries
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(
                    address(new InstrumentRegistry()),
                    abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner)
                )
            )
        );
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(
                    address(new SwapPoolRegistry()),
                    abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner)
                )
            )
        );

        // Deploy Aave adapter + register instrument
        address aavePool = json.readAddress(string.concat(networkPath, ".protocols.aave.pool"));
        aaveAdapter = new AaveAdapter(aavePool, owner);
        vm.startPrank(owner);
        aaveAdapter.registerMarket(usdcCurrency);
        bytes32 usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));
        vm.stopPrank();

        // Deploy strategy
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, owner)
                )
            )
        );
        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(strategy));

        // Deploy vault
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 10000});

        vault = new PortfolioVault(
            PortfolioVault.InitParams({
                initialOwner: owner,
                name: "UR Test Portfolio",
                symbol: "urPORT",
                stable: usdcCurrency,
                poolManager: poolManager,
                instrumentRegistry: instrumentRegistry,
                swapPoolRegistry: swapPoolRegistry,
                strategy: IPortfolioStrategy(address(strategy)),
                allocations: allocs
            })
        );

        // Deploy hook at address with correct flag bits
        address hookAddress = address(uint160(0x1000000000000000000000000000000000000aC8));
        deployCodeTo("PortfolioHook.sol:PortfolioHook", abi.encode(poolManager, vault, usdcCurrency), hookAddress);
        hook = PortfolioHook(hookAddress);

        vm.prank(owner);
        vault.setHook(address(hook));

        // Initialize pool
        (Currency c0, Currency c1) = Currency.unwrap(usdcCurrency) < address(vault)
            ? (usdcCurrency, Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), usdcCurrency);

        portfolioPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddress)});
        portfolioPoolId = portfolioPoolKey.toId();

        poolManager.initialize(portfolioPoolKey, Constants.SQRT_PRICE_1_1);
    }

    modifier onlyFork() {
        if (!forkActive) return;
        _;
    }

    // ============ Helpers ============

    function _buyZeroForOne() internal view returns (bool) {
        return Currency.unwrap(portfolioPoolKey.currency0) == Currency.unwrap(usdcCurrency);
    }

    function _inputCurrency() internal view returns (Currency) {
        return _buyZeroForOne() ? portfolioPoolKey.currency0 : portfolioPoolKey.currency1;
    }

    function _outputCurrency() internal view returns (Currency) {
        return _buyZeroForOne() ? portfolioPoolKey.currency1 : portfolioPoolKey.currency0;
    }

    function _setupUserApprovals(address u) internal {
        vm.startPrank(u);
        // ERC20 approve USDC → Permit2
        IERC20(usdc).approve(address(permit2), type(uint256).max);
        // Permit2 allowance → Universal Router
        permit2.approve(usdc, address(universalRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _setupSellApprovals(address u) internal {
        vm.startPrank(u);
        IERC20(address(vault)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(vault), address(universalRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice Encode a V4 exact-input single swap as Universal Router execute calldata
    function _encodeBuyViaUR(uint256 amount, address recipient)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // V4 actions: SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE_ALL
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), // 0x06
            uint8(Actions.SETTLE_ALL), // 0x0c
            uint8(Actions.TAKE_ALL) // 0x0f
        );

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: portfolioPoolKey,
                zeroForOne: _buyZeroForOne(),
                amountIn: uint128(amount),
                amountOutMinimum: 0,
                hookData: abi.encode(recipient)
            })
        );
        actionParams[1] = abi.encode(_inputCurrency(), type(uint256).max);
        actionParams[2] = abi.encode(_outputCurrency(), uint256(0));

        commands = abi.encodePacked(uint8(V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);
    }

    /// @notice Encode a V4 exact-input single sell as Universal Router execute calldata
    function _encodeSellViaUR(uint256 shareAmount, address recipient)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        // Sell = opposite direction from buy
        bool zeroForOne = !_buyZeroForOne();
        Currency inputCur = zeroForOne ? portfolioPoolKey.currency0 : portfolioPoolKey.currency1;
        Currency outputCur = zeroForOne ? portfolioPoolKey.currency1 : portfolioPoolKey.currency0;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: portfolioPoolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(shareAmount),
                amountOutMinimum: 0,
                hookData: abi.encode(recipient)
            })
        );
        actionParams[1] = abi.encode(inputCur, type(uint256).max);
        actionParams[2] = abi.encode(outputCur, uint256(0));

        commands = abi.encodePacked(uint8(V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);
    }

    function _buyShares(uint256 amount, address recipient) internal returns (uint256 shares) {
        uint256 sharesBefore = vault.balanceOf(recipient);

        (bytes memory commands, bytes[] memory inputs) = _encodeBuyViaUR(amount, recipient);

        vm.prank(recipient);
        universalRouter.execute(commands, inputs, block.timestamp + 1);

        shares = vault.balanceOf(recipient) - sharesBefore;
    }

    function _sellShares(uint256 shareAmount, address shareOwner) internal returns (uint256 usdcReturned) {
        _setupSellApprovals(shareOwner);

        uint256 usdcBefore = IERC20(usdc).balanceOf(shareOwner);

        (bytes memory commands, bytes[] memory inputs) = _encodeSellViaUR(shareAmount, shareOwner);

        vm.prank(shareOwner);
        universalRouter.execute(commands, inputs, block.timestamp + 1);

        usdcReturned = IERC20(usdc).balanceOf(shareOwner) - usdcBefore;
    }

    // ============ Tests ============

    function test_fork_ur_buy_1USDC() public onlyFork {
        uint256 amount = 1e6;
        deal(usdc, user, amount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(amount, user);

        console2.log("Shares received:", shares);
        console2.log("Vault NAV:", vault.totalAssets());

        assertGt(shares, 0, "should mint shares via Universal Router");
        assertGt(vault.totalAssets(), 0, "NAV should be positive");
    }

    function test_fork_ur_buy_1000USDC() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);

        assertGt(shares, 0, "should mint shares");
        assertApproxEqRel(vault.totalAssets(), DEPOSIT_AMOUNT, 1e16, "NAV should match deposit");
    }

    function test_fork_ur_buySell_roundtrip() public onlyFork {
        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 returned = _sellShares(shares, user);

        console2.log("Deposited:", DEPOSIT_AMOUNT);
        console2.log("Returned:", returned);

        assertGe(returned, DEPOSIT_AMOUNT - 3, "roundtrip should preserve value within 3 wei");
    }

    function test_fork_ur_multiUser() public onlyFork {
        address user2 = makeAddr("user2");
        vm.deal(user2, 100 ether);

        deal(usdc, user, DEPOSIT_AMOUNT);
        deal(usdc, user2, DEPOSIT_AMOUNT * 2);
        _setupUserApprovals(user);
        _setupUserApprovals(user2);

        uint256 shares1 = _buyShares(DEPOSIT_AMOUNT, user);
        uint256 shares2 = _buyShares(DEPOSIT_AMOUNT * 2, user2);

        assertGt(shares1, 0);
        assertGt(shares2, 0);
        assertApproxEqRel(shares2, shares1 * 2, 1e16, "double deposit should give ~double shares");

        uint256 returned1 = _sellShares(shares1, user);
        uint256 returned2 = _sellShares(shares2, user2);

        assertGe(returned1, DEPOSIT_AMOUNT - 3, "user1 should recover deposit");
        assertGe(returned2, DEPOSIT_AMOUNT * 2 - 5, "user2 should recover deposit");
    }

    function test_fork_ur_sqrtPrice_stays_static() public onlyFork {
        (uint160 priceBefore,,,) = poolManager.getSlot0(portfolioPoolId);

        deal(usdc, user, DEPOSIT_AMOUNT);
        _setupUserApprovals(user);
        _buyShares(DEPOSIT_AMOUNT, user);

        (uint160 priceAfter,,,) = poolManager.getSlot0(portfolioPoolId);
        assertEq(priceBefore, priceAfter, "price should stay static (hook bypasses AMM)");
    }

    function test_fork_ur_large_100k() public onlyFork {
        uint256 largeAmount = 100_000e6;
        deal(usdc, user, largeAmount);
        _setupUserApprovals(user);

        uint256 shares = _buyShares(largeAmount, user);
        assertGt(shares, 0, "100k buy should work via UR");

        uint256 returned = _sellShares(shares, user);
        assertGe(returned, largeAmount * 9999 / 10000, "100k roundtrip near lossless");
    }
}
