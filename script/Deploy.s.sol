// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentTreasury.sol";

contract DeployScript is Script {
    // Ethereum Mainnet
    address constant STETH_MAINNET = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH_MAINNET = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // Holesky Testnet
    address constant STETH_HOLESKY = 0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034;
    address constant WSTETH_HOLESKY = 0x8d09a4502Cc8Cf1547aD300E066060D043f6982D;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address agent = vm.envAddress("AGENT_ADDRESS");
        uint256 perTxCap = vm.envOr("PER_TX_CAP", uint256(0.1 ether));
        uint256 timeWindow = vm.envOr("TIME_WINDOW", uint256(1 hours));

        // Detect chain
        address stethAddr;
        address wstethAddr;
        if (block.chainid == 1) {
            stethAddr = STETH_MAINNET;
            wstethAddr = WSTETH_MAINNET;
        } else if (block.chainid == 17000) {
            stethAddr = STETH_HOLESKY;
            wstethAddr = WSTETH_HOLESKY;
        } else {
            revert("Unsupported chain - use Ethereum mainnet or Holesky testnet");
        }

        vm.startBroadcast(deployerPrivateKey);

        AgentTreasury treasury = new AgentTreasury(
            stethAddr,
            wstethAddr,
            agent,
            perTxCap,
            timeWindow
        );

        console.log("AgentTreasury deployed at:", address(treasury));
        console.log("  stETH:", stethAddr);
        console.log("  wstETH:", wstethAddr);
        console.log("  agent:", agent);
        console.log("  perTxCap:", perTxCap);
        console.log("  timeWindow:", timeWindow);

        vm.stopBroadcast();
    }
}
