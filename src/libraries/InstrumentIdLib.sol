// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InstrumentIdLib
/// @notice Library for generating globally unique instrument identifiers
library InstrumentIdLib {
    /// @notice Generates a globally unique instrument ID across all chains and protocols
    /// @dev ID Structure: [chainId: 32 bits][hash(executionAddress, marketId): 224 bits]
    /// @dev executionAddress is the immutable contract holding funds, ensuring ID stability across adapter upgrades
    /// @param chainId The blockchain identifier (1 = Ethereum, 8453 = Base, etc.)
    /// @param executionAddress The immutable contract that holds user funds:
    ///        - Aave: Pool address (single pool for all markets)
    ///        - Compound V3: Comet address (one per base asset)
    ///        - Morpho/Euler/Fluid: Vault address (one per strategy)
    /// @param marketId The protocol-specific market identifier
    /// @return instrumentId The globally unique identifier for this instrument
    function generateInstrumentId(uint256 chainId, address executionAddress, bytes32 marketId)
        internal
        pure
        returns (bytes32 instrumentId)
    {
        bytes32 localHash = keccak256(abi.encode(executionAddress, marketId));
        instrumentId = bytes32((uint256(chainId) << 224) | (uint256(localHash) >> 32));
    }

    /// @notice Extracts the chainId from an instrument ID
    /// @dev Reads the first 32 bits (most significant) of the ID
    /// @param instrumentId The instrument ID to extract from
    /// @return chainId The chain ID embedded in the instrument ID
    function getInstrumentChainId(bytes32 instrumentId) internal pure returns (uint32 chainId) {
        chainId = uint32(uint256(instrumentId) >> 224);
    }
}
