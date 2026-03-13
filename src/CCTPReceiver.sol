// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title CCTPReceiver
/// @notice Receives CCTP messages and executes destination buy automatically
contract CCTPReceiver is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant CCTP_HEADER_SIZE = 148;
    uint256 internal constant CCTP_BURN_MESSAGE_SIZE = 228;

    address public router;
    address public stableToken;
    address public messageTransmitter;

    uint256 private _locked;

    error ZeroAddress();
    error ReentrancyGuard();
    error CCTPRedeemFailed();
    error InvalidMessageLength();
    error InvalidRecipient();
    error InvalidHookData();
    error AmountMismatch();
    error InsufficientOutput(uint256 actual, uint256 minimum);

    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event MessageTransmitterUpdated(address indexed oldTransmitter, address indexed newTransmitter);
    event StableTokenUpdated(address indexed oldToken, address indexed newToken);
    event CrossChainBuyExecuted(
        bytes32 indexed instrumentId, address indexed recipient, uint256 amount, uint256 depositedAmount
    );
    event CrossChainBuyFailed(bytes32 indexed instrumentId, address indexed recipient, uint256 amount, bytes reason);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _router, address _stableToken, address _messageTransmitter)
        external
        initializer
    {
        if (_router == address(0)) revert ZeroAddress();
        if (_stableToken == address(0)) revert ZeroAddress();
        if (_messageTransmitter == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);

        router = _router;
        stableToken = _stableToken;
        messageTransmitter = _messageTransmitter;
        _locked = 1;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    function setRouter(address _newRouter) external onlyOwner {
        if (_newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(router, _newRouter);
        router = _newRouter;
    }

    function setMessageTransmitter(address _newTransmitter) external onlyOwner {
        if (_newTransmitter == address(0)) revert ZeroAddress();
        emit MessageTransmitterUpdated(messageTransmitter, _newTransmitter);
        messageTransmitter = _newTransmitter;
    }

    function setStableToken(address _newStableToken) external onlyOwner {
        if (_newStableToken == address(0)) revert ZeroAddress();
        emit StableTokenUpdated(stableToken, _newStableToken);
        stableToken = _newStableToken;
    }

    function rescueTokens(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    function redeem(bytes calldata message, bytes calldata attestation) external nonReentrant returns (bool) {
        if (message.length < CCTP_HEADER_SIZE + CCTP_BURN_MESSAGE_SIZE) revert InvalidMessageLength();

        uint256 balanceBefore = IERC20(stableToken).balanceOf(address(this));

        bool ok = IMessageTransmitter(messageTransmitter).receiveMessage(message, attestation);
        if (!ok) revert CCTPRedeemFailed();

        uint256 balanceAfter = IERC20(stableToken).balanceOf(address(this));
        uint256 actualMinted = balanceAfter - balanceBefore;

        bytes calldata messageBody = message[CCTP_HEADER_SIZE:];
        uint256 messageAmount = _readUint256(messageBody, 68);
        bytes memory hookData = _sliceMessageBodyHookData(messageBody);

        if (actualMinted > messageAmount) revert AmountMismatch();
        if (hookData.length == 0) return true;
        if (hookData.length != 96) revert InvalidHookData();

        (bytes32 instrumentId, address recipient, uint256 minDepositedAmount) =
            abi.decode(hookData, (bytes32, address, uint256));

        if (recipient == address(0)) revert InvalidRecipient();

        IERC20(stableToken).forceApprove(router, actualMinted);

        try ISwapDepositRouter(router).buyFor(instrumentId, actualMinted, recipient) returns (uint256 depositedAmount) {
            if (depositedAmount < minDepositedAmount) revert InsufficientOutput(depositedAmount, minDepositedAmount);
            emit CrossChainBuyExecuted(instrumentId, recipient, actualMinted, depositedAmount);
        } catch (bytes memory reason) {
            IERC20(stableToken).forceApprove(router, 0);
            IERC20(stableToken).safeTransfer(recipient, actualMinted);
            emit CrossChainBuyFailed(instrumentId, recipient, actualMinted, reason);
        }

        return true;
    }

    function _readUint256(bytes calldata data, uint256 offset) internal pure returns (uint256 value) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            value := calldataload(add(data.offset, offset))
        }
    }

    function _sliceMessageBodyHookData(bytes calldata messageBody) internal pure returns (bytes memory hookData) {
        if (messageBody.length <= CCTP_BURN_MESSAGE_SIZE) return "";
        hookData = messageBody[228:];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[46] private __gap;
}

interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

interface ISwapDepositRouter {
    function buyFor(bytes32 instrumentId, uint256 amount, address recipient) external returns (uint256 depositedAmount);
}
