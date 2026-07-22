// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterProxyLib} from "../../utils/AdapterProxyLib.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @title EulerEarnVaultsForkTest
/// @notice Fork tests for the newly-added Euler Earn USDC vaults on Base.
/// @dev Vault addresses are read from `script/config/NetworkConfig.json` (source of truth for
///      on-chain registration via `script/RegisterInstruments.s.sol`). Each vault is registered
///      on a freshly-deployed EulerAdapter and exercised end-to-end: deposit then full withdraw.
///
///      Pinned to a recent Base block because these vaults were deployed after the block used by
///      the shared {AdapterForkTestBase} (44_730_000). Do NOT bump the shared base block.
///
///      Run: BASE_RPC_URL=... forge test --mc EulerEarnVaultsForkTest -vv
contract EulerEarnVaultsForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 48_900_000;
    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";
    string internal constant VAULTS_PATH = ".networks.baseMainnet.protocols.eulerEarn.vaults.";

    EulerAdapter internal adapter;
    string internal json;
    address internal user;
    address internal recipient;

    /// @dev Config keys (under baseMainnet.protocols.eulerEarn.vaults) for the new USDC vaults.
    string[] internal vaultKeys = ["clearstarEarnUSDC"];

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        json = vm.readFile(CONFIG_PATH);

        adapter = AdapterProxyLib.deployEuler(address(this));
        adapter.setAuthorizedCaller(address(this), true);

        user = makeAddr("eeUser");
        recipient = makeAddr("eeRecipient");
    }

    function _vault(string memory key) internal view returns (address) {
        return json.readAddress(string.concat(VAULTS_PATH, key));
    }

    /// @notice Registers a vault, deposits its underlying, then withdraws all shares.
    function _depositWithdraw(string memory key) internal {
        address vault = _vault(key);
        address token = IERC4626(vault).asset();
        uint256 amount = 1000 * (10 ** IERC20Metadata(token).decimals());
        bytes32 marketId = bytes32(uint256(uint160(vault)));

        adapter.registerVault(Currency.wrap(token), vault);

        // Deposit
        deal(token, user, amount);
        vm.prank(user);
        IERC20(token).approve(address(adapter), amount);
        vm.prank(user);
        adapter.deposit(marketId, amount, user);

        uint256 shares = IERC4626(vault).balanceOf(user);
        assertGt(shares, 0, string.concat("no shares minted: ", key));

        // Withdraw (adapter holds the shares, redeems to recipient)
        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shares);
        uint256 withdrawn = adapter.withdraw(marketId, shares, recipient);

        // Allow 1% slippage for rounding / vault fees
        assertGe(withdrawn, (amount * 99) / 100, string.concat("withdrawn too low: ", key));
        assertGe(IERC20(token).balanceOf(recipient), (amount * 99) / 100, string.concat("recipient short: ", key));
    }

    /// @notice One aggregate test that exercises every new Euler Earn vault. Fails naming the
    ///         first vault that cannot round-trip a deposit/withdraw.
    function test_fork_base_eulerEarn_allVaults_depositWithdraw() public {
        for (uint256 i = 0; i < vaultKeys.length; i++) {
            _depositWithdraw(vaultKeys[i]);
        }
    }
}
