// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeoToken} from "../src/DeoToken.sol";
import {DeodesGovernance} from "../src/DeodesGovernance.sol";

/// @notice Governance tests (UNIFIED-PLAN 1.7): full lifecycle, snapshot
///         anti-flash-loan, deposit economics (refund/forfeit), cancel paths,
///         bounds, delegation-powered voting, quorum snapshot stability.
contract DeodesGovernanceTest is Test {
    DeoToken internal token;
    DeodesGovernance internal gov;
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant DEPOSIT = 100 ether; // default proposalDeposit

    function setUp() public {
        token = new DeoToken(); // owner = this test
        gov = new DeodesGovernance(token, treasury);
        // 1000 DEO electorate: alice 600 / bob 300 / carol 100.
        token.mint(alice, 600 ether);
        token.mint(bob, 300 ether);
        token.mint(carol, 100 ether);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _approve(address who) internal {
        vm.prank(who);
        token.approve(address(gov), DEPOSIT);
    }

    /// @dev Advance a block so the proposal snapshot block postdates all
    ///      setup checkpoints, then create, then advance one more block:
    ///      Compound-style snapshots revert for votes IN the creation block
    ///      (power "not yet determined"), so voting must happen strictly later.
    ///      Returns the proposal id.
    function _propose(address who, uint8 param, uint256 value) internal returns (uint256 id) {
        vm.roll(block.number + 1);
        _approve(who);
        vm.prank(who);
        id = gov.createProposal(param, value);
        vm.roll(block.number + 1);
    }

    function _voteFor(uint256 id, address who) internal {
        vm.prank(who);
        gov.castVote(id, true);
    }

    function _voteAgainst(uint256 id, address who) internal {
        vm.prank(who);
        gov.castVote(id, false);
    }

    function _closeVoting(uint256 id) internal {
        (, , , , , , , uint256 createdAt, , , ) = gov.proposals(id);
        vm.warp(createdAt + gov.votingPeriod() + 1);
        gov.finalize(id);
    }

    // ── happy path ─────────────────────────────────────────────────────────

    function test_FullLifecyclePassesAndExecutes() public {
        uint256 id = _propose(alice, gov.PARAM_TIMELOCK_DELAY(), 72 hours);
        _voteFor(id, alice);
        _voteFor(id, bob);
        _voteAgainst(id, carol); // 900 for / 100 against, quorum 200
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Queued));

        uint256 aliceBefore = token.balanceOf(alice); // 600 - 100 deposit
        vm.expectRevert(DeodesGovernance.TimelockNotElapsed.selector);
        gov.execute(id);
        (, , , , , , , , uint256 queuedAt, , ) = gov.proposals(id);
        vm.warp(queuedAt + gov.timelockDelay());
        gov.execute(id);

        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Executed));
        assertEq(gov.timelockDelay(), 72 hours, "parameter applied");
        assertEq(token.balanceOf(alice), aliceBefore + DEPOSIT, "deposit refunded");
    }

    // ── double vote ────────────────────────────────────────────────────────

    function test_DoubleVoteReverts() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, alice);
        vm.prank(alice);
        vm.expectRevert(DeodesGovernance.AlreadyVoted.selector);
        gov.castVote(id, false);
    }

    // ── flash loan ─────────────────────────────────────────────────────────

    function test_FlashLoanVotesWithZeroPower() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        // Attacker acquires 50x the electorate AFTER the snapshot block.
        address attacker = makeAddr("attacker");
        token.mint(attacker, 50_000 ether);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.prank(attacker);
        vm.expectRevert(DeodesGovernance.ZeroVotingPower.selector);
        gov.castVote(id, true);
    }

    function test_TransferredPostSnapshotVotesZero() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        // Bob sends everything to fresh carol-wallet... use new account.
        address fresh = makeAddr("fresh");
        vm.prank(bob);
        token.transfer(fresh, 300 ether);
        vm.prank(fresh);
        token.delegate(fresh);
        vm.prank(fresh);
        vm.expectRevert(DeodesGovernance.ZeroVotingPower.selector);
        gov.castVote(id, true);
    }

    // ── defeat economics ───────────────────────────────────────────────────

    function test_DefeatedForfeitsDepositToTreasury() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        _voteAgainst(id, alice); // 600 against, 0 for: quorum met, majority fails
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Defeated));
        assertEq(token.balanceOf(treasury), DEPOSIT, "failed = no refund");
        assertEq(token.balanceOf(alice), 500 ether, "600 - 100 deposit, nothing back");
    }

    function test_QuorumFailDefeats() public {
        uint256 id = _propose(carol, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, carol); // 100 < 200 quorum
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Defeated));
    }

    function test_TieDefeatsStrictMajority() public {
        // 600-for alice vs 300+100... construct exact tie: mint dave 600.
        address dave = makeAddr("dave");
        token.mint(dave, 600 ether);
        vm.prank(dave);
        token.delegate(dave);
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, alice); // 600
        _voteAgainst(id, dave); // 600: total 1200 >= 200, for*2 == total -> not >
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Defeated));
    }

    // ── timelock binds everyone ────────────────────────────────────────────

    function test_WhaleMajorityStillWaitsTimelock() public {
        address whale = makeAddr("whale");
        token.mint(whale, 100_000 ether);
        vm.prank(whale);
        token.delegate(whale);
        vm.roll(block.number + 1);
        vm.prank(whale);
        token.approve(address(gov), DEPOSIT);
        // NOTE: hoisted — an inline gov.PARAM_*() call would consume the
        // prank below (forge: prank/expectRevert bind the NEXT external call,
        // including argument evaluation).
        uint8 param = gov.PARAM_QUORUM_PCT();
        vm.prank(whale);
        uint256 id = gov.createProposal(param, 30);
        vm.roll(block.number + 1); // votes cannot land in the creation block
        vm.prank(whale);
        gov.castVote(id, true); // sole passer, 100% for
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Queued));
        vm.expectRevert(DeodesGovernance.TimelockNotElapsed.selector);
        gov.execute(id);
    }

    // ── cancels ────────────────────────────────────────────────────────────

    function test_ProposerCancelRefunds() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        vm.prank(alice);
        gov.cancelByProposer(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Canceled));
        assertEq(token.balanceOf(alice), 600 ether, "cooperative cancel refunds");
    }

    function test_NonProposerCannotCooperativeCancel() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        vm.prank(bob);
        vm.expectRevert(DeodesGovernance.NotProposer.selector);
        gov.cancelByProposer(id);
    }

    function test_VoterCancelAtThresholdForfeits() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, alice); // 600
        _voteAgainst(id, bob); // 300
        _voteAgainst(id, carol); // 100 -> against 400/1000 = 40% >= 33%
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Queued));
        gov.cancelByVoters(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Canceled));
        assertEq(token.balanceOf(treasury), DEPOSIT, "adversarial cancel forfeits");
    }

    function test_VoterCancelBelowThresholdReverts() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, alice); // 600
        _voteFor(id, bob); // 300
        _voteAgainst(id, carol); // 100 -> 10% < 33%
        _closeVoting(id);
        vm.expectRevert(DeodesGovernance.CancelNotAllowed.selector);
        gov.cancelByVoters(id);
    }

    // ── timing + state guards ──────────────────────────────────────────────

    function test_VoteAfterDeadlineReverts() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        (, , , , , , , uint256 createdAt, , , ) = gov.proposals(id);
        vm.warp(createdAt + gov.votingPeriod() + 1);
        vm.prank(alice);
        vm.expectRevert(DeodesGovernance.VotingClosed.selector);
        gov.castVote(id, true);
    }

    function test_FinalizeBeforeEndReverts() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        vm.expectRevert(DeodesGovernance.VotingOpen.selector);
        gov.finalize(id);
    }

    function test_ExecuteDefeatedReverts() public {
        uint256 id = _propose(carol, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, carol);
        _closeVoting(id);
        vm.expectRevert(DeodesGovernance.NotQueued.selector);
        gov.execute(id);
    }

    function test_FinalizeTwiceReverts() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        _voteFor(id, alice);
        _closeVoting(id);
        vm.expectRevert(DeodesGovernance.NotPending.selector);
        gov.finalize(id);
    }

    function test_UnknownProposalReverts() public {
        vm.expectRevert(DeodesGovernance.InvalidProposal.selector);
        gov.getState(999);
    }

    // ── bounds ─────────────────────────────────────────────────────────────

    function test_BadParamAndOutOfBoundsRevert() public {
        _approve(alice);
        // Hoisted: inline gov.PARAM_*() calls would consume expectRevert
        // (it binds the NEXT external call, including argument evaluation).
        uint8 quorumParam = gov.PARAM_QUORUM_PCT();
        uint8 timelockParam = gov.PARAM_TIMELOCK_DELAY();
        vm.startPrank(alice);
        vm.expectRevert(DeodesGovernance.BadParam.selector);
        gov.createProposal(9, 1);
        vm.expectRevert(DeodesGovernance.OutOfBounds.selector);
        gov.createProposal(quorumParam, 100); // max 50
        vm.expectRevert(DeodesGovernance.OutOfBounds.selector);
        gov.createProposal(timelockParam, 31 days); // max 30d
        vm.stopPrank();
    }

    function test_BoundsEdgesAccepted() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 50);
        _voteFor(id, alice);
        _voteFor(id, bob);
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Queued));
    }

    function test_CreateWithoutApproveReverts() public {
        vm.roll(block.number + 1);
        uint8 param = gov.PARAM_QUORUM_PCT(); // hoisted: inline call would eat expectRevert
        vm.prank(alice);
        vm.expectRevert(DeoToken.InsufficientAllowance.selector);
        gov.createProposal(param, 25);
    }

    // ── delegation-powered voting ──────────────────────────────────────────

    function test_DelegatedPowerVotesCombined() public {
        // Alice delegates everything to bob; bob votes with 900.
        vm.prank(alice);
        token.delegate(bob);
        uint256 id = _propose(bob, gov.PARAM_QUORUM_PCT(), 25);
        _approve(bob);
        vm.prank(bob);
        gov.castVote(id, true);
        (,,,,,uint256 forVotes,,,,,) = gov.proposals(id);
        assertEq(forVotes, 900 ether);
        // Alice kept no power for herself.
        vm.prank(alice);
        vm.expectRevert(DeodesGovernance.ZeroVotingPower.selector);
        gov.castVote(id, true);
    }

    // ── quorum snapshot stability ──────────────────────────────────────────

    function test_MidVoteMintDoesNotMoveQuorum() public {
        uint256 id = _propose(alice, gov.PARAM_QUORUM_PCT(), 25);
        (,,,,uint256 quorumVotes,,,,,,) = gov.proposals(id);
        assertEq(quorumVotes, 200 ether, "20% of 1000 at creation");
        token.mint(makeAddr("late"), 9_000 ether); // 10x supply mid-vote
        (,,,,uint256 quorumAfter,,,,,,) = gov.proposals(id);
        assertEq(quorumAfter, 200 ether, "goalposts frozen");
        _voteFor(id, alice); // 600 >= 200, 100% for
        _closeVoting(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Queued));
    }
}
