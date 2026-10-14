// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Pausable} from "./Pausable.sol";

/// @title DeodesTreasury — protocol-fee vault for Deodes circles (V1).
/// @notice UNIFIED-PLAN 1.5. Replaces the V0 EOA treasury (see
///         MAINNET-INCIDENT-REPORT.md §5: organizer == treasury single EOA).
///
///         INTEROP (critical): DeodesCircle forwards its 0.5% fee via
///         `treasury.call{value: fee}("")` — empty calldata. A vault WITHOUT a
///         payable receive() makes EVERY V0/factory-circle payout revert.
///         receive() therefore records plain transfers as deposits.
///
///         Phase 0.6 freeze: this vault (protocol revenue) and the keeper
///         escrow (user-debit collector) must be DIFFERENT addresses — never
///         configure the same address for both roles.
///
///         Custody: deploy-time EOA Density owns this vault until UNIFIED-PLAN
///         1.7/1.11 transfers ownership to the governance timelock. Until then
///         every withdrawal is owner-gated AND fully event-logged, so a rogue
///         owner is visible on-chain the moment it acts.
///
///         Emergency pause (UNIFIED-PLAN 1.8) freezes deposit/receive/withdraw
///         together: a paused vault accepts nothing and releases nothing.
///         Pause authority moves with ownership (lockstep) to the
///         multisig/timelock at the 1.11 ceremony.
contract DeodesTreasury is Pausable {
    address public owner;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 private _locked;

    event Deposited(address indexed sender, uint256 amount, uint256 balance);
    event Withdrawn(address indexed to, uint256 amount, uint256 balance);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        if (_locked != 0) revert Reentrant();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Accept plain native transfers (V0 fee flow + direct funding).
    ///         Zero-value transfers succeed silently: V0 computes
    ///         fee = pool*50/10000, which truncates to 0 for dust pools
    ///         (< 200 wei); reverting here would brick such payouts.
    ///         Non-zero transfers are recorded as deposits.
    receive() external payable whenNotPaused {
        if (msg.value == 0) return;
        _recordDeposit(msg.sender, msg.value);
    }

    /// @notice Explicit deposit entry point. Unlike receive(), zero value
    ///         reverts: calling deposit() with nothing is caller error, and
    ///         failing loudly beats an empty event.
    function deposit() external payable whenNotPaused {
        _recordDeposit(msg.sender, msg.value);
    }

    function _recordDeposit(address sender, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        totalDeposited += amount;
        emit Deposited(sender, amount, address(this).balance);
    }

    /// @notice Move funds out. Owner-only, zero-address/zero-amount guarded,
    ///         never more than the balance, reentrancy-locked, event-logged.
    /// @dev LINT TRIAGE (2026-10-14): `forge build` flags `reentrancy-eth` /
    ///      `reentrancy-events` here. Both are heuristic false positives: the
    ///      custom nonReentrant lock engages before the body (proven by
    ///      test_ReentrantWithdrawFailsOnLockNotAuth, which asserts the inner
    ///      call fails on Reentrant — not on auth), effects
    ///      (totalWithdrawn +=) precede the interaction, and the post-call
    ///      event intentionally logs the post-transfer balance (a revert rolls
    ///      it back, so it can never fabricate a log for a failed transfer).
    function withdraw(address to, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > address(this).balance) revert InsufficientBalance();
        totalWithdrawn += amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(to, amount, address(this).balance);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert NotOwner();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
        // Lockstep with pause authority (see DeodesFactory rationale, 1.8).
        pauseOwner = newOwner;
        emit PauseOwnershipTransferred(oldOwner, newOwner);
    }
}
