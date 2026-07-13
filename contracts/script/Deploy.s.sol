// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyVault} from "../src/PolicyVault.sol";

/// Deploys PolicyVault on Arc testnet and wires the initial policy.
/// env: AGENT_ADDRESS (agent signer), OWNER_ADDRESS (final owner, optional),
///      USDC, EURC, FX_ESCROW.
contract Deploy is Script {
    function run() external {
        address agent = vm.envAddress("AGENT_ADDRESS");
        address finalOwner = vm.envAddress("OWNER_ADDRESS");
        address usdc = vm.envAddress("USDC");
        address eurc = vm.envAddress("EURC");
        address escrow = vm.envAddress("FX_ESCROW");

        vm.startBroadcast();
        PolicyVault vault = new PolicyVault(agent);
        vault.setToken(usdc, true);
        vault.setToken(eurc, true);
        vault.setTarget(escrow, true);
        vault.setDailyCap(usdc, 50e6); // 50 USDC/day to start
        vault.setDailyCap(eurc, 50e6);
        vault.setOwner(finalOwner); // hand the vault to Soufian's wallet
        vm.stopBroadcast();

        console.log("PolicyVault:", address(vault));
    }
}
