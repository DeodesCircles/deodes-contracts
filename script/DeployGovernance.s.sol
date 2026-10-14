// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeoToken} from "../src/DeoToken.sol";
import {DeodesGovernance} from "../src/DeodesGovernance.sol";

/// @notice Deploys DeodesGovernance (V1, UNIFIED-PLAN 1.7) against an already
///         deployed DEO token + treasury. Set env first (NEVER commit values):
///   export DEO_TOKEN=0xDeoTokenAddress
///   export TREASURY=0xDeodesTreasuryAddress  # fee vault, NOT keeper escrow
///   export RPC_URL=https://rpc.testnet.arc.io
/// Run (key stays in YOUR terminal only, never share it):
///   forge script script/DeployGovernance.s.sol --rpc-url $RPC_URL --broadcast
/// Then record address/tx/block in deployments.{testnet,mainnet}.json and verify:
///   forge verify-contract <address> src/DeodesGovernance.sol:DeodesGovernance \
///     --chain-id <5042002|5042> --compiler-version v0.8.36 \
///     --constructor-args $(cast abi-encode "constructor(address,address)" $DEO_TOKEN $TREASURY)
/// Post-deploy (timelock live): transferOwnership(<timelock-or-multisig>) and
/// record the tx hash in the ceremony log.
contract DeployGovernance is Script {
    function run() external returns (DeodesGovernance gov) {
        address deo = vm.envAddress("DEO_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        vm.startBroadcast();
        gov = new DeodesGovernance(DeoToken(deo), treasury);
        vm.stopBroadcast();
    }
}
