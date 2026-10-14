// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeodesReputationRegistry} from "../src/DeodesReputationRegistry.sol";

/// @notice Deploys DeodesReputationRegistry (V1, UNIFIED-PLAN 1.6). No env
///         needed: the deployer becomes owner, then hands recorders to circle
///         contracts (setRecorder) and ownership to the governance timelock at
///         the 1.7/1.11 ceremony. Use a FRESH deployer key per network
///         (see MAINNET-INCIDENT-REPORT.md).
///   export RPC_URL=https://rpc.testnet.arc.io
/// Run (key stays in YOUR terminal only, never share it):
///   forge script script/DeployReputation.s.sol --rpc-url $RPC_URL --broadcast
/// Then record address/tx/block in deployments.{testnet,mainnet}.json and verify:
///   forge verify-contract <address> src/DeodesReputationRegistry.sol:DeodesReputationRegistry \
///     --chain-id <5042002|5042> --compiler-version v0.8.36
contract DeployReputation is Script {
    function run() external returns (DeodesReputationRegistry registry) {
        vm.startBroadcast();
        registry = new DeodesReputationRegistry();
        vm.stopBroadcast();
    }
}
