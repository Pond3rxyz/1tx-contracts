// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SwapDepositRouter} from "../../../src/SwapDepositRouter.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {ILendingAdapter} from "../../../src/interfaces/ILendingAdapter.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";

/// @title ApiInstrumentsArbitrumForkTest
/// @notice Verifies that every instrument returned by the API is registered on-chain
///         and that buyFor works for each one using the actual deployed contracts.
/// @dev Instrument IDs are computed from constituent fields (executionAddress + marketId)
///      using InstrumentIdLib, NOT hardcoded from the API.
///
///      Run with: ARBITRUM_RPC_URL=... forge test --mc ApiInstrumentsArbitrumForkTest -vvv
contract ApiInstrumentsArbitrumForkTest is Test {
    // ============ Deployed Addresses (Arbitrum) ============

    SwapDepositRouter public constant ROUTER = SwapDepositRouter(0xC46C6b9260F3BD3735637AaEd4fBD1B1dE6D84AE);
    InstrumentRegistry public constant REGISTRY = InstrumentRegistry(0x6d116ad5571BC8F2fd3839Fb18c351F58eaBdd97);
    address public constant CCTP_RECEIVER = 0xFCc3e94Eb1A6942a462Be9ADB657076AcD8954cB;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 public constant BUY_AMOUNT = 1000e6; // 1k USDC

    // ============ Protocol Types ============

    enum ProtocolType {
        Aave,
        Compound,
        Morpho,
        Fluid
    }

    // ============ API Instruments ============

    struct ApiInstrument {
        string description;
        ProtocolType protocolType;
        address executionAddress; // Aave=Pool, Compound=Comet, Morpho=Vault
        address tokenAddress; // underlying token
        address expectedAdapter;
        address expectedYieldToken;
    }

    ApiInstrument[] internal apiInstruments;

    function setUp() public {
        string memory rpcUrl = vm.envString("ARBITRUM_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Upgrade ROUTER to latest fee-enabled implementation
        address owner = ROUTER.owner();
        SwapDepositRouter newImpl = new SwapDepositRouter();
        vm.prank(owner);
        ROUTER.upgradeToAndCall(address(newImpl), "");

        // Enable fee to ensure it doesn't break cross-chain buyFor
        vm.prank(owner);
        ROUTER.setFeeConfig(50, makeAddr("feeRecipient")); // 0.5% fee

        // Morpho - Clearstar High Yield USDC (CSHYUSDC)
        apiInstruments.push(
            ApiInstrument({
                description: "Morpho Clearstar High Yield USDC",
                protocolType: ProtocolType.Morpho,
                executionAddress: 0x64CA76e2525fc6Ab2179300c15e343d73e42f958,
                tokenAddress: USDC,
                expectedAdapter: 0x61040AdE942611008c9Bc4da89735bE536eafFCe,
                expectedYieldToken: 0x64CA76e2525fc6Ab2179300c15e343d73e42f958
            })
        );

        // Morpho - Hyperithm USDC (HYPERUSDC)
        apiInstruments.push(
            ApiInstrument({
                description: "Morpho Hyperithm USDC",
                protocolType: ProtocolType.Morpho,
                executionAddress: 0x4B6F1C9E5d470b97181786b26da0d0945A7cf027,
                tokenAddress: USDC,
                expectedAdapter: 0x61040AdE942611008c9Bc4da89735bE536eafFCe,
                expectedYieldToken: 0x4B6F1C9E5d470b97181786b26da0d0945A7cf027
            })
        );

        // Morpho - Steakhouse Prime USDC (steakUSDC)
        apiInstruments.push(
            ApiInstrument({
                description: "Morpho Steakhouse Prime USDC",
                protocolType: ProtocolType.Morpho,
                executionAddress: 0x250CF7c82bAc7cB6cf899b6052979d4B5BA1f9ca,
                tokenAddress: USDC,
                expectedAdapter: 0x61040AdE942611008c9Bc4da89735bE536eafFCe,
                expectedYieldToken: 0x250CF7c82bAc7cB6cf899b6052979d4B5BA1f9ca
            })
        );

        // Morpho - Clearstar USDC Reactor (CSUSDC)
        apiInstruments.push(
            ApiInstrument({
                description: "Morpho Clearstar USDC Reactor",
                protocolType: ProtocolType.Morpho,
                executionAddress: 0xa53Cf822FE93002aEaE16d395CD823Ece161a6AC,
                tokenAddress: USDC,
                expectedAdapter: 0x61040AdE942611008c9Bc4da89735bE536eafFCe,
                expectedYieldToken: 0xa53Cf822FE93002aEaE16d395CD823Ece161a6AC
            })
        );

        // Morpho - Gauntlet USDC Core (GTUSDCC)
        apiInstruments.push(
            ApiInstrument({
                description: "Morpho Gauntlet USDC Core",
                protocolType: ProtocolType.Morpho,
                executionAddress: 0x7e97fa6893871A2751B5fE961978DCCb2c201E65,
                tokenAddress: USDC,
                expectedAdapter: 0x61040AdE942611008c9Bc4da89735bE536eafFCe,
                expectedYieldToken: 0x7e97fa6893871A2751B5fE961978DCCb2c201E65
            })
        );

        // Morpho - Steakhouse High Yield USDC (BBQUSDC)
        apiInstruments.push(
            ApiInstrument({
                description: "Morpho Steakhouse High Yield USDC",
                protocolType: ProtocolType.Morpho,
                executionAddress: 0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA,
                tokenAddress: USDC,
                expectedAdapter: 0x61040AdE942611008c9Bc4da89735bE536eafFCe,
                expectedYieldToken: 0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA
            })
        );

        // Aave - USDC (aUSDC)
        apiInstruments.push(
            ApiInstrument({
                description: "Aave V3 USDC",
                protocolType: ProtocolType.Aave,
                executionAddress: 0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                tokenAddress: USDC,
                expectedAdapter: 0xA734BdbBde76B8de92F2955c44583b1A851BA892,
                expectedYieldToken: 0x724dc807b04555b71ed48a6896b6F41593b8C637
            })
        );
    }

    // ============ Instrument ID Computation ============

    function _computeInstrumentId(ApiInstrument memory inst) internal view returns (bytes32) {
        bytes32 marketId;
        if (inst.protocolType == ProtocolType.Morpho || inst.protocolType == ProtocolType.Fluid) {
            // Vault-based: marketId = vault address cast to bytes32
            marketId = bytes32(uint256(uint160(inst.executionAddress)));
        } else {
            // Aave/Compound: marketId = keccak256(abi.encode(currency))
            marketId = keccak256(abi.encode(Currency.wrap(inst.tokenAddress)));
        }
        return InstrumentIdLib.generateInstrumentId(block.chainid, inst.executionAddress, marketId);
    }

    // ============ Registration Tests ============

    function test_fork_arb_api_allInstrumentsRegistered() public view {
        for (uint256 i = 0; i < apiInstruments.length; i++) {
            ApiInstrument memory inst = apiInstruments[i];
            bytes32 instrumentId = _computeInstrumentId(inst);
            bool registered = REGISTRY.isInstrumentRegistered(instrumentId);
            assertTrue(registered, string.concat("Not registered: ", inst.description));
        }
    }

    function test_fork_arb_api_allInstrumentsHaveCorrectAdapter() public view {
        for (uint256 i = 0; i < apiInstruments.length; i++) {
            ApiInstrument memory inst = apiInstruments[i];
            bytes32 instrumentId = _computeInstrumentId(inst);
            (address adapter,) = REGISTRY.getInstrumentDirect(instrumentId);
            assertEq(adapter, inst.expectedAdapter, string.concat("Wrong adapter: ", inst.description));
        }
    }

    function test_fork_arb_api_allInstrumentsHaveCorrectYieldToken() public view {
        for (uint256 i = 0; i < apiInstruments.length; i++) {
            ApiInstrument memory inst = apiInstruments[i];
            bytes32 instrumentId = _computeInstrumentId(inst);
            (address adapter, bytes32 marketId) = REGISTRY.getInstrumentDirect(instrumentId);
            address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);
            assertEq(yieldToken, inst.expectedYieldToken, string.concat("Wrong yield token: ", inst.description));
        }
    }

    // ============ buyFor Tests ============

    function test_fork_arb_api_buyFor_morphoClearstarHighYield() public {
        _testBuyFor(apiInstruments[0]);
    }

    function test_fork_arb_api_buyFor_morphoHyperithm() public {
        _testBuyFor(apiInstruments[1]);
    }

    function test_fork_arb_api_buyFor_morphoSteakhousePrime() public {
        _testBuyFor(apiInstruments[2]);
    }

    function test_fork_arb_api_buyFor_morphoClearstarReactor() public {
        _testBuyFor(apiInstruments[3]);
    }

    function test_fork_arb_api_buyFor_morphoGauntletCore() public {
        _testBuyFor(apiInstruments[4]);
    }

    function test_fork_arb_api_buyFor_morphoSteakhouseHighYield() public {
        _testBuyFor(apiInstruments[5]);
    }

    function test_fork_arb_api_buyFor_aaveUsdc() public {
        _testBuyFor(apiInstruments[6]);
    }

    // ============ Internal ============

    function _testBuyFor(ApiInstrument memory inst) internal {
        bytes32 instrumentId = _computeInstrumentId(inst);
        address recipient = makeAddr(string.concat("recipient-", inst.description));

        // Deal USDC to the cctpReceiver (buyFor pulls from msg.sender)
        deal(USDC, CCTP_RECEIVER, BUY_AMOUNT);

        // Approve router to spend cctpReceiver's USDC
        vm.prank(CCTP_RECEIVER);
        IERC20(USDC).approve(address(ROUTER), BUY_AMOUNT);

        // Execute buyFor as the cctpReceiver
        vm.prank(CCTP_RECEIVER);
        uint256 deposited = ROUTER.buyFor(instrumentId, BUY_AMOUNT, recipient);

        // Verify deposit succeeded
        assertEq(deposited, BUY_AMOUNT, string.concat("Deposited != input for ", inst.description));

        // Verify recipient received yield tokens
        (address adapter, bytes32 marketId) = REGISTRY.getInstrumentDirect(instrumentId);
        address yieldToken = ILendingAdapter(adapter).getYieldToken(marketId);
        uint256 yieldBalance = IERC20(yieldToken).balanceOf(recipient);
        assertGt(yieldBalance, 0, string.concat("No yield tokens for ", inst.description));

        // Verify no USDC left in router
        assertEq(IERC20(USDC).balanceOf(address(ROUTER)), 0, "Router should not hold USDC");
    }
}
