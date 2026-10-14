// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeodesTreasury} from "../src/DeodesTreasury.sol";

/// @notice Deploys DeodesTreasury (V1, UNIFIED-PLAN 1.5). No env needed: the
///         deployer becomes owner, then transfers ownership to the governance
///         timelock at the 1.7/1.11 ceremony. Use a FRESH deployer key per
///         network (see MAINNET-INCIDENT-REPORT.md).
///   export RPC_URL=https://rpc.testnet.arc.io
/// Run (key stays in YOUR terminal only, never share it):
///   forge script script/DeployTreasury.s.sol --rpc-url $RPC_URL --broadcast
/// Then record address/tx/block in deployments.{testnet,mainnet}.json and verify:
///   forge verify-contract <address> src/DeodesTreasury.sol:DeodesTreasury \
///     --chain-id <5042002|5042> --compiler-version v0.8.36
/// Post-deploy (timelock live): transferOwnership(<timelock>) from the
/// deployer and record the tx hash in the ceremony log.
contract DeployTreasury is Script {
    function run() external returns (DeodesTreasury vault) {
        vm.startBroadcast();
        vault = new DeodesTreasury();
        vm.stopBroadcast();
    }
}
