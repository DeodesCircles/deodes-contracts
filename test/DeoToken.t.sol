// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeoToken} from "../src/DeoToken.sol";

/// @notice DEO token tests (UNIFIED-PLAN 1.7): ERC-20 core, mint cap + owner
///         gate, delegation activation/movement, checkpoint history.
contract DeoTokenTest is Test {
    DeoToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new DeoToken(); // owner = this test
    }

    // ── ERC-20 core ────────────────────────────────────────────────────────

    function test_TransferMovesBalances() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 40 ether));
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.totalSupply(), 100 ether);
    }

    function test_TransferToZeroReverts() public {
        token.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(DeoToken.ZeroAddress.selector);
        token.transfer(address(0), 1 ether);
    }

    function test_TransferOverBalanceReverts() public {
        token.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(DeoToken.InsufficientBalance.selector);
        token.transfer(bob, 11 ether);
    }

    function test_ApproveAndTransferFrom() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 30 ether);
        assertEq(token.allowance(alice, bob), 30 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 30 ether));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 30 ether);
    }

    function test_TransferFromOverAllowanceReverts() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(DeoToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 11 ether);
    }

    // ── mint ───────────────────────────────────────────────────────────────

    function test_MintOwnerGatedAndCapped() public {
        token.mint(alice, token.MAX_SUPPLY());
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        vm.expectRevert(DeoToken.SupplyCapped.selector);
        token.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(DeoToken.NotOwner.selector);
        token.mint(alice, 1);
    }

    // ── delegation ─────────────────────────────────────────────────────────

    function test_NoDelegationNoPower() public {
        token.mint(alice, 100 ether);
        vm.roll(block.number + 1);
        assertEq(token.getPriorVotes(alice, block.number - 1), 0);
    }

    function test_SelfDelegateActivates() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.delegate(alice);
        vm.roll(block.number + 1);
        assertEq(token.getPriorVotes(alice, block.number - 1), 100 ether);
    }

    function test_DelegateToOtherMovesPower() public {
        token.mint(alice, 100 ether);
        token.mint(bob, 10 ether);
        vm.prank(alice);
        token.delegate(bob);
        vm.prank(bob);
        token.delegate(bob); // bob self-delegates so receipts credit his rep
        vm.roll(block.number + 1);
        assertEq(token.getPriorVotes(bob, block.number - 1), 110 ether);
        assertEq(token.getPriorVotes(alice, block.number - 1), 0);

        // Transfer moves power between CURRENT delegates (both bob): preserved.
        vm.prank(alice);
        token.transfer(bob, 40 ether);
        vm.roll(block.number + 1);
        assertEq(token.getPriorVotes(bob, block.number - 1), 110 ether);
    }

    function test_RedelegateShiftsPower() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(alice);
        token.delegate(bob);
        vm.roll(block.number + 1);
        assertEq(token.getPriorVotes(alice, block.number - 1), 0);
        assertEq(token.getPriorVotes(bob, block.number - 1), 100 ether);
    }

    function test_HistoryAcrossBlocks() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.delegate(alice);
        uint256 b1 = block.number;
        vm.roll(b1 + 5);
        token.mint(alice, 50 ether); // same delegatee, later block
        vm.roll(b1 + 10);
        assertEq(token.getPriorVotes(alice, b1), 100 ether);
        assertEq(token.getPriorVotes(alice, b1 + 5), 150 ether);
        assertEq(token.getPriorVotes(alice, b1 + 10 - 1), 150 ether);
    }

    function test_PriorVotesFutureReverts() public {
        token.mint(alice, 100 ether);
        vm.expectRevert(DeoToken.NotYetDetermined.selector);
        token.getPriorVotes(alice, block.number);
    }

    // ── conservation fuzz ──────────────────────────────────────────────────

    function testFuzz_TransferConservesSupply(uint256 a, uint256 b) public {
        a = bound(a, 1, 1_000 ether);
        b = bound(b, 0, a);
        token.mint(alice, a);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(alice);
        token.transfer(bob, b);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), a);
        assertEq(token.totalSupply(), a);
    }
}
