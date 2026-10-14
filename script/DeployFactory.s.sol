// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeodesFactory} from "../src/DeodesFactory.sol";

/// @notice Deploys DeodesFactory (V1, UNIFIED-PLAN 1.4/1.11). Set env first
///         (NEVER commit real values). Use a FRESH deployer key per network —
///         reusing one key at the same nonce on two chains yields the same
///         address (see MAINNET-INCIDENT-REPORT.md).
///   export PROTOCOL_TREASURY=0xYourFeeVault   # MUST differ from keeper escrow
///   export RPC_URL=https://rpc.testnet.arc.io
/// Run (key stays in YOUR terminal only, never share it):
///   forge script script/DeployFactory.s.sol --rpc-url $RPC_URL --broadcast
/// Then record address/tx/block in deployments.{testnet,mainnet}.json and verify:
///   forge verify-contract <address> src/DeodesFactory.sol:DeodesFactory \
///     --chain-id <5042002|5042> --compiler-version v0.8.36 \
///     --constructor-args $(cast abi-encode "constructor(address)" $PROTOCOL_TREASURY)
contract DeployFactory is Script {
    function run() external returns (DeodesFactory factory) {
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        vm.startBroadcast();
        factory = new DeodesFactory(treasury);
        vm.stopBroadcast();
    }
}
