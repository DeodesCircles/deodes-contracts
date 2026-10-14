// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {DeoToken} from "./DeoToken.sol";
import {Pausable} from "./Pausable.sol";

/// @title DeodesGovernance — DEO proposal lifecycle with timelock (V1).
/// @notice UNIFIED-PLAN 1.7. Lifecycle: Pending (7d vote) → Queued (48h
///         timelock) → Executed; or Defeated / Canceled. Every proposal changes
///         exactly one governable parameter (no empty signaling).
///
///         Anti-flash-loan: voting weight = DeoToken.getPriorVotes(voter,
///         proposal.snapshotBlock) — balances at the block BEFORE creation.
///         The creation block itself is EXCLUDED on purpose: the deposit
///         escrow transferFrom lands in the creation block, and snapshotting
///         it would silently disenfranchise any proposer whose balance equals
///         the deposit (found by test: carol with exactly 100 DEO read as
///         zero power). Tokens bought, minted, or received at/after the
///         creation block still read as ZERO at the snapshot — atomic
///         borrow-and-vote stays impossible; only pre-positioned holders vote.
///         Quorum (default 20% of supply) is snapshotted at the same block,
///         so mid-vote mints cannot move the goalposts either.
///
///         Pass rule: strict majority (for*2 > for+against) AND quorum met.
///         Deposit (default 100 DEO, approved upfront, held in escrow):
///         executed → refunded; defeated → forfeited to treasury;
///         proposer-cancel → refunded (cooperative); voter-cancel → forfeited
///         (adversarial).
///         Cancel: proposer anytime pre-execution; anyone during timelock iff
///         against-share >= cancelThresholdPct (default 33).
///
///         Governable params (id: default [min..max]): 0 VOTING_PERIOD 7d
///         [1d..30d]; 1 TIMELOCK_DELAY 48h [1h..30d]; 2 QUORUM_PCT 20 [1..50];
///         3 CANCEL_THRESHOLD_PCT 33 [1..100]; 4 PROPOSAL_DEPOSIT 100 DEO
///         [0..1M DEO]. Bounds prevent governance suicide (e.g. quorum 100).
///         Time uses block.timestamp (day/hour granularity — same triage as
///         the reputation recency note in 1.6).
///
///         Emergency pause (UNIFIED-PLAN 1.8) freezes createProposal, castVote,
///         finalize, and execute — but NEVER the two cancel paths. Cancels are
///         escape hatches: trapping a malicious proposal inside the timelock
///         by pausing its cancellation would be strictly worse than the
///         attack. Pause authority moves with ownership (lockstep) to the
///         multisig/timelock at the 1.11 ceremony.
contract DeodesGovernance is Pausable {
/// @dev LINT TRIAGE (2026-10-14): `block-timestamp` on voting/timelock
///      windows is accepted risk (7d/48h granularity; validator games move
///      seconds). One `environment-read-across-mutation` on execute() is a
///      false positive (no cheatcodes exist in src; plain timelock check).
    enum State {
        Pending, // 0: voting open
        Queued, // 1: passed, inside timelock
        Executed, // 2: terminal
        Defeated, // 3: terminal
        Canceled // 4: terminal

    }

    uint8 public constant PARAM_VOTING_PERIOD = 0;
    uint8 public constant PARAM_TIMELOCK_DELAY = 1;
    uint8 public constant PARAM_QUORUM_PCT = 2;
    uint8 public constant PARAM_CANCEL_THRESHOLD_PCT = 3;
    uint8 public constant PARAM_PROPOSAL_DEPOSIT = 4;

    struct Proposal {
        address proposer;
        uint8 param;
        uint256 newValue;
        uint256 snapshotBlock;
        uint256 quorumVotes;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 createdAt;
        uint256 queuedAt;
        uint256 deposit;
        State state;
    }

    DeoToken public immutable deo;
    address public treasury;
    address public owner;

    uint256 public votingPeriod = 7 days;
    uint256 public timelockDelay = 48 hours;
    uint256 public quorumPct = 20;
    uint256 public cancelThresholdPct = 33;
    uint256 public proposalDeposit = 100 ether;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public voted;

    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        uint8 param,
        uint256 newValue,
        uint256 quorumVotes,
        uint256 deposit
    );
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalQueued(uint256 indexed id, uint256 queuedAt);
    event ProposalExecuted(uint256 indexed id, uint8 param, uint256 newValue);
    event ProposalDefeated(uint256 indexed id);
    event ProposalCanceled(uint256 indexed id, bool byVoters);
    event DepositRefunded(uint256 indexed id, address indexed to, uint256 amount);
    event DepositForfeited(uint256 indexed id, address indexed treasury, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error NotOwner();
    error InvalidProposal();
    error BadParam();
    error OutOfBounds();
    error VotingClosed();
    error VotingOpen();
    error AlreadyVoted();
    error ZeroVotingPower();
    error NotPending();
    error NotQueued();
    error TimelockNotElapsed();
    error NotProposer();
    error CancelNotAllowed();
    error TransferFailed();

    constructor(DeoToken _deo, address _treasury) {
        if (address(_deo) == address(0) || _treasury == address(0)) revert BadParam();
        deo = _deo;
        treasury = _treasury;
        owner = msg.sender;
    }

    function setTreasury(address newTreasury) external {
        if (msg.sender != owner) revert NotOwner();
        if (newTreasury == address(0)) revert BadParam();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert NotOwner();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
        // Lockstep with pause authority (1.8 rationale in NatSpec above).
        pauseOwner = newOwner;
        emit PauseOwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Create a proposal changing exactly one parameter. Caller must
    ///         approve(proposalDeposit) first; the deposit is escrowed here.
    function createProposal(uint8 param, uint256 newValue) external whenNotPaused returns (uint256 id) {
        _checkBounds(param, newValue);
        uint256 deposit = proposalDeposit;
        if (deposit > 0) {
            bool ok = deo.transferFrom(msg.sender, address(this), deposit);
            if (!ok) revert TransferFailed();
        }
        id = proposalCount;
        proposalCount = id + 1;
        uint256 supply = deo.totalSupply();
        // Snapshot the PRIOR block (see NatSpec): the escrow transferFrom
        // below lands in the creation block, and end-of-block checkpoint
        // reads would count the proposer as poorer by exactly the deposit.
        // block.number >= 1 in any executable context, so no underflow.
        uint256 snapshot = block.number - 1;
        proposals[id] = Proposal({
            proposer: msg.sender,
            param: param,
            newValue: newValue,
            snapshotBlock: snapshot,
            quorumVotes: (supply * quorumPct) / 100,
            forVotes: 0,
            againstVotes: 0,
            createdAt: block.timestamp,
            queuedAt: 0,
            deposit: deposit,
            state: State.Pending
        });
        emit ProposalCreated(id, msg.sender, param, newValue, (supply * quorumPct) / 100, deposit);
    }

    /// @notice Vote with snapshot weight. Reverts on zero power (this IS the
    ///         flash-loan guard asserting itself — post-creation balances
    ///         read as zero at the snapshot block).
    function castVote(uint256 id, bool support) external whenNotPaused {
        Proposal storage p = _proposal(id);
        if (p.state != State.Pending) revert NotPending();
        if (block.timestamp > p.createdAt + votingPeriod) revert VotingClosed();
        if (voted[id][msg.sender]) revert AlreadyVoted();
        uint256 weight = deo.getPriorVotes(msg.sender, p.snapshotBlock);
        if (weight == 0) revert ZeroVotingPower();
        voted[id][msg.sender] = true;
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }
        emit VoteCast(id, msg.sender, support, weight);
    }

    /// @notice Close voting after the window. Anyone may call. Passed →
    ///         Queued (timelock starts); otherwise Defeated + deposit forfeit.
    function finalize(uint256 id) external whenNotPaused {
        Proposal storage p = _proposal(id);
        if (p.state != State.Pending) revert NotPending();
        if (block.timestamp <= p.createdAt + votingPeriod) revert VotingOpen();
        uint256 total = p.forVotes + p.againstVotes;
        if (total >= p.quorumVotes && p.forVotes * 2 > total) {
            p.state = State.Queued;
            p.queuedAt = block.timestamp;
            emit ProposalQueued(id, block.timestamp);
        } else {
            p.state = State.Defeated;
            _forfeit(id, p);
            emit ProposalDefeated(id);
        }
    }

    /// @notice Execute after the timelock. Applies the parameter, refunds the
    ///         deposit. Effects (state) precede the DEO refund transfer.
    function execute(uint256 id) external whenNotPaused {
        Proposal storage p = _proposal(id);
        if (p.state != State.Queued) revert NotQueued();
        if (block.timestamp < p.queuedAt + timelockDelay) revert TimelockNotElapsed();
        p.state = State.Executed;
        _applyParam(p.param, p.newValue);
        _refund(id, p);
        emit ProposalExecuted(id, p.param, p.newValue);
    }

    /// @notice Proposer cooperative-cancel anytime pre-execution; refunded.
    function cancelByProposer(uint256 id) external {
        Proposal storage p = _proposal(id);
        if (msg.sender != p.proposer) revert NotProposer();
        if (p.state != State.Pending && p.state != State.Queued) revert CancelNotAllowed();
        p.state = State.Canceled;
        _refund(id, p);
        emit ProposalCanceled(id, false);
    }

    /// @notice Adversarial cancel inside the timelock: anyone may cancel iff
    ///         against-share >= cancelThresholdPct. Deposit forfeited.
    function cancelByVoters(uint256 id) external {
        Proposal storage p = _proposal(id);
        if (p.state != State.Queued) revert NotQueued();
        uint256 total = p.forVotes + p.againstVotes;
        if (total == 0 || (p.againstVotes * 100) / total < cancelThresholdPct) {
            revert CancelNotAllowed();
        }
        p.state = State.Canceled;
        _forfeit(id, p);
        emit ProposalCanceled(id, true);
    }

    function getState(uint256 id) external view returns (State) {
        return _proposal(id).state;
    }

    function _proposal(uint256 id) internal view returns (Proposal storage p) {
        if (id >= proposalCount) revert InvalidProposal();
        p = proposals[id];
    }

    function _checkBounds(uint8 param, uint256 value) internal pure {
        if (param == PARAM_VOTING_PERIOD) {
            if (value < 1 days || value > 30 days) revert OutOfBounds();
        } else if (param == PARAM_TIMELOCK_DELAY) {
            if (value < 1 hours || value > 30 days) revert OutOfBounds();
        } else if (param == PARAM_QUORUM_PCT) {
            if (value < 1 || value > 50) revert OutOfBounds();
        } else if (param == PARAM_CANCEL_THRESHOLD_PCT) {
            if (value < 1 || value > 100) revert OutOfBounds();
        } else if (param == PARAM_PROPOSAL_DEPOSIT) {
            if (value > 1_000_000 ether) revert OutOfBounds();
        } else {
            revert BadParam();
        }
    }

    function _applyParam(uint8 param, uint256 value) internal {
        if (param == PARAM_VOTING_PERIOD) votingPeriod = value;
        else if (param == PARAM_TIMELOCK_DELAY) timelockDelay = value;
        else if (param == PARAM_QUORUM_PCT) quorumPct = value;
        else if (param == PARAM_CANCEL_THRESHOLD_PCT) cancelThresholdPct = value;
        else /* PARAM_PROPOSAL_DEPOSIT */ proposalDeposit = value;
    }

    function _refund(uint256 id, Proposal storage p) internal {
        if (p.deposit == 0) return;
        uint256 amount = p.deposit;
        p.deposit = 0;
        bool ok = deo.transfer(p.proposer, amount);
        if (!ok) revert TransferFailed();
        emit DepositRefunded(id, p.proposer, amount);
    }

    function _forfeit(uint256 id, Proposal storage p) internal {
        if (p.deposit == 0) return;
        uint256 amount = p.deposit;
        p.deposit = 0;
        bool ok = deo.transfer(treasury, amount);
        if (!ok) revert TransferFailed();
        emit DepositForfeited(id, treasury, amount);
    }
}
