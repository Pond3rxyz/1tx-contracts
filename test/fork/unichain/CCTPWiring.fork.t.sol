// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCTPWiringForkTest} from "../../utils/CCTPWiringForkTest.sol";

/// @notice Unichain half of the CCTP wiring checks — see {CCTPWiringForkTest}.
contract UnichainCCTPWiringForkTest is CCTPWiringForkTest {
    function setUp() public {
        _initWiringTest("unichainMainnet");
    }
}
