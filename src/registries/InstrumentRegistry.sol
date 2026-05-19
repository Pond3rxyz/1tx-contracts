// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {InstrumentIdLib} from "../libraries/InstrumentIdLib.sol";

/// @title InstrumentRegistry
/// @notice Central registry for managing lending protocol instruments across adapters
/// @dev Maps globally unique instrument IDs (with embedded chainId) to adapter + marketId pairs
contract InstrumentRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /// @notice Information about a registered instrument
    struct InstrumentInfo {
        address adapter;
        bytes32 marketId;
    }

    // ============ Errors ============

    error InvalidAdapterAddress();
    error InvalidExecutionAddress();
    error MarketNotRegisteredInAdapter();
    error InstrumentNotRegistered();
    error InstrumentAlreadyRegistered();

    // ============ Events ============

    event InstrumentRegistered(
        bytes32 indexed instrumentId,
        address indexed adapter,
        uint256 chainId,
        address executionAddress,
        bytes32 marketId
    );

    event InstrumentUnregistered(bytes32 indexed instrumentId);

    // ============ State ============

    /// @notice Maps instrument IDs to their corresponding adapter and market info
    /// @dev instrumentId structure: [chainId: 32 bits][hash(executionAddress, marketId): 224 bits]
    mapping(bytes32 instrumentId => InstrumentInfo) public instruments;

    // ============ Constructor / Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract (replaces constructor for proxy pattern)
    /// @param initialOwner The initial owner of the registry
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    // ============ Admin Functions ============

    /// @notice Registers a new instrument in the registry
    /// @param executionAddress The immutable contract that holds user funds
    /// @param marketId The protocol-specific market identifier
    /// @param adapter The address of the lending adapter that handles this instrument
    function registerInstrument(address executionAddress, bytes32 marketId, address adapter) external onlyOwner {
        if (adapter == address(0)) revert InvalidAdapterAddress();
        if (executionAddress == address(0)) revert InvalidExecutionAddress();

        ILendingAdapter adapterContract = ILendingAdapter(adapter);

        if (!adapterContract.hasMarket(marketId)) revert MarketNotRegisteredInAdapter();

        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, marketId);

        if (instruments[instrumentId].adapter != address(0)) revert InstrumentAlreadyRegistered();

        instruments[instrumentId] = InstrumentInfo({adapter: adapter, marketId: marketId});

        emit InstrumentRegistered(instrumentId, adapter, block.chainid, executionAddress, marketId);
    }

    /// @notice Unregisters an instrument from the registry
    /// @param instrumentId The globally unique instrument identifier to remove
    function unregisterInstrument(bytes32 instrumentId) external onlyOwner {
        if (instruments[instrumentId].adapter == address(0)) revert InstrumentNotRegistered();

        delete instruments[instrumentId];

        emit InstrumentUnregistered(instrumentId);
    }

    // ============ View Functions ============

    /// @notice Gas-optimized retrieval returning individual values instead of struct
    /// @param instrumentId The globally unique instrument identifier
    /// @return adapter The address of the lending adapter
    /// @return marketId The protocol-specific market identifier
    function getInstrumentDirect(bytes32 instrumentId) external view returns (address adapter, bytes32 marketId) {
        InstrumentInfo storage info = instruments[instrumentId];
        adapter = info.adapter;
        if (adapter == address(0)) revert InstrumentNotRegistered();
        marketId = info.marketId;
    }

    // ============ Internal ============

    /// @notice Authorizes an upgrade to a new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Storage Gap ============

    uint256[49] private __gap;
}
