// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {InstrumentRegistry} from "./registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "./registries/SwapPoolRegistry.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {ICCTPBridge} from "./interfaces/ICCTPBridge.sol";
import {InstrumentIdLib} from "./libraries/InstrumentIdLib.sol";
import {SwapExecutor} from "./libraries/SwapExecutor.sol";
import {LendingExecutor} from "./libraries/LendingExecutor.sol";

/// @title SwapDepositRouter
/// @notice Router for buying/selling lending protocol instruments with automatic token swapping
/// @dev Uses Uniswap V4 PoolManager for swaps and lending adapters via InstrumentRegistry for deposits/withdrawals.
///      Always operates in the configured stable currency (e.g. USDC). Yield tokens go to / come from msg.sender.
contract SwapDepositRouter is Initializable, UUPSUpgradeable, OwnableUpgradeable, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // ============ State ============

    IPoolManager public poolManager;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    Currency public stable;
    address public cctpBridge;
    address public cctpReceiver;

    // ============ Errors ============

    error CallerNotPoolManager();
    error InvalidAmount();
    error InvalidAddress();
    error InvalidPoolManager();
    error InvalidRegistry();
    error InvalidStable();
    error CrossChainBridgeNotConfigured();
    error CrossChainSellNotSupported();
    error UnauthorizedBuyForCaller();
    error InsufficientOutput(uint256 actual, uint256 minimum);
    error ChainIdOverflow();

    // ============ Events ============

    event Buy(bytes32 indexed instrumentId, address indexed recipient, uint256 inputAmount, uint256 depositedAmount);
    event Sell(bytes32 indexed instrumentId, address indexed recipient, uint256 yieldTokenAmount, uint256 outputAmount);
    event CCTPBridgeUpdated(address indexed cctpBridge);
    event CCTPReceiverUpdated(address indexed cctpReceiver);
    event CCTPBridgeInitiated(
        address indexed sender,
        bytes32 indexed instrumentId,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    // ============ Types ============

    struct SwapCallbackData {
        PoolKey swapPool;
        Currency inputCurrency;
        Currency outputCurrency;
        uint256 inputAmount;
    }

    // ============ Constructor / Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        IPoolManager _poolManager,
        InstrumentRegistry _instrumentRegistry,
        SwapPoolRegistry _swapPoolRegistry,
        Currency _stable
    ) external initializer {
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        if (address(_instrumentRegistry) == address(0)) revert InvalidRegistry();
        if (address(_swapPoolRegistry) == address(0)) revert InvalidRegistry();
        if (Currency.unwrap(_stable) == address(0)) revert InvalidStable();

        __Ownable_init(initialOwner);
        poolManager = _poolManager;
        instrumentRegistry = _instrumentRegistry;
        swapPoolRegistry = _swapPoolRegistry;
        stable = _stable;
    }

    // ============ Admin Functions ============

    function setPoolManager(IPoolManager _poolManager) external onlyOwner {
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        poolManager = _poolManager;
    }

    function setInstrumentRegistry(InstrumentRegistry _instrumentRegistry) external onlyOwner {
        if (address(_instrumentRegistry) == address(0)) revert InvalidRegistry();
        instrumentRegistry = _instrumentRegistry;
    }

    function setSwapPoolRegistry(SwapPoolRegistry _swapPoolRegistry) external onlyOwner {
        if (address(_swapPoolRegistry) == address(0)) revert InvalidRegistry();
        swapPoolRegistry = _swapPoolRegistry;
    }

    /// @notice Sets Circle CCTP TokenMessengerV2 contract used for bridging stable funds
    /// @param _cctpBridge CCTP bridge adapter address
    function setCCTPBridge(address _cctpBridge) external onlyOwner {
        if (_cctpBridge == address(0)) revert InvalidAddress();
        cctpBridge = _cctpBridge;
        emit CCTPBridgeUpdated(_cctpBridge);
    }

    function setCCTPReceiver(address _cctpReceiver) external onlyOwner {
        if (_cctpReceiver == address(0)) revert InvalidAddress();
        cctpReceiver = _cctpReceiver;
        emit CCTPReceiverUpdated(_cctpReceiver);
    }

    /// @notice Rescue tokens accidentally sent to the contract
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ============ External Functions ============

    /// @notice Buy an instrument, bridging cross-chain if needed
    /// @param instrumentId The globally unique instrument identifier
    /// @param amount The amount of stable currency to spend
    /// @param minDepositedAmount Minimum amount deposited into lending (slippage protection, ignored for cross-chain)
    /// @param fastTransfer Whether to use fast CCTP transfer (cross-chain only)
    /// @param maxFee Maximum fee for fast transfer (cross-chain only)
    /// @return depositedAmount The amount deposited (0 for cross-chain, actual amount for local)
    function buy(bytes32 instrumentId, uint256 amount, uint256 minDepositedAmount, bool fastTransfer, uint256 maxFee)
        external
        returns (uint256 depositedAmount)
    {
        if (amount == 0) revert InvalidAmount();

        uint32 targetChain = InstrumentIdLib.getInstrumentChainId(instrumentId);
        if (targetChain != _safeChainId()) {
            _bridgeForCrossChainInstrument(instrumentId, amount, targetChain, fastTransfer, maxFee);
            return 0; // Cross-chain: deposit happens on destination chain
        }

        depositedAmount = _buyLocal(instrumentId, amount, msg.sender, msg.sender);
        if (depositedAmount < minDepositedAmount) revert InsufficientOutput(depositedAmount, minDepositedAmount);
    }

    /// @notice Buy on behalf of a recipient — called by CCTPReceiver for cross-chain buys
    /// @dev Only callable by the configured cctpReceiver
    function buyFor(bytes32 instrumentId, uint256 amount, address recipient)
        external
        returns (uint256 depositedAmount)
    {
        if (msg.sender != cctpReceiver) revert UnauthorizedBuyForCaller();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();

        return _buyLocal(instrumentId, amount, msg.sender, recipient);
    }

    function _buyLocal(bytes32 instrumentId, uint256 amount, address payer, address recipient)
        internal
        returns (uint256 depositedAmount)
    {
        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

        // Pull stable tokens from user
        IERC20(Currency.unwrap(stable)).safeTransferFrom(payer, address(this), amount);

        // Swap if stable differs from the market's underlying currency
        if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
            PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
            depositedAmount = _executeSwap(swapPool, stable, marketCurrency, amount);
        } else {
            depositedAmount = amount;
        }

        // Deposit to lending protocol — yield tokens go to recipient
        LendingExecutor.deposit(adapter, marketId, marketCurrency, depositedAmount, recipient);

        emit Buy(instrumentId, recipient, amount, depositedAmount);
    }

    /// @notice Sell an instrument: withdraw from lending and swap to USDC (if needed)
    /// @param instrumentId The globally unique instrument identifier
    /// @param yieldTokenAmount The amount of yield-bearing tokens to redeem
    /// @param minOutputAmount Minimum stable currency to receive (slippage protection)
    /// @return outputAmount The actual amount of stable currency returned to the caller
    function sell(bytes32 instrumentId, uint256 yieldTokenAmount, uint256 minOutputAmount) external returns (uint256 outputAmount) {
        if (InstrumentIdLib.getInstrumentChainId(instrumentId) != _safeChainId()) {
            revert CrossChainSellNotSupported();
        }
        if (yieldTokenAmount == 0) revert InvalidAmount();

        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

        // Withdraw from lending protocol — yield tokens transferred from user to adapter
        // NOTE: For Compound V3, user must call comet.allow(router, true) instead of ERC20 approve
        uint256 withdrawnAmount =
            LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldTokenAmount, msg.sender, address(this));

        // Swap if market currency differs from stable
        if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
            PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
            outputAmount = _executeSwap(swapPool, marketCurrency, stable, withdrawnAmount);
        } else {
            outputAmount = withdrawnAmount;
        }

        if (outputAmount < minOutputAmount) revert InsufficientOutput(outputAmount, minOutputAmount);

        // Send stable tokens to caller
        IERC20(Currency.unwrap(stable)).safeTransfer(msg.sender, outputAmount);

        emit Sell(instrumentId, msg.sender, yieldTokenAmount, outputAmount);
    }

    // ============ Callback ============

    /// @notice Called by PoolManager during unlock to execute the swap
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();

        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));
        uint256 outputAmount = SwapExecutor.executeSwap(
            poolManager, data.swapPool, data.inputCurrency, data.outputCurrency, data.inputAmount
        );

        return abi.encode(outputAmount);
    }

    // ============ Internal ============

    function _executeSwap(PoolKey memory swapPool, Currency inputCurrency, Currency outputCurrency, uint256 inputAmount)
        internal
        returns (uint256 outputAmount)
    {
        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    swapPool: swapPool,
                    inputCurrency: inputCurrency,
                    outputCurrency: outputCurrency,
                    inputAmount: inputAmount
                })
            )
        );
        outputAmount = abi.decode(result, (uint256));
    }

    /// @dev Safely cast block.chainid to uint32, reverts on overflow
    function _safeChainId() internal view returns (uint32) {
        if (block.chainid > type(uint32).max) revert ChainIdOverflow();
        return uint32(block.chainid);
    }

    function _bridgeForCrossChainInstrument(
        bytes32 instrumentId,
        uint256 amount,
        uint32 targetChain,
        bool fastTransfer,
        uint256 maxFee
    ) internal {
        if (cctpBridge == address(0)) revert CrossChainBridgeNotConfigured();

        address stableToken = Currency.unwrap(stable);

        // NOTE: Uses push-transfer pattern — the bridge adapter must handle tokens
        // already in its balance (not transferFrom). Verify bridge adapter compatibility.
        IERC20(stableToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(stableToken).safeTransfer(cctpBridge, amount);

        bytes memory hookData = abi.encode(instrumentId, msg.sender);

        (uint32 destinationDomain, bytes32 resolvedMintRecipient, uint32 minFinalityThreshold) = ICCTPBridge(cctpBridge)
            .bridge(
                stableToken, msg.sender, amount, targetChain, fastTransfer, maxFee, hookData
            );

        emit CCTPBridgeInitiated(
            msg.sender,
            instrumentId,
            amount,
            destinationDomain,
            resolvedMintRecipient,
            maxFee,
            minFinalityThreshold
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============
    // Direct state variables: poolManager, instrumentRegistry, swapPoolRegistry, stable, cctpBridge, cctpReceiver = 6
    // Gap: 50 - 6 = 44. Verify with: forge inspect SwapDepositRouter storage-layout
    // If adding a new state variable, DECREMENT the gap size by the slots consumed.

    uint256[44] private __gap;
}
