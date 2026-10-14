// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {DeodesCircle} from "./DeodesCircle.sol";
import {Pausable} from "./Pausable.sol";
import {IDeodesEvents} from "./IDeodesEvents.sol";

/// @title DeodesFactory — permissionless registry deploying one DeodesCircle per call.
/// @notice V1 (UNIFIED-PLAN 1.4). Each createCircle() performs a fresh CREATE, so
///         every circle has a unique address by deployer-nonce progression; the
///         factory never reuses or re-registers an address (enforced by the
///         CircleAlreadyRegistered guard, defense-in-depth: a fresh CREATE cannot
///         collide, mirroring the RotationComplete pattern in DeodesCircle).
///         Cross-chain address reuse is prevented by per-env deployer keys
///         (UNIFIED-PLAN 1.11), not by this contract — same key + same nonce on
///         two chains yields the same address (see MAINNET-INCIDENT-REPORT.md).
///
///         NOTE: DeodesCircle sets `organizer = msg.sender` at construction, so a
///         factory-created circle's on-chain organizer is THIS factory. The human
///         organizer is recorded in `circleOrganizer` and emitted in CircleCreated;
///         off-chain consumers (indexer, UI) MUST use circleOrganizer, not
///         DeodesCircle.organizer, for factory circles.
///
///         Emits the canonical IDeodesEvents.CircleCreated (inherited — the
///         compiler guarantees the factory cannot drift from the frozen
///         1.9 schema). See EVENTS.md.
contract DeodesFactory is Pausable, IDeodesEvents {
    address public owner;
    address public protocolTreasury;

    address[] private _circles;
    mapping(address => bool) public isCircle;
    mapping(address => address) public circleOrganizer;

    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error TreasuryRequired();
    error ContributionRequired();
    error InvalidMemberBounds();
    error CircleAlreadyRegistered();
    error NotOwner();

    constructor(address _protocolTreasury) {
        if (_protocolTreasury == address(0)) revert TreasuryRequired();
        owner = msg.sender;
        protocolTreasury = _protocolTreasury;
    }

    /// @notice Deploy a new circle. Pass treasury = address(0) to use the
    ///         protocol default. Bounds mirror DeodesCircle so misconfigured
    ///         calls fail here (cheap) instead of inside the deployment.
    ///         Paused during emergencies (no new circles while paused).
    function createCircle(
        address treasury_,
        uint256 contribution,
        uint256 maxMembers
    ) external whenNotPaused returns (address circle) {
        address treasury = treasury_ == address(0) ? protocolTreasury : treasury_;
        if (treasury == address(0)) revert TreasuryRequired();
        if (contribution == 0) revert ContributionRequired();
        if (maxMembers < 2 || maxMembers > 100) revert InvalidMemberBounds();

        circle = address(new DeodesCircle(treasury, contribution, maxMembers));
        if (isCircle[circle]) revert CircleAlreadyRegistered();

        isCircle[circle] = true;
        circleOrganizer[circle] = msg.sender;
        _circles.push(circle);
        emit CircleCreated(circle, msg.sender, treasury, contribution, maxMembers, _circles.length - 1);
    }

    /// @notice Update the default fee vault. Per-circle treasuries already
    ///         deployed are immutable and unaffected.
    function setProtocolTreasury(address newTreasury) external {
        if (msg.sender != owner) revert NotOwner();
        if (newTreasury == address(0)) revert TreasuryRequired();
        address oldTreasury = protocolTreasury;
        protocolTreasury = newTreasury;
        emit ProtocolTreasuryUpdated(oldTreasury, newTreasury);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert NotOwner();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
        // Lockstep: a lone pauseOwner after handover is a backdoor. Pause
        // authority moves to the multisig/timelock with everything else (1.11).
        pauseOwner = newOwner;
        emit PauseOwnershipTransferred(oldOwner, newOwner);
    }

    function circleCount() external view returns (uint256) {
        return _circles.length;
    }

    function circleAt(uint256 index) external view returns (address) {
        return _circles[index];
    }

    /// @notice Paginated registry read (offset/limit) so off-chain indexers and
    ///         UIs never walk an unbounded array. limit == 0 or offset beyond
    ///         the end returns an empty array, never reverts.
    function allCircles(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 length = _circles.length;
        if (offset >= length || limit == 0) {
            return new address[](0);
        }
        uint256 end = offset + limit;
        if (end > length) end = length;
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = _circles[i];
        }
    }
}
