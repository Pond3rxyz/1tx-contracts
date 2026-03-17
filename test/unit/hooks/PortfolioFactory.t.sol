// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseHookTest} from "../../utils/BaseHookTest.sol";
import {PortfolioFactory} from "../../../src/hooks/PortfolioFactory.sol";
import {PortfolioFactoryHelper} from "../../../src/hooks/PortfolioFactoryHelper.sol";
import {PortfolioHook} from "../../../src/hooks/PortfolioHook.sol";
import {PortfolioVault} from "../../../src/hooks/PortfolioVault.sol";
import {PortfolioStrategy} from "../../../src/hooks/PortfolioStrategy.sol";
import {IPortfolioStrategy} from "../../../src/interfaces/IPortfolioStrategy.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../../../src/registries/SwapPoolRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";

contract PortfolioFactoryTest is BaseHookTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PortfolioFactory public factory;
    PortfolioFactoryHelper public factoryHelper;
    PortfolioStrategy public strategy;
    InstrumentRegistry public instrumentRegistry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;
    MockAavePool public mockAavePool;

    MockERC20 public usdc;
    MockERC20 public aUsdc;
    Currency public usdcCurrency;

    bytes32 public usdcMarketId;
    bytes32 public usdcInstrumentId;

    address public owner;
    address public user;
    address public executionAddress;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        executionAddress = makeAddr("executionAddress");

        // Deploy real Uniswap V4 infrastructure
        deployArtifacts();

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        usdcCurrency = Currency.wrap(address(usdc));

        // Deploy registries
        InstrumentRegistry irImpl = new InstrumentRegistry();
        instrumentRegistry = InstrumentRegistry(
            address(
                new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, owner))
            )
        );

        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        swapPoolRegistry = SwapPoolRegistry(
            address(
                new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, owner))
            )
        );

        // Deploy Aave adapter + register instrument
        mockAavePool = new MockAavePool();
        mockAavePool.setReserveData(address(usdc), address(aUsdc));
        usdc.mint(address(mockAavePool), 1_000_000e6);

        aaveAdapter = new AaveAdapter(address(mockAavePool), owner);
        vm.prank(owner);
        aaveAdapter.registerMarket(usdcCurrency);

        usdcMarketId = keccak256(abi.encode(usdcCurrency));
        usdcInstrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, executionAddress, usdcMarketId);

        vm.prank(owner);
        instrumentRegistry.registerInstrument(executionAddress, usdcMarketId, address(aaveAdapter));

        // Deploy shared strategy (UUPS proxy)
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, owner)
                )
            )
        );

        // Authorize strategy on adapter
        vm.prank(owner);
        aaveAdapter.addAuthorizedCaller(address(strategy));

        // Deploy factory
        factory = new PortfolioFactory(poolManager, instrumentRegistry, swapPoolRegistry, IPortfolioStrategy(address(strategy)));

        // Deploy helper for address computation
        factoryHelper = new PortfolioFactoryHelper(
            address(factory), poolManager, instrumentRegistry, swapPoolRegistry, IPortfolioStrategy(address(strategy))
        );
    }

    // ============ Helpers ============

    function _buildAllocations() internal view returns (PortfolioVault.Allocation[] memory) {
        PortfolioVault.Allocation[] memory allocs = new PortfolioVault.Allocation[](1);
        allocs[0] = PortfolioVault.Allocation({instrumentId: usdcInstrumentId, weightBps: 10000});
        return allocs;
    }

    /// @dev Mines a hook salt that produces an address with flag bits 0xAC8
    function _mineSalt(address vault) internal view returns (bytes32) {
        bytes32 creationCodeHash = factoryHelper.getHookCreationCodeHash(PortfolioVault(vault), usdcCurrency);

        for (uint256 i = 0; i < 200_000; i++) {
            bytes32 salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, creationCodeHash));
            address hookAddr = address(uint160(uint256(hash)));
            if (uint160(hookAddr) & 0x3FFF == 0x0AC8) {
                return salt;
            }
        }
        revert("Could not mine salt");
    }

    /// @dev Computes vault address deterministically (mirrors factory logic)
    function _predictVaultAddress(string memory name, string memory symbol) internal view returns (address) {
        return factoryHelper.computeVaultAddress(address(this), name, symbol, usdcCurrency, _buildAllocations());
    }

    function _deployStrategy()
        internal
        returns (address vault, address hook, PoolId poolId)
    {
        string memory name = "Test Portfolio";
        string memory symbol = "tPORT";

        address predictedVault = _predictVaultAddress(name, symbol);
        bytes32 salt = _mineSalt(predictedVault);

        PortfolioFactory.DeployParams memory params = PortfolioFactory.DeployParams({
            initialOwner: owner,
            name: name,
            symbol: symbol,
            stable: usdcCurrency,
            allocations: _buildAllocations(),
            hookSalt: salt
        });

        (vault, hook, poolId) = factory.deploy(params);
    }

    // ============ Tests ============

    function test_deploy_createsVaultAndHook() public {
        (address vault, address hook,) = _deployStrategy();

        // Vault is a valid contract
        assertTrue(vault.code.length > 0, "Vault not deployed");
        assertTrue(hook.code.length > 0, "Hook not deployed");

        // Vault is ERC20 with correct metadata
        assertEq(PortfolioVault(vault).name(), "Test Portfolio");
        assertEq(PortfolioVault(vault).symbol(), "tPORT");
    }

    function test_deploy_initializesPool() public {
        (address vault, address hook, PoolId poolId) = _deployStrategy();

        // Pool exists and has a valid sqrtPriceX96
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool not initialized");
    }

    function test_deploy_vaultOwnershipTransferred() public {
        (address vault,,) = _deployStrategy();

        assertEq(PortfolioVault(vault).owner(), owner, "Owner not transferred");
    }

    function test_deploy_revertsOnBadSalt() public {
        string memory name = "Bad Salt Portfolio";
        string memory symbol = "BAD";

        PortfolioFactory.DeployParams memory params = PortfolioFactory.DeployParams({
            initialOwner: owner,
            name: name,
            symbol: symbol,
            stable: usdcCurrency,
            allocations: _buildAllocations(),
            hookSalt: bytes32(uint256(999999999)) // Almost certainly wrong flag bits
        });

        vm.expectRevert();
        factory.deploy(params);
    }

    function test_computeAddresses() public {
        string memory name = "Test Portfolio";
        string memory symbol = "tPORT";

        address predictedVault = _predictVaultAddress(name, symbol);

        // Deploy and verify vault matches prediction
        bytes32 salt = _mineSalt(predictedVault);

        PortfolioFactory.DeployParams memory params = PortfolioFactory.DeployParams({
            initialOwner: owner,
            name: name,
            symbol: symbol,
            stable: usdcCurrency,
            allocations: _buildAllocations(),
            hookSalt: salt
        });

        (address vault, address hook,) = factory.deploy(params);
        assertEq(vault, predictedVault, "Vault address mismatch");

        // Verify hook matches prediction
        address predictedHook = factoryHelper.computeHookAddress(PortfolioVault(vault), usdcCurrency, salt);
        assertEq(hook, predictedHook, "Hook address mismatch");
    }

    function test_deploy_vaultHookIsSet() public {
        (address vault, address hook,) = _deployStrategy();
        assertEq(PortfolioVault(vault).hook(), hook, "Hook not set on vault");
    }

    function test_deploy_emitsEvent() public {
        string memory name = "Test Portfolio";
        string memory symbol = "tPORT";
        address predictedVault = _predictVaultAddress(name, symbol);
        bytes32 salt = _mineSalt(predictedVault);

        PortfolioFactory.DeployParams memory params = PortfolioFactory.DeployParams({
            initialOwner: owner,
            name: name,
            symbol: symbol,
            stable: usdcCurrency,
            allocations: _buildAllocations(),
            hookSalt: salt
        });

        // We just check the event is emitted (can't predict poolId easily)
        vm.expectEmit(true, false, true, false);
        emit PortfolioFactory.StrategyDeployed(predictedVault, address(0), PoolId.wrap(bytes32(0)), owner, name, symbol);
        factory.deploy(params);
    }
}
