// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeodesTreasury} from "../src/DeodesTreasury.sol";
import {DeoToken} from "../src/DeoToken.sol";
import {DeodesReputationRegistry} from "../src/DeodesReputationRegistry.sol";
import {DeodesFactory} from "../src/DeodesFactory.sol";
import {DeodesGovernance} from "../src/DeodesGovernance.sol";

/// @notice Single-transaction-order V1 deploy (UNIFIED-PLAN 1.11): treasury ->
///         token -> registry -> factory(protocolTreasury) -> gov(token,
///         treasury). Owners stay with the deployer; the CEREMONY.md handover
///         moves them to the multisig in separate, auditable txs (never woven
///         into the deploy — a failed handover must not block deployment).
///         Use a FRESH deployer key per network (MAINNET-INCIDENT-REPORT.md).
///   export RPC_URL=https://rpc.testnet.arc.io   # or mainnet (2 operators!)
/// Run (key stays in YOUR terminal only):
///   forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --account <name>
contract DeployAll is Script {
    function run() external {
        vm.startBroadcast();
        DeodesTreasury treasury = new DeodesTreasury();
        DeoToken token = new DeoToken();
        DeodesReputationRegistry registry = new DeodesReputationRegistry();
        DeodesFactory factory = new DeodesFactory(address(treasury));
        DeodesGovernance gov = new DeodesGovernance(token, address(treasury));
        vm.stopBroadcast();

        console.log("treasury:  %s", address(treasury));
        console.log("token:     %s", address(token));
        console.log("registry:  %s", address(registry));
        console.log("factory:   %s", address(factory));
        console.log("gov:       %s", address(gov));
        console.log("owner-all: <deployer> -> handover per CEREMONY.md");
    }
}
