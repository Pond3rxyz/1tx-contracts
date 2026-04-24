// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =====================================================================================
// Pre-selector-cleanup snapshot of SwapDepositRouter. Used as the storage-layout
// reference for upgrade validation in SwapDepositRouter.upgrade.t.sol — DO NOT EDIT.
// =====================================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {InstrumentRegistry} from "../../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../../src/registries/SwapPoolRegistry.sol";
import {ILendingAdapter} from "../../../../src/interfaces/ILendingAdapter.sol";
import {ICCTPBridge} from "../../../../src/interfaces/ICCTPBridge.sol";
import {InstrumentIdLib} from "../../../../src/libraries/InstrumentIdLib.sol";
import {SwapExecutor} from "../../../../src/libraries/SwapExecutor.sol";
import {LendingExecutor} from "../../../../src/libraries/LendingExecutor.sol";

contract SwapDepositRouterV2 is Initializable, UUPSUpgradeable, OwnableUpgradeable, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    uint16 public constant MAX_PROTOCOL_FEE_BPS = 500;
    uint16 public constant MAX_REFERRAL_FEE_BPS = 500;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    IPoolManager public poolManager;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    Currency public stable;
    address public cctpBridge;
    address public cctpReceiver;

    uint16 public protocolFeeBps;
    address public feeRecipient;

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
    error FeeTooHigh();

    event Buy(bytes32 indexed instrumentId, address indexed recipient, uint256 inputAmount, uint256 depositedAmount);
    event Sell(bytes32 indexed instrumentId, address indexed recipient, uint256 yieldTokenAmount, uint256 outputAmount);
    event FeeConfigUpdated(uint16 protocolFeeBps, address feeRecipient);
    event FeeCharged(address indexed recipient, uint256 amount, string feeType);
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

    struct SwapCallbackData {
        PoolKey swapPool;
        Currency inputCurrency;
        Currency outputCurrency;
        uint256 inputAmount;
    }

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

    function setFeeConfig(uint16 _protocolFeeBps, address _feeRecipient) external onlyOwner {
        if (_protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        if (_feeRecipient == address(0)) revert InvalidAddress();
        protocolFeeBps = _protocolFeeBps;
        feeRecipient = _feeRecipient;
        emit FeeConfigUpdated(_protocolFeeBps, _feeRecipient);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function buy(bytes32 instrumentId, uint256 amount, uint256 minDepositedAmount, bool fastTransfer, uint256 maxFee)
        external
        returns (uint256 depositedAmount)
    {
        return _processBuy(instrumentId, amount, minDepositedAmount, fastTransfer, maxFee, 0, address(0));
    }

    function buy(
        bytes32 instrumentId,
        uint256 amount,
        uint256 minDepositedAmount,
        bool fastTransfer,
        uint256 maxFee,
        uint16 referralFeeBps,
        address referralWallet
    ) external returns (uint256 depositedAmount) {
        if (referralFeeBps > MAX_REFERRAL_FEE_BPS) revert FeeTooHigh();
        return
            _processBuy(instrumentId, amount, minDepositedAmount, fastTransfer, maxFee, referralFeeBps, referralWallet);
    }

    function _processBuy(
        bytes32 instrumentId,
        uint256 amount,
        uint256 minDepositedAmount,
        bool fastTransfer,
        uint256 maxFee,
        uint16 referralFeeBps,
        address referralWallet
    ) internal returns (uint256 depositedAmount) {
        if (amount == 0) revert InvalidAmount();

        IERC20(Currency.unwrap(stable)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 netAmount = amount;
        netAmount -= _deductFee(amount, protocolFeeBps, feeRecipient, "protocol");
        netAmount -= _deductFee(amount, referralFeeBps, referralWallet, "referral");

        uint32 targetChain = InstrumentIdLib.getInstrumentChainId(instrumentId);
        if (targetChain != _safeChainId()) {
            _bridgeForCrossChainInstrument(
                instrumentId, netAmount, targetChain, fastTransfer, maxFee, minDepositedAmount
            );
            return 0;
        }

        depositedAmount = _buyLocal(instrumentId, netAmount, msg.sender);
        if (depositedAmount < minDepositedAmount) revert InsufficientOutput(depositedAmount, minDepositedAmount);
    }

    function buyFor(bytes32 instrumentId, uint256 amount, address recipient)
        external
        returns (uint256 depositedAmount)
    {
        if (msg.sender != cctpReceiver) revert UnauthorizedBuyForCaller();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();

        IERC20(Currency.unwrap(stable)).safeTransferFrom(msg.sender, address(this), amount);

        return _buyLocal(instrumentId, amount, recipient);
    }

    function _buyLocal(bytes32 instrumentId, uint256 amount, address recipient)
        internal
        returns (uint256 depositedAmount)
    {
        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);

        if (Currency.unwrap(stable) != Currency.unwrap(marketCurrency)) {
            PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(stable, marketCurrency);
            depositedAmount = _executeSwap(swapPool, stable, marketCurrency, amount);
        } else {
            depositedAmount = amount;
        }

        LendingExecutor.deposit(adapter, marketId, marketCurrency, depositedAmount, recipient);

        emit Buy(instrumentId, recipient, amount, depositedAmount);
    }

    function sell(bytes32 instrumentId, uint256 yieldTokenAmount, uint256 minOutputAmount)
        external
        returns (uint256 outputAmount)
    {
        return _processSell(instrumentId, yieldTokenAmount, minOutputAmount, 0, address(0));
    }

    function sell(
        bytes32 instrumentId,
        uint256 yieldTokenAmount,
        uint256 minOutputAmount,
        uint16 referralFeeBps,
        address referralWallet
    ) external returns (uint256 outputAmount) {
        if (referralFeeBps > MAX_REFERRAL_FEE_BPS) revert FeeTooHigh();
        return _processSell(instrumentId, yieldTokenAmount, minOutputAmount, referralFeeBps, referralWallet);
    }

    function _processSell(
        bytes32 instrumentId,
        uint256 yieldTokenAmount,
        uint256 minOutputAmount,
        uint16 referralFeeBps,
        address referralWallet
    ) internal returns (uint256 outputAmount) {
        if (InstrumentIdLib.getInstrumentChainId(instrumentId) != _safeChainId()) {
            revert CrossChainSellNotSupported();
        }
        if (yieldTokenAmount == 0) revert InvalidAmount();

        (address adapter, bytes32 marketId) = instrumentRegistry.getInstrumentDirect(instrumentId);
        Currency marketCurrency = ILendingAdapter(adapter).getMarketCurrency(marketId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);

        uint256 withdrawnAmount =
            LendingExecutor.withdraw(adapter, marketId, yieldToken, yieldTokenAmount, msg.sender, address(this));

        uint256 grossOutputAmount;
        if (Currency.unwrap(marketCurrency) != Currency.unwrap(stable)) {
            PoolKey memory swapPool = swapPoolRegistry.getDefaultSwapPool(marketCurrency, stable);
            grossOutputAmount = _executeSwap(swapPool, marketCurrency, stable, withdrawnAmount);
        } else {
            grossOutputAmount = withdrawnAmount;
        }

        outputAmount = grossOutputAmount;
        outputAmount -= _deductFee(grossOutputAmount, protocolFeeBps, feeRecipient, "protocol");
        outputAmount -= _deductFee(grossOutputAmount, referralFeeBps, referralWallet, "referral");

        if (outputAmount < minOutputAmount) revert InsufficientOutput(outputAmount, minOutputAmount);

        IERC20(Currency.unwrap(stable)).safeTransfer(msg.sender, outputAmount);

        emit Sell(instrumentId, msg.sender, yieldTokenAmount, outputAmount);
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();

        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));
        uint256 outputAmount = SwapExecutor.executeSwap(
            poolManager, data.swapPool, data.inputCurrency, data.outputCurrency, data.inputAmount
        );

        return abi.encode(outputAmount);
    }

    function _deductFee(uint256 amount, uint16 feeBps, address recipient, string memory feeType)
        internal
        returns (uint256 feeAmount)
    {
        if (feeBps == 0 || recipient == address(0)) return 0;
        feeAmount = (amount * feeBps) / BPS_DENOMINATOR;
        if (feeAmount > 0) {
            IERC20(Currency.unwrap(stable)).safeTransfer(recipient, feeAmount);
            emit FeeCharged(recipient, feeAmount, feeType);
        }
    }

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

    function _safeChainId() internal view returns (uint32) {
        if (block.chainid > type(uint32).max) revert ChainIdOverflow();
        return uint32(block.chainid);
    }

    function _bridgeForCrossChainInstrument(
        bytes32 instrumentId,
        uint256 amount,
        uint32 targetChain,
        bool fastTransfer,
        uint256 maxFee,
        uint256 minDepositedAmount
    ) internal {
        if (cctpBridge == address(0)) revert CrossChainBridgeNotConfigured();

        address stableToken = Currency.unwrap(stable);

        IERC20(stableToken).safeTransfer(cctpBridge, amount);

        bytes memory hookData = abi.encode(instrumentId, msg.sender, minDepositedAmount);

        (uint32 destinationDomain, bytes32 resolvedMintRecipient, uint32 minFinalityThreshold) =
            ICCTPBridge(cctpBridge).bridge(stableToken, msg.sender, amount, targetChain, fastTransfer, maxFee, hookData);

        emit CCTPBridgeInitiated(
            msg.sender, instrumentId, amount, destinationDomain, resolvedMintRecipient, maxFee, minFinalityThreshold
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[43] private __gap;
}
