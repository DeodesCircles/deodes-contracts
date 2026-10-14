// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title Pausable — minimal emergency-stop shared by V1 contracts.
/// @notice UNIFIED-PLAN 1.8. Owner-gated pause/unpause with events. Semantics
///         are intentionally blunt: paused functions REVERT, they do not
///         queue. Pause power centralizes by design — it MUST move to the
///         multisig/timelock at the 1.11 ceremony (every inheriting contract
///         documents this), and every pause/unpause is event-logged for
///         off-chain alarms.
///
///         Deliberately NOT pausable: DeoToken (pausing transfers would brick
///         governance escrow + voting deposits mid-election — strictly worse
///         than any attack it could stop) and DeodesCircle V0 (frozen).
///         DeodesReputationRegistry record-functions are recorder-gated, not
///         paused: freezing reputation writes would brick circle flows that
///         report into it, while adding no safety (writes are already
///         allowlisted).
contract Pausable {
    address public pauseOwner;
    bool public paused;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event PauseOwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error PauseNotOwner();
    error IsPaused();
    error NotPaused();

    constructor() {
        pauseOwner = msg.sender;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    function pause() external {
        if (msg.sender != pauseOwner) revert PauseNotOwner();
        if (paused) revert IsPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if (msg.sender != pauseOwner) revert PauseNotOwner();
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferPauseOwnership(address newOwner) external {
        if (msg.sender != pauseOwner) revert PauseNotOwner();
        if (newOwner == address(0)) revert PauseNotOwner();
        address oldOwner = pauseOwner;
        pauseOwner = newOwner;
        emit PauseOwnershipTransferred(oldOwner, newOwner);
    }
}
