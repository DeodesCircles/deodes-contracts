// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeoToken} from "../src/DeoToken.sol";

/// @notice Deploys DeoToken (V1, UNIFIED-PLAN 1.7). No env needed: the
///         deployer becomes owner (mint/ownership move to the governance
///         timelock at the 1.11 ceremony). Use a FRESH deployer key per
///         network (see MAINNET-INCIDENT-REPORT.md).
///   export RPC_URL=https://rpc.testnet.arc.io
/// Run (key stays in YOUR terminal only, never share it):
///   forge script script/DeployDeoToken.s.sol --rpc-url $RPC_URL --broadcast
/// Then record address/tx/block in deployments.{testnet,mainnet}.json and verify:
///   forge verify-contract <address> src/DeoToken.sol:DeoToken \
///     --chain-id <5042002|5042> --compiler-version v0.8.36
contract DeployDeoToken is Script {
    function run() external returns (DeoToken token) {
        vm.startBroadcast();
        token = new DeoToken();
        vm.stopBroadcast();
    }
}
