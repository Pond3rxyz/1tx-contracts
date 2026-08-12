// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCTPWiringForkTest} from "../../utils/CCTPWiringForkTest.sol";

/// @notice Monad half of the CCTP wiring checks — see {CCTPWiringForkTest}.
contract MonadCCTPWiringForkTest is CCTPWiringForkTest {
    function setUp() public {
        _initWiringTest("monadMainnet");
    }
}
