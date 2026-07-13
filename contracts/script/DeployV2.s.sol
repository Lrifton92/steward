// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PolicyVault} from "../src/PolicyVault.sol";
import {FxDesk} from "../src/FxDesk.sol";

/// Deploys FxDesk + PolicyVault v2 fully wired, then hands the vault to OWNER_ADDRESS.
/// The desk stays owned by the deployer (agent burner) so the agent-side tooling can
/// refresh the posted FX rate on testnet.
contract DeployV2 is Script {
    function run() external {
        address agent = vm.envAddress("AGENT_ADDRESS");
        address finalOwner = vm.envAddress("OWNER_ADDRESS");
        address usdc = vm.envAddress("USDC");
        address eurc = vm.envAddress("EURC");
        address escrow = vm.envAddress("FX_ESCROW");

        vm.startBroadcast();
        FxDesk desk = new FxDesk(usdc, eurc);
        desk.setRate(855000); // 0.855 EURC/USDC, rafraîchi ensuite par l'agent

        PolicyVault vault = new PolicyVault(agent);
        vault.setToken(usdc, true);
        vault.setToken(eurc, true);
        vault.setTarget(address(desk), true);
        vault.setTarget(escrow, true); // StableFX branchable si accès accordé
        vault.setDailyCap(usdc, 50e6);
        vault.setDailyCap(eurc, 50e6);
        vault.setOwner(finalOwner);
        vm.stopBroadcast();

        console.log("FxDesk:", address(desk));
        console.log("PolicyVault v2:", address(vault));
    }
}
