// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ITokenMessengerV2} from "./interfaces/cctp/ITokenMessengerV2.sol";
import {ICCTPBridge} from "./interfaces/ICCTPBridge.sol";

/// @title CCTPBridge
/// @notice Dedicated CCTP adapter used by SwapDepositRouter for cross-chain buy flows
contract CCTPBridge is Initializable, UUPSUpgradeable, OwnableUpgradeable, ICCTPBridge {
    using SafeERC20 for IERC20;

    struct BridgeParams {
        address stableToken;
        address sender;
        uint256 amount;
        uint32 targetChain;
        bool fastTransfer;
        uint256 maxFee;
    }

    uint32 public constant CCTP_FAST_FINALITY_THRESHOLD = 1000;
    uint32 public constant CCTP_STANDARD_FINALITY_THRESHOLD = 2000;

    address public tokenMessenger;
    mapping(uint32 chainId => uint32 cctpDomain) public chainIdToCCTPDomain;
    mapping(uint32 chainId => bool configured) public configuredDomains;
    mapping(uint32 chainId => bytes32 mintRecipient) public chainIdToMintRecipient;
    mapping(uint32 chainId => bytes32 destinationCaller) public chainIdToDestinationCaller;
    mapping(address caller => bool isAuthorized) public authorizedCallers;

    error InvalidAddress();
    error InvalidAmount();
    error UnauthorizedCaller();
    error TokenMessengerNotConfigured();
    error DestinationDomainNotConfigured(uint32 chainId);
    error FastTransferRequiresFee();
    error DestinationCallerNotConfigured(uint32 chainId);
    error MintRecipientNotConfigured(uint32 chainId);
    error DomainNotConfigured(uint32 chainId);
    error CannotBridgeToSelf();

    event TokenMessengerUpdated(address indexed tokenMessenger);
    event DestinationDomainUpdated(uint32 indexed chainId, uint32 indexed cctpDomain);
    event DestinationMintRecipientUpdated(uint32 indexed chainId, bytes32 mintRecipient);
    event DestinationCallerUpdated(uint32 indexed chainId, bytes32 destinationCaller);
    event AuthorizedCallerUpdated(address indexed caller, bool allowed);
    event DestinationDomainRemoved(uint32 indexed chainId);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event BridgeExecuted(
        address indexed sender,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 amount,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function setTokenMessenger(address _tokenMessenger) external onlyOwner {
        if (_tokenMessenger == address(0)) revert InvalidAddress();
        tokenMessenger = _tokenMessenger;
        emit TokenMessengerUpdated(_tokenMessenger);
    }

    function setDestinationDomain(uint32 chainId, uint32 cctpDomain) external onlyOwner {
        chainIdToCCTPDomain[chainId] = cctpDomain;
        configuredDomains[chainId] = true;
        emit DestinationDomainUpdated(chainId, cctpDomain);
    }

    function removeDestinationDomain(uint32 chainId) external onlyOwner {
        if (!configuredDomains[chainId]) revert DomainNotConfigured(chainId);
        delete chainIdToCCTPDomain[chainId];
        configuredDomains[chainId] = false;
        emit DestinationDomainRemoved(chainId);
    }

    function setDestinationMintRecipient(uint32 chainId, bytes32 mintRecipient) external onlyOwner {
        chainIdToMintRecipient[chainId] = mintRecipient;
        emit DestinationMintRecipientUpdated(chainId, mintRecipient);
    }

    function setDestinationCaller(uint32 chainId, bytes32 _destinationCaller) external onlyOwner {
        chainIdToDestinationCaller[chainId] = _destinationCaller;
        emit DestinationCallerUpdated(chainId, _destinationCaller);
    }

    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0)) revert InvalidAddress();
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerUpdated(caller, allowed);
    }

    function bridge(
        address stableToken,
        address sender,
        uint256 amount,
        uint32 targetChain,
        bool fastTransfer,
        uint256 maxFee,
        bytes calldata hookData
    ) external returns (uint32 destinationDomain, bytes32 resolvedMintRecipient, uint32 minFinalityThreshold) {
        BridgeParams memory p = BridgeParams({
            stableToken: stableToken,
            sender: sender,
            amount: amount,
            targetChain: targetChain,
            fastTransfer: fastTransfer,
            maxFee: maxFee
        });
        return _executeBridge(p, hookData);
    }

    function _executeBridge(BridgeParams memory p, bytes calldata hookData)
        internal
        returns (uint32 destinationDomain, bytes32 resolvedMintRecipient, uint32 minFinalityThreshold)
    {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        if (p.amount == 0) revert InvalidAmount();
        if (p.stableToken == address(0)) revert InvalidAddress();
        if (p.sender == address(0)) revert InvalidAddress();
        if (tokenMessenger == address(0)) revert TokenMessengerNotConfigured();
        if (!configuredDomains[p.targetChain]) revert DestinationDomainNotConfigured(p.targetChain);
        if (p.targetChain == block.chainid) revert CannotBridgeToSelf();

        destinationDomain = chainIdToCCTPDomain[p.targetChain];

        minFinalityThreshold = p.fastTransfer ? CCTP_FAST_FINALITY_THRESHOLD : CCTP_STANDARD_FINALITY_THRESHOLD;
        if (p.fastTransfer && p.maxFee == 0) revert FastTransferRequiresFee();

        resolvedMintRecipient = chainIdToMintRecipient[p.targetChain];
        if (resolvedMintRecipient == bytes32(0)) revert MintRecipientNotConfigured(p.targetChain);

        IERC20(p.stableToken).forceApprove(tokenMessenger, p.amount);
        bytes32 resolvedDestinationCaller = chainIdToDestinationCaller[p.targetChain];
        if (resolvedDestinationCaller == bytes32(0)) revert DestinationCallerNotConfigured(p.targetChain);

        ITokenMessengerV2(tokenMessenger)
            .depositForBurnWithHook(
                p.amount,
                destinationDomain,
                resolvedMintRecipient,
                p.stableToken,
                resolvedDestinationCaller,
                p.maxFee,
                minFinalityThreshold,
                hookData
            );

        emit BridgeExecuted(
            p.sender,
            destinationDomain,
            resolvedMintRecipient,
            resolvedDestinationCaller,
            p.amount,
            p.maxFee,
            minFinalityThreshold
        );
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[44] private __gap;
}
