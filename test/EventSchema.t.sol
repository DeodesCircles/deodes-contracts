// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeodesFactory} from "../src/DeodesFactory.sol";

/// @notice Event-schema freeze test (UNIFIED-PLAN 1.9). Reads the COMPILED
///         artifact (out/IDeodesEvents.sol/IDeodesEvents.json), rebuilds each
///         event signature from name + input types, and compares its topic0
///         against the frozen table below. Editing, reordering, adding, or
///         removing an event breaks this test ON PURPOSE — signature changes
///         break the 2.6 decoder, so they require a new UNIFIED-PLAN subphase
///         (see EVENTS.md freeze policy), never a silent edit.
///         Also proves the factory emits the canonical CircleCreated topic.
contract EventSchemaTest is Test {
    using stdJson for string;

    // Frozen topic0 table (keccak of canonical signatures; see EVENTS.md).
    bytes32 internal constant T_CIRCLE_CREATED = 0xd8d91ef7205e69709b41b7d04828958b77ad420e3ddb36ce51b7e94c3b08d849;
    bytes32 internal constant T_MEMBER_JOINED = 0xb168e0b33ed126dec210fb14910d562a068905fb3431f3abe71b964e9e1b119a;
    bytes32 internal constant T_CONTRIBUTION_RECEIVED =
        0xe482e8d853bcf23b76d7656a12af7c09cc6820a4683d6c48851261c2b12323b3;
    bytes32 internal constant T_PAYOUT_EXECUTED =
        0x102ce461c824a1021c2d1b210c32a2de5a8de51f34656b969bf730d789112b48;
    bytes32 internal constant T_FEE_DEPOSITED =
        0x652893d29fd820a4f183b65e6138f2125655352c510e215ab9202d37bd46a4d1;
    bytes32 internal constant T_LATE_REPORTED =
        0x8f4c79b46096b24b40a91ce1ceee1a5cb49a95097169dcba1bc29f5da4a0b720;
    bytes32 internal constant T_MEMBER_EXITED =
        0x13288d7c0173c1a97d8f96fd51acbf5c8f75d23842d1f10cbd9467a161a2aff0;
    bytes32 internal constant T_DEFAULT_RECORDED =
        0x491fa318f3afc51cef0ae824155bf6ca98185dd902f3f4e5e4151db171a21bf7;
    bytes32 internal constant T_CIRCLE_COMPLETED =
        0xd645cee42742598a5aca6bccb4ce7d99cc931dfb44fe244f318f6868e285897e;
    bytes32 internal constant T_AUCTION_BID =
        0x84fd05b88be83fc762b7bb54dc94b107b11b2bd82db6f2d29cf4fc78929877de;
    bytes32 internal constant T_VOTE_CAST =
        0xcc194f214df029fe546c9959ee15d79d8633742aab6c02a862e337f8ace3d550;
    bytes32 internal constant T_DISPUTE_RAISED =
        0xe64f7ad65d89337c4a8e0a184107b60e148188a40b245de26ff7881762f111e8;

    string internal _artifact;

    function setUp() public {
        _artifact = vm.readFile("out/IDeodesEvents.sol/IDeodesEvents.json");
    }

    function test_SchemaFrozen() public view {
        // Artifact ABI is alphabetical, NOT declaration order — match by
        // name. Exactly twelve entries: index 12 must not exist. (Fewer than
        // twelve fails inside the per-name scan.)
        _assertEventByName("CircleCreated", T_CIRCLE_CREATED, 6);
        _assertEventByName("MemberJoined", T_MEMBER_JOINED, 2);
        _assertEventByName("ContributionReceived", T_CONTRIBUTION_RECEIVED, 3);
        _assertEventByName("PayoutExecuted", T_PAYOUT_EXECUTED, 4);
        _assertEventByName("FeeDeposited", T_FEE_DEPOSITED, 3);
        _assertEventByName("LateReported", T_LATE_REPORTED, 3);
        _assertEventByName("MemberExited", T_MEMBER_EXITED, 2);
        _assertEventByName("DefaultRecorded", T_DEFAULT_RECORDED, 2);
        _assertEventByName("CircleCompleted", T_CIRCLE_COMPLETED, 2);
        _assertEventByName("AuctionBid", T_AUCTION_BID, 4);
        _assertEventByName("VoteCast", T_VOTE_CAST, 3);
        _assertEventByName("DisputeRaised", T_DISPUTE_RAISED, 3);
        try this._nameAt(12) {
            revert("schema grew without freeze update");
        } catch {}
    }

    function test_FactoryEmitsCanonicalTopic() public {
        DeodesFactory factory = new DeodesFactory(makeAddr("treasury"));
        vm.recordLogs();
        vm.prank(makeAddr("organizer"));
        factory.createCircle(address(0), 10 ether, 5);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == T_CIRCLE_CREATED) {
                found = true;
                break;
            }
        }
        assertTrue(found, "factory emits the frozen canonical CircleCreated topic");
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _nameAt(uint256 idx) external view returns (string memory) {
        return _artifact.readString(
            string.concat(".abi[", vm.toString(idx), "].name")
        );
    }

    /// @dev Finds the event by NAME (artifact order is alphabetical and must
    ///      not be relied on), rebuilds `name(t0,t1,…)` from recorded input
    ///      types, and compares topic0 against the frozen constant.
    function _assertEventByName(string memory expName, bytes32 frozen, uint256 nInputs)
        internal
        view
    {
        bytes32 want = keccak256(bytes(expName));
        for (uint256 idx = 0; idx < 12; idx++) {
            string memory base = string.concat(".abi[", vm.toString(idx), "]");
            string memory name =
                _artifact.readString(string.concat(base, ".name"));
            if (keccak256(bytes(name)) != want) continue;
            assertEq(_artifact.readString(string.concat(base, ".type")), "event");
            string memory sig = string.concat(expName, "(");
            for (uint256 i = 0; i < nInputs; i++) {
                string memory ibase =
                    string.concat(base, ".inputs[", vm.toString(i), "].type");
                sig = string.concat(sig, _artifact.readString(ibase));
                if (i + 1 < nInputs) sig = string.concat(sig, ",");
            }
            sig = string.concat(sig, ")");
            assertEq(
                keccak256(bytes(sig)), frozen, "event signature changed: freeze update required"
            );
            return;
        }
        revert(string.concat("event missing from artifact: ", expName));
    }
}
