// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeodesCircle} from "../src/DeodesCircle.sol";

/// @notice Deploys DeodesCircle. Set env first (NEVER commit real values):
///   export TREASURY=0xYourWallet
///   export CONTRIBUTION_WEI=10000000000000000000   # 10 USDC (18 decimals)
///   export MAX_MEMBERS=5
///   export RPC_URL=https://rpc.testnet.arc.io    # testnet first!
/// Run (key stays in YOUR terminal only, never share it):
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
/// forge will prompt for the private key with --account or use --private-key.
contract Deploy is Script {
    function run() external returns (DeodesCircle circle) {
        address treasury = vm.envAddress("TREASURY");
        uint256 contribution = vm.envUint("CONTRIBUTION_WEI");
        uint256 maxMembers = vm.envUint("MAX_MEMBERS");
        vm.startBroadcast();
        circle = new DeodesCircle(treasury, contribution, maxMembers);
        vm.stopBroadcast();
    }
}
