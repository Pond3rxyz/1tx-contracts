// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {CompoundAdapter} from "../../src/adapters/CompoundAdapter.sol";
import {ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {MorphoAdapter} from "../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../src/adapters/EulerAdapter.sol";
import {FluidAdapter} from "../../src/adapters/FluidAdapter.sol";

/// @title AdapterProxyLib
/// @notice Test helper that deploys each lending adapter behind an ERC1967Proxy, mirroring the
///         production deploy path. Keeps proxy wiring out of individual tests.
library AdapterProxyLib {
    function deployAave(address aavePool, address owner) internal returns (AaveAdapter) {
        AaveAdapter impl = new AaveAdapter();
        return AaveAdapter(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(AaveAdapter.initialize, (aavePool, owner))))
        );
    }

    function deployCompound(address owner) internal returns (CompoundAdapter) {
        CompoundAdapter impl = new CompoundAdapter();
        return
            CompoundAdapter(
                address(new ERC1967Proxy(address(impl), abi.encodeCall(CompoundAdapter.initialize, (owner))))
            );
    }

    function deployERC4626(address owner) internal returns (ERC4626Adapter) {
        ERC4626Adapter impl = new ERC4626Adapter();
        return
            ERC4626Adapter(address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC4626Adapter.initialize, (owner)))));
    }

    function deployMorpho(address owner) internal returns (MorphoAdapter) {
        MorphoAdapter impl = new MorphoAdapter();
        return
            MorphoAdapter(address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC4626Adapter.initialize, (owner)))));
    }

    function deployEuler(address owner) internal returns (EulerAdapter) {
        EulerAdapter impl = new EulerAdapter();
        return
            EulerAdapter(address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC4626Adapter.initialize, (owner)))));
    }

    function deployFluid(address owner) internal returns (FluidAdapter) {
        FluidAdapter impl = new FluidAdapter();
        return
            FluidAdapter(address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC4626Adapter.initialize, (owner)))));
    }
}
