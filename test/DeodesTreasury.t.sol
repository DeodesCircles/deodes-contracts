// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeodesTreasury} from "../src/DeodesTreasury.sol";
import {DeodesFactory} from "../src/DeodesFactory.sol";
import {DeodesCircle} from "../src/DeodesCircle.sol";

/// @notice Owner contract that attempts reentry during withdraw().
///         The inner call must fail on the reentrancy lock (Reentrant), NOT on
///         auth (it IS the owner) — proving the guard, not the gate, stops it.
contract ReentrantOwner {
    DeodesTreasury internal immutable vault;
    bool public reentered;
    bool public innerWasReentrantRevert;

    constructor(DeodesTreasury _vault) {
        vault = _vault;
    }

    function attack(address to, uint256 amount) external {
        vault.withdraw(to, amount);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try vault.withdraw(address(this), 1) {} catch (bytes memory reason) {
                innerWasReentrantRevert =
                    bytes4(reason) == DeodesTreasury.Reentrant.selector;
                require(innerWasReentrantRevert, "inner must fail on Reentrant lock");
            }
        }
    }
}

/// @notice Treasury test suite (UNIFIED-PLAN 1.5): deposits (explicit + plain),
///         withdrawals (gated/guarded/accounted), V0 fee-flow interop through
///         the factory, reentrancy attempt, fuzz accounting.
contract DeodesTreasuryTest is Test {
    uint256 internal constant CONTRIBUTION = 10 ether;

    DeodesTreasury internal vault;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vault = new DeodesTreasury(); // owner = this test contract
    }

    // ── deposits ───────────────────────────────────────────────────────────

    function test_DepositRecordsEventAndTotals() public {
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit DeodesTreasury.Deposited(alice, CONTRIBUTION, CONTRIBUTION);
        vault.deposit{value: CONTRIBUTION}();
        assertEq(address(vault).balance, CONTRIBUTION);
        assertEq(vault.totalDeposited(), CONTRIBUTION);
        assertEq(vault.totalWithdrawn(), 0);
    }

    function test_PlainTransferRecordedAsDeposit() public {
        // Mirrors the V0 fee flow: empty-calldata .call{value} (no function).
        deal(alice, CONTRIBUTION);
        vm.prank(alice);
        (bool ok, ) = payable(address(vault)).call{value: CONTRIBUTION}("");
        assertTrue(ok, "vault must accept plain transfers or V0 payouts revert");
        assertEq(address(vault).balance, CONTRIBUTION);
        assertEq(vault.totalDeposited(), CONTRIBUTION);
    }

    function test_ZeroDepositReverts() public {
        vm.expectRevert(DeodesTreasury.ZeroAmount.selector);
        vault.deposit();
    }

    function test_ZeroPlainTransferSucceedsSilently() public {
        // Dust-fee edge (V0 fee truncates to 0 below 200 wei pool): plain
        // zero-value transfers must not brick a payout.
        (bool ok, ) = payable(address(vault)).call{value: 0}("");
        assertTrue(ok, "zero-value plain transfer succeeds");
        assertEq(vault.totalDeposited(), 0, "records nothing");
        assertEq(address(vault).balance, 0);
    }

    // ── withdrawals ────────────────────────────────────────────────────────

    function test_WithdrawMovesFundsAndAccounts() public {
        // Seed via deposit so totals are honest (deal() would bypass accounting).
        DeodesTreasury v2 = new DeodesTreasury();
        deal(alice, 5 ether);
        vm.prank(alice);
        v2.deposit{value: 5 ether}();

        uint256 bobBefore = bob.balance;
        vm.expectEmit(true, false, false, true, address(v2));
        emit DeodesTreasury.Withdrawn(bob, 2 ether, 3 ether);
        v2.withdraw(bob, 2 ether);
        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(address(v2).balance, 3 ether);
        assertEq(v2.totalWithdrawn(), 2 ether);
        assertEq(v2.totalDeposited(), 5 ether);
    }

    function test_WithdrawNonOwnerReverts() public {
        deal(address(vault), 1 ether);
        vm.prank(alice);
        vm.expectRevert(DeodesTreasury.NotOwner.selector);
        vault.withdraw(alice, 1 ether);
    }

    function test_WithdrawZeroAddressReverts() public {
        vm.expectRevert(DeodesTreasury.ZeroAddress.selector);
        vault.withdraw(address(0), 1 ether);
    }

    function test_WithdrawZeroAmountReverts() public {
        vm.expectRevert(DeodesTreasury.ZeroAmount.selector);
        vault.withdraw(bob, 0);
    }

    function test_WithdrawOverBalanceReverts() public {
        deal(alice, 1 ether);
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.expectRevert(DeodesTreasury.InsufficientBalance.selector);
        vault.withdraw(bob, 2 ether);
    }

    function test_TransferOwnership() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
        vm.expectRevert(DeodesTreasury.NotOwner.selector);
        vault.withdraw(bob, 1 ether); // old owner locked out
        vm.prank(alice);
        vault.transferOwnership(address(this));
        assertEq(vault.owner(), address(this));
    }

    // ── reentrancy ─────────────────────────────────────────────────────────

    function test_ReentrantWithdrawFailsOnLockNotAuth() public {
        ReentrantOwner attacker = new ReentrantOwner(vault);
        vault.transferOwnership(address(attacker));
        deal(alice, 3 ether);
        vm.prank(alice);
        vault.deposit{value: 3 ether}();

        // Outer withdraw pays the attacker itself so its receive() runs and
        // attempts reentry mid-flight.
        attacker.attack(address(attacker), 1 ether);

        assertTrue(attacker.reentered(), "reentry attempted");
        assertTrue(attacker.innerWasReentrantRevert(), "inner failed on Reentrant lock");
        assertEq(address(attacker).balance, 1 ether, "single drain only, not 1 + 1");
        assertEq(address(vault).balance, 2 ether);
        assertEq(vault.totalWithdrawn(), 1 ether);
    }

    // ── V0 fee-flow interop (the reason this vault exists) ─────────────────

    function test_V0CirclePayoutStreamsFeeToVault() public {
        // Factory with the vault as protocol default; circle created with
        // treasury = address(0) resolves to the vault.
        DeodesFactory factory = new DeodesFactory(address(vault));
        vm.prank(alice);
        address circleAddr = factory.createCircle(address(0), CONTRIBUTION, 2);
        DeodesCircle circle = DeodesCircle(payable(circleAddr));
        assertEq(circle.treasury(), address(vault));

        _join(circle, alice);
        _join(circle, bob);

        uint256 pool = address(circle).balance; // 20 ether
        uint256 fee = (pool * 50) / 10_000; // 0.1 ether
        circle.payout(bob); // ANYONE can trigger; fee goes via empty .call

        assertEq(address(vault).balance, fee, "vault received exactly the 0.5% fee");
        assertEq(vault.totalDeposited(), fee, "accounted as deposit");
        assertEq(address(circle).balance, 0, "circle drained");
        assertEq(bob.balance, pool - fee, "member got net");
    }

    function test_V0CircleExplicitTreasuryToVault() public {
        DeodesFactory factory = new DeodesFactory(makeAddr("otherTreasury"));
        vm.prank(alice);
        address circleAddr = factory.createCircle(address(vault), CONTRIBUTION, 2);
        DeodesCircle circle = DeodesCircle(payable(circleAddr));

        _join(circle, alice);
        _join(circle, bob);
        circle.payout(alice);

        assertEq(address(vault).balance, (20 ether * 50) / 10_000);
    }

    // ── fuzz accounting ────────────────────────────────────────────────────

    function testFuzz_DepositWithdrawRoundTrip(uint256 a, uint256 b) public {
        a = bound(a, 1, 100 ether);
        b = bound(b, 0, a);
        deal(alice, a);
        vm.prank(alice);
        vault.deposit{value: a}();
        if (b > 0) {
            vault.withdraw(bob, b);
        }
        assertEq(address(vault).balance, a - b);
        assertEq(vault.totalDeposited(), a);
        assertEq(vault.totalWithdrawn(), b);
        assertEq(vault.totalDeposited() - vault.totalWithdrawn(), address(vault).balance);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _join(DeodesCircle circle, address m) internal {
        deal(m, CONTRIBUTION);
        vm.prank(m);
        circle.join{value: CONTRIBUTION}();
    }
}
