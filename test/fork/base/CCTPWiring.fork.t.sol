// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCTPWiringForkTest} from "../../utils/CCTPWiringForkTest.sol";

/// @notice Base half of the CCTP wiring checks — see {CCTPWiringForkTest}.
contract BaseCCTPWiringForkTest is CCTPWiringForkTest {
    function setUp() public {
        _initWiringTest("baseMainnet");
    }
}
