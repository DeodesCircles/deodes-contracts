// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeodesCircle} from "../src/DeodesCircle.sol";

/// @notice V0 test suite (UNIFIED-PLAN 1.1): join / contribute / payout,
///         fee math pool*50/10000, AlreadyPaid / RotationComplete, and the
///         paidCount <= memberCount invariant.
contract DeodesCircleTest is Test {
    using stdJson for string;

    uint256 internal constant CONTRIBUTION = 10 ether; // 10 USDC, 18 dec
    uint256 internal constant MAX_MEMBERS = 5;

    address internal treasury = makeAddr("treasury");
    DeodesCircle internal circle;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        circle = new DeodesCircle(treasury, CONTRIBUTION, MAX_MEMBERS);
    }

    // ── join ─────────────────────────────────────────────────────────────

    function test_JoinExactSucceeds() public {
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        circle.join{value: CONTRIBUTION}();
        assertTrue(circle.isMember(alice));
        assertEq(circle.memberCount(), 1);
        assertEq(address(circle).balance, CONTRIBUTION);
    }

    function test_JoinWrongAmountReverts() public {
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        vm.expectRevert(DeodesCircle.WrongContribution.selector);
        circle.join{value: CONTRIBUTION - 1}();
    }

    function test_JoinTwiceReverts() public {
        deal(alice, 2 * CONTRIBUTION);
        vm.startPrank(alice);
        circle.join{value: CONTRIBUTION}();
        vm.expectRevert(DeodesCircle.AlreadyMember.selector);
        circle.join{value: CONTRIBUTION}();
        vm.stopPrank();
    }

    function test_JoinBeyondMaxReverts() public {
        for (uint256 i = 0; i < MAX_MEMBERS; i++) {
            address m = makeAddr(string(abi.encodePacked("member", i)));
            deal(m, CONTRIBUTION);
            vm.prank(m);
            circle.join{value: CONTRIBUTION}();
        }
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        vm.expectRevert(DeodesCircle.CircleFull.selector);
        circle.join{value: CONTRIBUTION}();
    }

    // ── contribute ───────────────────────────────────────────────────────

    function test_ContributeNonMemberReverts() public {
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        vm.expectRevert(DeodesCircle.NotMember.selector);
        circle.contribute{value: CONTRIBUTION}();
    }

    function test_ContributeWrongAmountReverts() public {
        _join(alice);
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        vm.expectRevert(DeodesCircle.WrongContribution.selector);
        circle.contribute{value: CONTRIBUTION - 1}();
    }

    function test_ContributeExactAccumulates() public {
        _join(alice);
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        circle.contribute{value: CONTRIBUTION}();
        assertEq(address(circle).balance, 2 * CONTRIBUTION);
    }

    // ── payout ───────────────────────────────────────────────────────────

    function test_PayoutNonMemberReverts() public {
        _join(alice);
        vm.expectRevert(DeodesCircle.NotMember.selector);
        circle.payout(bob);
    }

    function test_PayoutSplitsFeeAndNet() public {
        _join(alice);
        _join(bob);
        // Pool = 2 contributions. Anyone may trigger.
        uint256 pool = address(circle).balance;
        uint256 fee = (pool * 50) / 10_000;
        uint256 net = pool - fee;

        uint256 treasuryBefore = treasury.balance;
        uint256 bobBefore = bob.balance;

        circle.payout(bob);

        assertEq(treasury.balance, treasuryBefore + fee, "treasury gets 0.5%");
        assertEq(bob.balance, bobBefore + net, "recipient gets pool minus fee");
        assertTrue(circle.hasBeenPaid(bob));
        assertEq(circle.paidCount(), 1);
        assertEq(circle.totalCollected(), 0, "cycle total resets");
        assertEq(address(circle).balance, 0, "pool drained");
    }

    function test_PayoutTwiceToSameMemberReverts() public {
        _join(alice);
        _join(bob);
        circle.payout(bob);
        // Refill so the second attempt reaches the AlreadyPaid check.
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        circle.contribute{value: CONTRIBUTION}();
        vm.expectRevert(DeodesCircle.AlreadyPaid.selector);
        circle.payout(bob);
    }

    function test_PayoutPaidMemberAfterFullRotationReverts() public {
        _join(alice);
        _join(bob);
        circle.payout(alice);
        // Refill for the second leg of the rotation.
        deal(bob, CONTRIBUTION);
        vm.prank(bob);
        circle.contribute{value: CONTRIBUTION}();
        circle.payout(bob);

        assertEq(circle.paidCount(), circle.memberCount());
        // Check order in payout(): NotMember -> AlreadyPaid -> RotationComplete,
        // so a paid member reverts AlreadyPaid even at full rotation.
        // NOTE (audit): RotationComplete is unreachable while members.length
        // only grows — paidCount (paid members) can never exceed length, and
        // any unpaid member passes the first two checks with paidCount < length.
        // It is defense-in-depth, not a live branch.
        vm.expectRevert(DeodesCircle.AlreadyPaid.selector);
        circle.payout(alice);
    }

    function test_RotationContinuesAsNewMembersJoin() public {
        _join(alice);
        _join(bob);
        circle.payout(alice);
        deal(bob, CONTRIBUTION);
        vm.prank(bob);
        circle.contribute{value: CONTRIBUTION}();
        circle.payout(bob);
        assertEq(circle.paidCount(), circle.memberCount());

        // A member joining after a full rotation can still be paid.
        address dave = makeAddr("dave");
        _join(dave);
        assertEq(circle.unpaidCount(), 1);
        circle.payout(dave);
        assertEq(circle.paidCount(), circle.memberCount());
        assertLe(circle.paidCount(), circle.memberCount());
    }

    function test_PaidCountNeverExceedsMembers() public {
        _join(alice);
        _join(bob);
        _join(carol);
        address[3] memory order = [alice, bob, carol];
        for (uint256 i = 0; i < order.length; i++) {
            circle.payout(order[i]);
            assertLe(circle.paidCount(), circle.memberCount());
            if (i + 1 < order.length) {
                // Refill exactly one contribution for the next leg.
                deal(order[(i + 1) % order.length], CONTRIBUTION);
                vm.prank(order[(i + 1) % order.length]);
                circle.contribute{value: CONTRIBUTION}();
            }
        }
        assertEq(circle.unpaidCount(), 0);
    }

    // ── fee math (fuzz) ──────────────────────────────────────────────────

    /// @dev Mirrors the on-chain formula for arbitrary pools: fee is exactly
    ///      50 bps, fee + net reconstructs the pool (no dust leaks to fees).
    function testFuzz_FeeIs50Bps(uint256 pool) public pure {
        pool = bound(pool, 10_000, 1_000_000 ether);
        uint256 fee = (pool * 50) / 10_000;
        uint256 net = pool - fee;
        assertEq(fee + net, pool);
        // Integer division truncates: |fee*10000 - pool*50| < 10000 always
        // (remainder of a /10000 division), so tolerance is 10000, not 50.
        assertApproxEqAbs(fee * 10_000, pool * 50, 10_000);
    }

    function testFuzz_V0ContributionRoundTrip(uint256 n) public {
        n = bound(n, 1, MAX_MEMBERS);
        for (uint256 i = 0; i < n; i++) {
            address m = makeAddr(string(abi.encodePacked("fuzzmember", i)));
            _join(m);
        }
        assertEq(circle.memberCount(), n);
        assertEq(address(circle).balance, n * CONTRIBUTION);
    }

    // ── vectors file consistency (machine-checked, not eyeballed) ──────────

    /// @dev Pins test/vectors/fee-vectors.json to the on-chain formula:
    ///      every (pool, fee, net) case must satisfy fee = (pool*50)/10000
    ///      and fee + net = pool. The backend 2.8 tests consume the same
    ///      file, so drift here breaks both sides loudly.
    function test_FeeVectorsMatchFormula() public view {
        string memory json = vm.readFile("test/vectors/fee-vectors.json");
        // 14 cases (dust 0/1/199, step 200/201, round 10k, USDC-scale,
        // billions-scale).
        for (uint256 i = 0; i < 14; i++) {
            string memory base = string.concat(".cases[", vm.toString(i), "].");
            uint256 pool = json.readUint(string.concat(base, "pool"));
            uint256 fee = json.readUint(string.concat(base, "fee"));
            uint256 net = json.readUint(string.concat(base, "net"));
            assertEq(fee, (pool * 50) / 10_000, "fee drift");
            assertEq(fee + net, pool, "fee+net must reconstruct pool");
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _join(address m) internal {
        deal(m, CONTRIBUTION);
        vm.prank(m);
        circle.join{value: CONTRIBUTION}();
    }
}
