// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwapDepositRouter} from "../../src/SwapDepositRouter.sol";
import {CCTPBridge} from "../../src/CCTPBridge.sol";
import {CCTPReceiver} from "../../src/CCTPReceiver.sol";
import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockTokenMessengerV2E2E {
    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinalityThreshold;
    bytes public lastHookData;

    event DepositForBurnCalled(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;

        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);

        emit DepositForBurnCalled(
            amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold
        );
    }
}

contract MockMessageTransmitterV2E2E {
    MockERC20 public immutable usdc;

    event MessageReceived(bytes message, bytes attestation);

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool) {
        emit MessageReceived(message, attestation);

        bytes calldata body = message[148:];
        uint256 amount;
        assembly {
            amount := calldataload(add(body.offset, 68))
        }

        usdc.mint(msg.sender, amount);
        return true;
    }
}

contract CrossChainBuyE2ETest is Test {
    using CurrencyLibrary for Currency;

    event CCTPBridgeInitiated(
        address indexed sender,
        bytes32 indexed instrumentId,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    event DepositForBurnCalled(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    address internal owner;
    address internal user;

    SwapDepositRouter internal sourceRouter;
    CCTPBridge internal sourceBridge;
    MockTokenMessengerV2E2E internal sourceMessenger;
    MockERC20 internal sourceUsdc;

    SwapDepositRouter internal destinationRouter;
    CCTPReceiver internal destinationReceiver;
    MockMessageTransmitterV2E2E internal destinationMessageTransmitter;
    MockERC20 internal destinationUsdc;
    MockERC20 internal destinationUsdt;
    MockERC20 internal destinationAUsdt;
    bytes32 internal destinationInstrumentId;
    bytes32 internal sourceRemoteInstrumentId;

    uint32 internal constant DESTINATION_CHAIN_ID = 8453;
    uint32 internal constant DESTINATION_DOMAIN = 6;
    uint256 internal constant AMOUNT = 500e6;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        _deployDestinationSide();
        _deploySourceSide();
    }

    function test_e2e_crossChainBuy_standardMode_sourceEvents_and_destinationExecution() public {
        bytes32 destinationCaller = bytes32(uint256(uint160(makeAddr("destinationCaller"))));
        bytes32 mintRecipient = bytes32(uint256(uint160(address(destinationReceiver))));

        vm.prank(user);
        sourceUsdc.approve(address(sourceRouter), AMOUNT);

        vm.expectEmit(false, false, false, true, address(sourceMessenger));
        emit DepositForBurnCalled(
            AMOUNT, DESTINATION_DOMAIN, mintRecipient, address(sourceUsdc), destinationCaller, 0, 2000
        );

        vm.expectEmit(true, true, true, true, address(sourceRouter));
        emit CCTPBridgeInitiated(user, sourceRemoteInstrumentId, AMOUNT, DESTINATION_DOMAIN, mintRecipient, 0, 2000);

        vm.prank(user);
        uint256 sourceResult = sourceRouter.buy(sourceRemoteInstrumentId, AMOUNT, 0, false, 0, 0, address(0));
        assertEq(sourceResult, 0);

        assertEq(sourceMessenger.lastAmount(), AMOUNT);
        assertEq(sourceMessenger.lastDestinationDomain(), DESTINATION_DOMAIN);
        assertEq(sourceMessenger.lastMintRecipient(), mintRecipient);
        assertEq(sourceMessenger.lastBurnToken(), address(sourceUsdc));
        assertEq(sourceMessenger.lastMaxFee(), 0);
        assertEq(sourceMessenger.lastMinFinalityThreshold(), 2000);
        assertEq(sourceUsdc.balanceOf(address(sourceBridge)), 0);
        assertEq(sourceUsdc.balanceOf(address(sourceMessenger)), AMOUNT);

        bytes memory message = _buildCCTPMessageBodyWithHeader(
            address(destinationUsdc),
            address(destinationReceiver),
            AMOUNT,
            bytes32(uint256(uint160(user))),
            abi.encode(destinationInstrumentId, user, uint256(0))
        );

        vm.prank(user);
        bool redeemOk = destinationReceiver.redeem(message, bytes("dummy_attestation"));
        assertTrue(redeemOk);

        assertEq(destinationAUsdt.balanceOf(user), AMOUNT);
        assertEq(destinationUsdc.balanceOf(user), 0);
    }

    function _deploySourceSide() internal {
        sourceUsdc = new MockERC20("USD Coin", "USDC", 6);

        MockPoolManager sourcePM = new MockPoolManager();
        InstrumentRegistry sourceIR = _deployInstrumentRegistry();
        SwapPoolRegistry sourceSPR = _deploySwapPoolRegistry();
        sourceRouter = _deployRouter(sourcePM, sourceIR, sourceSPR, Currency.wrap(address(sourceUsdc)));

        CCTPBridge bridgeImpl = new CCTPBridge();
        ERC1967Proxy bridgeProxy =
            new ERC1967Proxy(address(bridgeImpl), abi.encodeWithSelector(CCTPBridge.initialize.selector, owner));
        sourceBridge = CCTPBridge(address(bridgeProxy));
        sourceMessenger = new MockTokenMessengerV2E2E();

        vm.startPrank(owner);
        sourceBridge.setTokenMessenger(address(sourceMessenger));
        sourceBridge.setDestinationDomain(DESTINATION_CHAIN_ID, DESTINATION_DOMAIN);
        sourceBridge.setDestinationMintRecipient(
            DESTINATION_CHAIN_ID, bytes32(uint256(uint160(address(destinationReceiver))))
        );
        sourceBridge.setDestinationCaller(
            DESTINATION_CHAIN_ID, bytes32(uint256(uint160(makeAddr("destinationCaller"))))
        );
        sourceBridge.setAuthorizedCaller(address(sourceRouter), true);
        sourceRouter.setCCTPBridge(address(sourceBridge));
        vm.stopPrank();

        sourceUsdc.mint(user, AMOUNT);
    }

    function _deployDestinationSide() internal {
        destinationUsdc = new MockERC20("USD Coin", "USDC", 6);
        destinationUsdt = new MockERC20("Tether USD", "USDT", 6);
        destinationAUsdt = new MockERC20("Aave USDT", "aUSDT", 6);

        MockPoolManager destinationPM = new MockPoolManager();

        InstrumentRegistry destinationIR = _deployInstrumentRegistry();
        SwapPoolRegistry destinationSPR = _deploySwapPoolRegistry();

        MockAavePool destinationAavePool = new MockAavePool();
        destinationAavePool.setReserveData(address(destinationUsdt), address(destinationAUsdt));
        destinationUsdt.mint(address(destinationAavePool), 1_000_000e6);

        AaveAdapter destinationAdapter = new AaveAdapter(address(destinationAavePool), owner);
        vm.startPrank(owner);
        destinationAdapter.registerMarket(Currency.wrap(address(destinationUsdt)));
        vm.stopPrank();

        destinationRouter =
            _deployRouter(destinationPM, destinationIR, destinationSPR, Currency.wrap(address(destinationUsdc)));

        CCTPReceiver receiverImpl = new CCTPReceiver();
        destinationMessageTransmitter = new MockMessageTransmitterV2E2E(destinationUsdc);
        ERC1967Proxy receiverProxy = new ERC1967Proxy(
            address(receiverImpl),
            abi.encodeWithSelector(
                CCTPReceiver.initialize.selector,
                owner,
                address(destinationRouter),
                address(destinationUsdc),
                address(destinationMessageTransmitter)
            )
        );
        destinationReceiver = CCTPReceiver(address(receiverProxy));

        vm.prank(owner);
        destinationRouter.setCCTPReceiver(address(destinationReceiver));

        vm.prank(owner);
        destinationAdapter.addAuthorizedCaller(address(destinationRouter));

        bytes32 usdtMarketId = keccak256(abi.encode(Currency.wrap(address(destinationUsdt))));
        address destinationExecutionAddress = makeAddr("destinationExecutionAddress");
        destinationInstrumentId =
            InstrumentIdLib.generateInstrumentId(block.chainid, destinationExecutionAddress, usdtMarketId);
        sourceRemoteInstrumentId =
            InstrumentIdLib.generateInstrumentId(DESTINATION_CHAIN_ID, destinationExecutionAddress, usdtMarketId);

        vm.prank(owner);
        destinationIR.registerInstrument(destinationExecutionAddress, usdtMarketId, address(destinationAdapter));

        (Currency currency0, Currency currency1) =
            _orderCurrencies(Currency.wrap(address(destinationUsdc)), Currency.wrap(address(destinationUsdt)));
        PoolKey memory swapPool =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});

        vm.startPrank(owner);
        destinationSPR.registerDefaultSwapPool(
            Currency.wrap(address(destinationUsdc)), Currency.wrap(address(destinationUsdt)), swapPool
        );
        destinationSPR.registerDefaultSwapPool(
            Currency.wrap(address(destinationUsdt)), Currency.wrap(address(destinationUsdc)), swapPool
        );
        vm.stopPrank();

        destinationUsdt.mint(address(destinationPM), 1_000_000e6);
        destinationUsdc.mint(address(destinationPM), 1_000_000e6);
    }

    function _deployRouter(MockPoolManager pm, InstrumentRegistry ir, SwapPoolRegistry spr, Currency stable)
        internal
        returns (SwapDepositRouter router)
    {
        SwapDepositRouter impl = new SwapDepositRouter();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                SwapDepositRouter.initialize.selector, owner, IPoolManager(address(pm)), ir, spr, stable
            )
        );
        router = SwapDepositRouter(address(proxy));
    }

    function _deployInstrumentRegistry() internal returns (InstrumentRegistry registry) {
        InstrumentRegistry impl = new InstrumentRegistry();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner));
        registry = InstrumentRegistry(address(proxy));
    }

    function _deploySwapPoolRegistry() internal returns (SwapPoolRegistry registry) {
        SwapPoolRegistry impl = new SwapPoolRegistry();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner));
        registry = SwapPoolRegistry(address(proxy));
    }

    function _orderCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    function _buildCCTPMessageBodyWithHeader(
        address burnToken,
        address mintRecipient,
        uint256 amount,
        bytes32 sender,
        bytes memory hookData
    ) internal pure returns (bytes memory message) {
        bytes memory body = abi.encodePacked(
            uint32(1),
            bytes32(uint256(uint160(burnToken))),
            bytes32(uint256(uint160(mintRecipient))),
            bytes32(amount),
            sender,
            bytes32(uint256(0)),
            bytes32(uint256(0)),
            bytes32(uint256(0)),
            hookData
        );
        message = abi.encodePacked(new bytes(148), body);
    }
}
