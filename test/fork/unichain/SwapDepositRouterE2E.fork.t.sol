// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {SwapDepositRouter} from "../../../src/SwapDepositRouter.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {ILendingAdapter} from "../../../src/interfaces/ILendingAdapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";

/// @title SwapDepositRouterE2EUnichainForkTest
/// @notice E2E fork tests for SwapDepositRouter on Unichain mainnet
contract SwapDepositRouterE2EUnichainForkTest is AdapterForkTestBase {
    using stdJson for string;

    SwapDepositRouter public router;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    IPoolManager public poolManager;

    address public usdc;
    Currency public usdcCurrency;
    address public morphoExecAddr;
    address public eulerExecAddr;

    MorphoAdapter public morphoAdapter;
    EulerAdapter public eulerAdapter;

    struct Instrument {
        bytes32 id;
        string name;
        address adapter;
        bytes32 marketId;
    }

    Instrument[] public instruments;

    function setUp() public override {
        networkName = "unichainMainnet";
        super.setUp();

        morphoExecAddr = makeAddr("morphoExec");
        eulerExecAddr = makeAddr("eulerExec");
        usdc = getToken("USDC");
        if (usdc == address(0)) return;
        usdcCurrency = Currency.wrap(usdc);

        poolManager = IPoolManager(json.readAddress(string.concat(networkPath, ".uniswapV4.poolManager")));

        _deployInfrastructure();
        _setupMorpho();
        _setupEuler();
    }

    function _deployInfrastructure() internal {
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(
                    address(new InstrumentRegistry()),
                    abi.encodeWithSelector(InstrumentRegistry.initialize.selector, address(this))
                )
            )
        );
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(
                    address(new SwapPoolRegistry()),
                    abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, address(this))
                )
            )
        );
        router = SwapDepositRouter(
            address(
                new ERC1967Proxy(
                    address(new SwapDepositRouter()),
                    abi.encodeWithSelector(
                        SwapDepositRouter.initialize.selector,
                        address(this),
                        poolManager,
                        instrumentRegistry,
                        swapPoolRegistry,
                        usdcCurrency
                    )
                )
            )
        );
    }

    function _setupMorpho() internal {
        morphoAdapter = new MorphoAdapter(address(this));
        morphoAdapter.addAuthorizedCaller(address(router));

        _tryRegisterMorphoVault("Morpho-gauntletUSDCC", "gauntletUSDCC");
    }

    function _tryRegisterMorphoVault(string memory name, string memory vaultName) internal {
        address vault = getMorphoVault(vaultName);
        if (vault == address(0)) return;

        Currency currency = Currency.wrap(usdc);
        try morphoAdapter.registerVault(currency, vault) {
            _registerInstrument(name, address(morphoAdapter), _computeVaultMarketId(vault), morphoExecAddr);
        } catch {}
    }

    function _setupEuler() internal {
        eulerAdapter = new EulerAdapter(address(this));
        eulerAdapter.addAuthorizedCaller(address(router));

        address vault = getEulerVault("eeUSDC");
        if (vault == address(0)) return;

        Currency currency = Currency.wrap(usdc);
        try eulerAdapter.registerVault(currency, vault) {
            _registerInstrument("Euler-eeUSDC", address(eulerAdapter), _computeVaultMarketId(vault), eulerExecAddr);
        } catch {}
    }

    // ============ Registration Helpers ============

    function _registerInstrument(string memory name, address adapter, bytes32 marketId, address execAddr) internal {
        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, execAddr, marketId);
        instrumentRegistry.registerInstrument(execAddr, marketId, adapter);
        instruments.push(Instrument({id: instrumentId, name: name, adapter: adapter, marketId: marketId}));
    }

    // ============ E2E Tests ============

    function test_fork_unichain_e2e_buyAll() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            _testBuy(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one instrument");
    }

    function test_fork_unichain_e2e_roundtripAll() public {
        uint256 tested = 0;
        for (uint256 i = 0; i < instruments.length; i++) {
            _testRoundtrip(instruments[i], DEPOSIT_AMOUNT);
            tested++;
        }
        assertGt(tested, 0, "Should test at least one roundtrip");
    }

    function test_fork_unichain_e2e_multipleUsers() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _dealTokens(usdc, alice, 500e6);
        _approveTokens(usdc, alice, address(router), 500e6);
        vm.prank(alice);
        router.buy(inst.id, 500e6, 0, false, 0);

        _dealTokens(usdc, bob, 1500e6);
        _approveTokens(usdc, bob, address(router), 1500e6);
        vm.prank(bob);
        router.buy(inst.id, 1500e6, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        assertGt(_getBalance(yieldToken, alice), 0, "Alice should have yield tokens");
        assertGt(_getBalance(yieldToken, bob), 0, "Bob should have yield tokens");
    }

    function test_fork_unichain_e2e_noTokensLeftInRouter() public {
        if (instruments.length == 0) return;
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        assertEq(_getBalance(usdc, address(router)), 0, "Router should not hold USDC");

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, user);
        _approveTokens(yieldToken, user, address(router), yieldBalance);
        vm.prank(user);
        router.sell(inst.id, yieldBalance, 0);

        assertEq(_getBalance(usdc, address(router)), 0, "Router should not hold USDC after sell");
    }

    function test_fork_unichain_e2e_buy_exactSlippage_passes() public {
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        uint256 deposited = router.buy(inst.id, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, false, 0);
        assertEq(deposited, DEPOSIT_AMOUNT, "No-swap deposit should equal input exactly");
    }

    function test_fork_unichain_e2e_buy_tightSlippage_reverts() public {
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert();
        router.buy(inst.id, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1, false, 0);
    }

    function test_fork_unichain_e2e_sell_tightSlippage_reverts() public {
        Instrument memory inst = instruments[0];

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(router), DEPOSIT_AMOUNT);
        vm.prank(user);
        router.buy(inst.id, DEPOSIT_AMOUNT, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, user);
        _approveTokens(yieldToken, user, address(router), yieldBalance);

        vm.prank(user);
        vm.expectRevert();
        router.sell(inst.id, yieldBalance, DEPOSIT_AMOUNT * 2);
    }

    // ============ Internal Helpers ============

    function _testBuy(Instrument memory inst, uint256 amount) internal {
        address testUser = makeAddr(string.concat("buyer-", inst.name));
        vm.deal(testUser, 1 ether);

        _dealTokens(usdc, testUser, amount);
        _approveTokens(usdc, testUser, address(router), amount);

        vm.prank(testUser);
        uint256 deposited = router.buy(inst.id, amount, 0, false, 0);

        assertEq(deposited, amount, string.concat("No-swap deposit should equal input for ", inst.name));

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        assertGt(_getBalance(yieldToken, testUser), 0, string.concat("No yield tokens for ", inst.name));
    }

    function _testRoundtrip(Instrument memory inst, uint256 amount) internal {
        address testUser = makeAddr(string.concat("rt-", inst.name));
        vm.deal(testUser, 1 ether);

        _dealTokens(usdc, testUser, amount);
        _approveTokens(usdc, testUser, address(router), amount);
        vm.prank(testUser);
        router.buy(inst.id, amount, 0, false, 0);

        address yieldToken = ILendingAdapter(inst.adapter).getYieldToken(inst.marketId);
        uint256 yieldBalance = _getBalance(yieldToken, testUser);
        _approveTokens(yieldToken, testUser, address(router), yieldBalance);
        vm.prank(testUser);
        uint256 output = router.sell(inst.id, yieldBalance, 0);

        assertGt(output, 0, string.concat("Sell returned 0 for ", inst.name));
        assertGe(output, amount - 2, string.concat("Value loss for ", inst.name));
    }
}
