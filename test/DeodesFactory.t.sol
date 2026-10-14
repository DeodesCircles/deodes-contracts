// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeodesFactory} from "../src/DeodesFactory.sol";
import {DeodesCircle} from "../src/DeodesCircle.sol";

/// @notice Factory test suite (UNIFIED-PLAN 1.4): per-circle deploy uniqueness,
///         registry + pagination, treasury default vs override, bounds, access
///         control, organizer attribution.
contract DeodesFactoryTest is Test {
    uint256 internal constant CONTRIBUTION = 10 ether;
    uint256 internal constant MAX_MEMBERS = 5;

    address internal protocolTreasury = makeAddr("protocolTreasury");
    address internal organizer = makeAddr("organizer");
    DeodesFactory internal factory;

    event CircleCreated(
        address indexed circle,
        address indexed organizer,
        address treasury,
        uint256 contribution,
        uint256 maxMembers,
        uint256 index
    );

    function setUp() public {
        factory = new DeodesFactory(protocolTreasury);
    }

    // ── createCircle happy path ────────────────────────────────────────────

    function test_CreateCircleRegistersWithDefaultTreasury() public {
        vm.prank(organizer);
        // Zero address = use protocol default; event circle address unknown
        // ahead of time, so assert the non-indexed payload via recordLogs.
        vm.recordLogs();
        address circle = factory.createCircle(address(0), CONTRIBUTION, MAX_MEMBERS);
        assertTrue(circle != address(0), "deploys a real address");
        assertTrue(factory.isCircle(circle), "registered");
        assertEq(factory.circleOrganizer(circle), organizer, "human organizer recorded");
        assertEq(factory.circleCount(), 1);
        assertEq(factory.circleAt(0), circle);

        // Deployed circle carries the resolved params.
        DeodesCircle c = DeodesCircle(payable(circle));
        assertEq(c.treasury(), protocolTreasury);
        assertEq(c.contribution(), CONTRIBUTION);
        assertEq(c.maxMembers(), MAX_MEMBERS);
        // NOTE: V0 sets organizer = msg.sender at construction = the factory.
        assertEq(c.organizer(), address(factory));
    }

    function test_CreateCircleEmitsFullPayload() public {
        vm.recordLogs();
        vm.prank(organizer);
        address circle = factory.createCircle(address(0), CONTRIBUTION, MAX_MEMBERS);
        (bytes32[] memory topics, bytes memory data) =
            _findCircleCreatedEvent(vm.getRecordedLogs());
        assertEq(topics.length, 3, "sig + 2 indexed");
        assertEq(address(uint160(uint256(topics[1]))), circle, "indexed circle");
        assertEq(address(uint160(uint256(topics[2]))), organizer, "indexed organizer");
        (address treasury, uint256 contribution, uint256 maxMembers, uint256 index) =
            abi.decode(data, (address, uint256, uint256, uint256));
        assertEq(treasury, protocolTreasury);
        assertEq(contribution, CONTRIBUTION);
        assertEq(maxMembers, MAX_MEMBERS);
        assertEq(index, 0);
    }

    function test_CreateCircleTreasuryOverride() public {
        address custom = makeAddr("customTreasury");
        vm.prank(organizer);
        address circle = factory.createCircle(custom, CONTRIBUTION, MAX_MEMBERS);
        assertEq(DeodesCircle(payable(circle)).treasury(), custom);
    }

    // ── uniqueness (no address reuse) ──────────────────────────────────────

    function test_EachCreateDeploysUniqueAddress() public {
        address[3] memory created;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(organizer);
            created[i] = factory.createCircle(address(0), CONTRIBUTION, MAX_MEMBERS);
        }
        assertTrue(created[0] != created[1] && created[1] != created[2] && created[0] != created[2]);
        assertEq(factory.circleCount(), 3);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(factory.isCircle(created[i]));
            assertEq(factory.circleOrganizer(created[i]), organizer);
        }
    }

    function testFuzz_CreateCircleAlwaysUnique(uint8 n) public {
        n = uint8(bound(n, 1, 20));
        address prev = address(0);
        for (uint256 i = 0; i < n; i++) {
            address circle = factory.createCircle(address(0), CONTRIBUTION, MAX_MEMBERS);
            assertTrue(circle != address(0), "real deployment");
            assertTrue(circle != prev, "sequential CREATEs never repeat");
            assertTrue(factory.isCircle(circle), "registered");
            prev = circle;
        }
        assertEq(factory.circleCount(), n);
    }

    // ── validation ─────────────────────────────────────────────────────────

    function test_CreateCircleZeroContributionReverts() public {
        vm.prank(organizer);
        vm.expectRevert(DeodesFactory.ContributionRequired.selector);
        factory.createCircle(address(0), 0, MAX_MEMBERS);
    }

    function test_CreateCircleMemberBoundsReverts() public {
        vm.startPrank(organizer);
        vm.expectRevert(DeodesFactory.InvalidMemberBounds.selector);
        factory.createCircle(address(0), CONTRIBUTION, 1);
        vm.expectRevert(DeodesFactory.InvalidMemberBounds.selector);
        factory.createCircle(address(0), CONTRIBUTION, 101);
        vm.stopPrank();
    }

    function testFuzz_CreateCircleBoundsMirrorV0(uint256 contribution, uint256 maxMembers) public {
        contribution = bound(contribution, 1, 1_000_000 ether);
        maxMembers = bound(maxMembers, 2, 100);
        address circle = factory.createCircle(address(0), contribution, maxMembers);
        assertEq(DeodesCircle(payable(circle)).contribution(), contribution);
        assertEq(DeodesCircle(payable(circle)).maxMembers(), maxMembers);
    }

    // ── factory admin ──────────────────────────────────────────────────────

    function test_SetProtocolTreasuryOnlyOwner() public {
        address next = makeAddr("nextTreasury");
        vm.prank(organizer);
        vm.expectRevert(DeodesFactory.NotOwner.selector);
        factory.setProtocolTreasury(next);

        factory.setProtocolTreasury(next);
        assertEq(factory.protocolTreasury(), next);

        // Next circle uses the new default; already-deployed circles keep theirs.
        address before = factory.createCircle(address(0), CONTRIBUTION, MAX_MEMBERS);
        assertEq(DeodesCircle(payable(before)).treasury(), next);
    }

    function test_SetProtocolTreasuryZeroReverts() public {
        vm.expectRevert(DeodesFactory.TreasuryRequired.selector);
        factory.setProtocolTreasury(address(0));
    }

    function test_TransferOwnership() public {
        address next = makeAddr("nextOwner");
        factory.transferOwnership(next);
        assertEq(factory.owner(), next);
        vm.expectRevert(DeodesFactory.NotOwner.selector);
        factory.setProtocolTreasury(makeAddr("x"));
    }

    function test_ConstructorZeroTreasuryReverts() public {
        vm.expectRevert(DeodesFactory.TreasuryRequired.selector);
        new DeodesFactory(address(0));
    }

    // ── pagination ─────────────────────────────────────────────────────────

    function test_AllCirclesPaginates() public {
        for (uint256 i = 0; i < 5; i++) {
            factory.createCircle(address(0), CONTRIBUTION, MAX_MEMBERS);
        }
        address[] memory page = factory.allCircles(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], factory.circleAt(1));
        assertEq(page[1], factory.circleAt(2));

        // Clamped tail, empty page, zero limit — never revert.
        assertEq(factory.allCircles(4, 10).length, 1);
        assertEq(factory.allCircles(5, 10).length, 0);
        assertEq(factory.allCircles(99, 10).length, 0);
        assertEq(factory.allCircles(0, 0).length, 0);
        assertEq(factory.allCircles(0, 10).length, 5);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _findCircleCreatedEvent(Vm.Log[] memory logs)
        internal
        pure
        returns (bytes32[] memory topics, bytes memory data)
    {
        bytes32 sig = keccak256("CircleCreated(address,address,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                return (logs[i].topics, logs[i].data);
            }
        }
        revert("CircleCreated not emitted");
    }
}
