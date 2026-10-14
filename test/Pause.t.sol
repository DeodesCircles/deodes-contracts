// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "../src/Pausable.sol";
import {DeodesFactory} from "../src/DeodesFactory.sol";
import {DeodesTreasury} from "../src/DeodesTreasury.sol";
import {DeoToken} from "../src/DeoToken.sol";
import {DeodesGovernance} from "../src/DeodesGovernance.sol";

/// @notice Emergency-pause suite (UNIFIED-PLAN 1.8): per-contract freeze
///         behavior, escape hatches that MUST stay open (governance cancels),
///         ownership lockstep, and the block-1 snapshot edge review.
contract PauseTest is Test {
    DeodesFactory internal factory;
    DeodesTreasury internal vault;
    DeoToken internal token;
    DeodesGovernance internal gov;
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        factory = new DeodesFactory(treasury);
        vault = new DeodesTreasury();
        token = new DeoToken();
        gov = new DeodesGovernance(token, treasury);
        token.mint(alice, 600 ether);
        token.mint(bob, 400 ether);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
    }

    // ── factory ────────────────────────────────────────────────────────────

    function test_FactoryPauseBlocksCreatesOnly() public {
        factory.pause();
        assertTrue(factory.paused());
        vm.prank(alice);
        vm.expectRevert(Pausable.IsPaused.selector);
        factory.createCircle(address(0), 10 ether, 5);
        // Reads unaffected.
        assertEq(factory.circleCount(), 0);
        factory.unpause();
        assertFalse(factory.paused());
        vm.prank(alice);
        factory.createCircle(address(0), 10 ether, 5);
        assertEq(factory.circleCount(), 1);
    }

    function test_PauseAccessAndEdges() public {
        vm.prank(alice);
        vm.expectRevert(Pausable.PauseNotOwner.selector);
        factory.pause();
        vm.expectRevert(Pausable.NotPaused.selector);
        factory.unpause(); // unpausing an unpaused contract reverts
        factory.pause();
        vm.expectRevert(Pausable.IsPaused.selector);
        factory.pause(); // double pause reverts
    }

    function test_OwnershipMovesPauseLockstep() public {
        factory.transferOwnership(alice);
        assertEq(factory.pauseOwner(), alice);
        vm.expectRevert(Pausable.PauseNotOwner.selector);
        factory.pause(); // old owner locked out of BOTH authorities
        vm.prank(alice);
        factory.pause();
        assertTrue(factory.paused());
    }

    // ── treasury ───────────────────────────────────────────────────────────

    function test_TreasuryPauseFreezesAllMovement() public {
        deal(alice, 6 ether); // 5 to seed + 1 for the reverted attempt below
        deal(address(this), 1 ether); // plain-transfer check pays from here
        vm.prank(alice);
        vault.deposit{value: 5 ether}();
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.IsPaused.selector);
        vault.deposit{value: 1 ether}();
        // Plain call runs as this contract (no prank active), so it pays the
        // 1 ether from the deal above; the paused vault must reject it.
        (bool ok, ) = payable(address(vault)).call{value: 1 ether}("");
        assertFalse(ok, "paused receive rejects plain transfers");
        vm.expectRevert(Pausable.IsPaused.selector);
        vault.withdraw(alice, 1 ether);
        assertEq(address(vault).balance, 5 ether, "nothing moved while paused");
        vault.unpause();
        vault.withdraw(alice, 5 ether);
        assertEq(address(vault).balance, 0);
    }

    // ── governance: progression freezes, cancels stay open ─────────────────

    function _queuedProposal() internal returns (uint256 id) {
        vm.roll(block.number + 1);
        vm.prank(alice);
        token.approve(address(gov), 100 ether);
        // Hoisted (1.7 lesson): inline gov.PARAM_*() would eat the prank below.
        uint8 param = gov.PARAM_QUORUM_PCT();
        vm.prank(alice);
        id = gov.createProposal(param, 25);
        vm.roll(block.number + 1);
        vm.prank(alice);
        gov.castVote(id, true); // 600: quorum 200, 100% for
        (,,,,,,, uint256 createdAt,,,) = gov.proposals(id);
        vm.warp(createdAt + gov.votingPeriod() + 1);
        gov.finalize(id);
    }

    function test_GovernancePauseFreezesProgression() public {
        uint256 id = _queuedProposal();
        gov.pause();
        vm.expectRevert(Pausable.IsPaused.selector);
        gov.execute(id);
        gov.unpause();
        (,,,,,,,, uint256 queuedAt,,) = gov.proposals(id);
        vm.warp(queuedAt + gov.timelockDelay());
        gov.execute(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Executed));
    }

    function test_GovernancePauseBlocksNewLifecycle() public {
        gov.pause();
        vm.prank(alice);
        token.approve(address(gov), 100 ether);
        uint8 param = gov.PARAM_QUORUM_PCT(); // hoisted (see _queuedProposal)
        vm.prank(alice);
        vm.expectRevert(Pausable.IsPaused.selector);
        gov.createProposal(param, 25);
    }

    function test_CancelsWorkWhilePaused() public {
        uint256 id = _queuedProposal();
        gov.pause();
        // Proposer escape hatch open while paused (refunded).
        vm.prank(alice);
        gov.cancelByProposer(id);
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Canceled));
        assertEq(token.balanceOf(alice), 600 ether);
    }

    function test_VoterCancelWorksWhilePaused() public {
        // 600 for / 400 against: queued, 40% against >= 33%.
        vm.roll(block.number + 1);
        vm.prank(alice);
        token.approve(address(gov), 100 ether);
        uint8 param = gov.PARAM_QUORUM_PCT(); // hoisted (see _queuedProposal)
        vm.prank(alice);
        uint256 id = gov.createProposal(param, 25);
        vm.roll(block.number + 1);
        vm.prank(alice);
        gov.castVote(id, true);
        vm.prank(bob);
        gov.castVote(id, false);
        (,,,,,,, uint256 createdAt,,,) = gov.proposals(id);
        vm.warp(createdAt + gov.votingPeriod() + 1);
        gov.finalize(id);
        gov.pause();
        gov.cancelByVoters(id); // escape hatch: no prank needed, anyone may call
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Canceled));
        assertEq(token.balanceOf(treasury), 100 ether, "adversarial cancel forfeits");
    }

    // ── snapshot review: block-1 creation edge ─────────────────────────────

    function test_SnapshotAtGenesisBlockDefeatsGracefully() public {
        // Creation in block 1 (no roll): snapshot = block 0, where NO
        // checkpoints exist — every voter reads zero power. The proposal must
        // die as Defeated, never brick the machine (1.8 snapshot review).
        vm.prank(alice);
        token.approve(address(gov), 100 ether);
        uint8 param = gov.PARAM_QUORUM_PCT(); // hoisted (see _queuedProposal)
        vm.prank(alice);
        uint256 id = gov.createProposal(param, 25);
        (,,, uint256 snapshot,,,,,,,) = gov.proposals(id);
        assertEq(snapshot, 0);
        vm.prank(alice);
        vm.expectRevert(DeodesGovernance.ZeroVotingPower.selector);
        gov.castVote(id, true);
        (,,,,,,, uint256 createdAt,,,) = gov.proposals(id);
        vm.warp(createdAt + gov.votingPeriod() + 1);
        gov.finalize(id); // 0 votes < quorum → Defeated, deposit forfeited
        assertEq(uint256(gov.getState(id)), uint256(DeodesGovernance.State.Defeated));
    }
}
