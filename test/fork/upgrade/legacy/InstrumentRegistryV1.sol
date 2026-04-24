// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILendingAdapter} from "../../../../src/interfaces/ILendingAdapter.sol";
import {InstrumentIdLib} from "../../../../src/libraries/InstrumentIdLib.sol";

contract InstrumentRegistryV1 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    struct InstrumentInfo {
        address adapter;
        bytes32 marketId;
    }

    error InvalidAdapterAddress();
    error InvalidExecutionAddress();
    error MarketNotRegisteredInAdapter();
    error ChainIdMismatch();
    error InstrumentNotRegistered();
    error InstrumentAlreadyRegistered();

    event InstrumentRegistered(
        bytes32 indexed instrumentId,
        address indexed adapter,
        uint256 chainId,
        address executionAddress,
        bytes32 marketId
    );

    event InstrumentUnregistered(bytes32 indexed instrumentId);

    mapping(bytes32 instrumentId => InstrumentInfo) public instruments;

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function registerInstrument(address executionAddress, bytes32 marketId, address adapter) external onlyOwner {
        if (adapter == address(0)) revert InvalidAdapterAddress();
        if (executionAddress == address(0)) revert InvalidExecutionAddress();

        ILendingAdapter adapterContract = ILendingAdapter(adapter);

        if (!adapterContract.hasMarket(marketId)) revert MarketNotRegisteredInAdapter();

        ILendingAdapter.AdapterMetadata memory metadata = adapterContract.getAdapterMetadata();
        if (metadata.chainId != block.chainid) revert ChainIdMismatch();

        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, marketId);

        if (instruments[instrumentId].adapter != address(0)) revert InstrumentAlreadyRegistered();

        instruments[instrumentId] = InstrumentInfo({adapter: adapter, marketId: marketId});

        emit InstrumentRegistered(instrumentId, adapter, block.chainid, executionAddress, marketId);
    }

    function unregisterInstrument(bytes32 instrumentId) external onlyOwner {
        if (instruments[instrumentId].adapter == address(0)) revert InstrumentNotRegistered();

        delete instruments[instrumentId];

        emit InstrumentUnregistered(instrumentId);
    }

    function getInstrument(bytes32 instrumentId) external view returns (InstrumentInfo memory instrument) {
        instrument = instruments[instrumentId];
        if (instrument.adapter == address(0)) revert InstrumentNotRegistered();
        return instrument;
    }

    function getInstrumentDirect(bytes32 instrumentId) external view returns (address adapter, bytes32 marketId) {
        InstrumentInfo storage info = instruments[instrumentId];
        adapter = info.adapter;
        if (adapter == address(0)) revert InstrumentNotRegistered();
        marketId = info.marketId;
    }

    function isInstrumentRegistered(bytes32 instrumentId) external view returns (bool) {
        return instruments[instrumentId].adapter != address(0);
    }

    function getInstrumentDetails(bytes32 instrumentId)
        external
        view
        returns (address adapter, bytes32 marketId, address yieldToken, uint8 decimals)
    {
        InstrumentInfo memory info = instruments[instrumentId];
        if (info.adapter == address(0)) revert InstrumentNotRegistered();

        ILendingAdapter adapterContract = ILendingAdapter(info.adapter);
        yieldToken = adapterContract.getYieldToken(info.marketId);
        decimals = IERC20Metadata(yieldToken).decimals();

        return (info.adapter, info.marketId, yieldToken, decimals);
    }

    function getInstrumentChainId(bytes32 instrumentId) public pure returns (uint32 chainId) {
        return InstrumentIdLib.getInstrumentChainId(instrumentId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[49] private __gap;
}
