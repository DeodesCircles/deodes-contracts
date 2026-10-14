// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title DeodesReputationRegistry — on-chain DeoScore (V1).
/// @notice UNIFIED-PLAN 1.6. Score 0–1000 from four capped components:
///
///         streak      35% → min(streak * 35, 350): +35 per on-time payment.
///         completions 30% → min(completions * 50, 300): +50 per completed circle.
///         volume      20% → min(totalVolumeUSDC, 200): +1 per whole USDC contributed.
///         recency     15% → 150 (≤30d) / 100 (≤90d) / 50 (≤180d) / 0.
///
///         FORMULA FROZEN (Phase 1.6 decision): weights 35/30/20/15 match the
///         backend formula (BACK-END PLAN §8, content/docs/reputation.md).
///         Backend 2.9 MUST mirror these exact numbers — shared vectors live
///         in test/vectors/reputation-vectors.json and are asserted on both
///         sides. Any formula change is a new UNIFIED-PLAN subphase, never a
///         silent edit.
///
///         Defaults act through streak reset (a default zeroes the streak),
///         not a subtraction term; `defaults` is exposed for 2.9 gating.
///         Tier table (UPGRADE Ph6): collateral bips Diamond 0 / Plat 100 /
///         Gold 300 / Silver 500 / Bronze 1000; maxSize 100/50/20/10/5;
///         maxContrib (whole USDC) 50000/10000/2000/500/100.
///
///         Writes are recorder-gated (circles/factory registered by owner);
///         reads are permissionless. Ownership moves to the governance
///         timelock at 1.7/1.11.
contract DeodesReputationRegistry {
    enum Tier {
        Bronze, // 0
        Silver, // 1
        Gold, // 2
        Platinum, // 3
        Diamond // 4

    }

    struct Record {
        uint256 streak;
        uint256 completions;
        uint256 totalVolumeWei;
        uint256 lastActive;
        uint256 defaults;
    }

    // Eligibility reason codes for checkEligibility (view-friendly, no strings).
    uint8 public constant ELIGIBLE = 0;
    uint8 public constant SIZE_EXCEEDS_TIER = 1;
    uint8 public constant CONTRIBUTION_EXCEEDS_TIER = 2;

    uint256 public constant STREAK_PER = 35;
    uint256 public constant STREAK_MAX = 350;
    uint256 public constant COMPLETION_PER = 50;
    uint256 public constant COMPLETION_MAX = 300;
    uint256 public constant VOLUME_MAX = 200;
    uint256 public constant RECENCY_MAX = 150;
    uint256 public constant SCORE_MAX = 1000;
    uint256 public constant WAD = 1e18;

    address public owner;
    mapping(address => Record) private _records;
    mapping(address => bool) public isRecorder;

    event ContributionRecorded(address indexed user, uint256 amount, bool onTime, uint256 streak);
    event CompletionRecorded(address indexed user, uint256 completions);
    event DefaultRecorded(address indexed user, uint256 defaults);
    event RecorderUpdated(address indexed recorder, bool allowed);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error NotOwner();
    error NotRecorder();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRecorder() {
        if (!isRecorder[msg.sender]) revert NotRecorder();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setRecorder(address recorder, bool allowed) external onlyOwner {
        isRecorder[recorder] = allowed;
        // LINT TRIAGE: forge flags missing-events-access-control here, but the
        // very next line emits RecorderUpdated — heuristic false positive.
        emit RecorderUpdated(recorder, allowed);
    }

    /// @notice Record a contribution. On-time extends the streak; late resets
    ///         it (a late payment breaks reliability, a default — see below —
    ///         additionally counts against gating). Volume always accumulates.
    function recordContribution(address user, uint256 amount, bool onTime)
        external
        onlyRecorder
    {
        Record storage r = _records[user];
        if (onTime) {
            r.streak += 1;
        } else {
            r.streak = 0;
        }
        r.totalVolumeWei += amount;
        r.lastActive = block.timestamp;
        emit ContributionRecorded(user, amount, onTime, r.streak);
    }

    /// @notice Record a completed circle for a member.
    function recordCompletion(address user) external onlyRecorder {
        Record storage r = _records[user];
        r.completions += 1;
        emit CompletionRecorded(user, r.completions);
    }

    /// @notice Record a default (never-paid obligation). Resets the streak
    ///         AND counts for 2.9 gating; no score subtraction term by design
    ///         (frozen formula has exactly four components).
    function recordDefault(address user) external onlyRecorder {
        Record storage r = _records[user];
        r.streak = 0;
        r.defaults += 1;
        emit DefaultRecorded(user, r.defaults);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ── reads ────────────────────────────────────────────────────────────

    function recordOf(address user) external view returns (Record memory) {
        return _records[user];
    }

    function streakScore(address user) public view returns (uint256) {
        uint256 s = _records[user].streak * STREAK_PER;
        return s > STREAK_MAX ? STREAK_MAX : s;
    }

    function completionScore(address user) public view returns (uint256) {
        uint256 s = _records[user].completions * COMPLETION_PER;
        return s > COMPLETION_MAX ? COMPLETION_MAX : s;
    }

    function volumeScore(address user) public view returns (uint256) {
        uint256 whole = _records[user].totalVolumeWei / WAD;
        return whole > VOLUME_MAX ? VOLUME_MAX : whole;
    }

    /// @dev LINT TRIAGE: `block.timestamp` comparisons flagged by forge are
    ///      accepted risk — tier edges sit 30/90/180 DAYS apart, so validator
    ///      timestamp games (seconds) cannot flip a tier; moving chain time by
    ///      days gains an attacker nothing (recency caps at 150 of 1000).
    function recencyScore(address user) public view returns (uint256) {
        uint256 last = _records[user].lastActive;
        if (last == 0) return 0;
        uint256 elapsed = block.timestamp - last;
        if (elapsed <= 30 days) return RECENCY_MAX;
        if (elapsed <= 90 days) return 100;
        if (elapsed <= 180 days) return 50;
        return 0;
    }

    function scoreOf(address user) public view returns (uint256) {
        return streakScore(user) + completionScore(user) + volumeScore(user)
            + recencyScore(user);
    }

    function tierOf(address user) public view returns (Tier) {
        uint256 score = scoreOf(user);
        if (score >= 800) return Tier.Diamond;
        if (score >= 600) return Tier.Platinum;
        if (score >= 400) return Tier.Gold;
        if (score >= 200) return Tier.Silver;
        return Tier.Bronze;
    }

    function collateralBips(Tier tier) public pure returns (uint256) {
        if (tier == Tier.Diamond) return 0;
        if (tier == Tier.Platinum) return 100;
        if (tier == Tier.Gold) return 300;
        if (tier == Tier.Silver) return 500;
        return 1000; // Bronze
    }

    function maxCircleSize(Tier tier) public pure returns (uint256) {
        if (tier == Tier.Diamond) return 100;
        if (tier == Tier.Platinum) return 50;
        if (tier == Tier.Gold) return 20;
        if (tier == Tier.Silver) return 10;
        return 5; // Bronze
    }

    /// @notice Max single contribution in whole USDC for a tier.
    function maxContribution(Tier tier) public pure returns (uint256) {
        if (tier == Tier.Diamond) return 50_000;
        if (tier == Tier.Platinum) return 10_000;
        if (tier == Tier.Gold) return 2_000;
        if (tier == Tier.Silver) return 500;
        return 100; // Bronze
    }

    /// @notice Tier enforcement hook for backend 2.9: size + contribution
    ///         ceilings for a user's current tier. Collateral itself is NOT
    ///         enforced here (no staking in V1) — ceilings only.
    function checkEligibility(address user, uint256 size, uint256 contributionUSDC)
        external
        view
        returns (bool ok, uint8 code)
    {
        Tier tier = tierOf(user);
        if (size > maxCircleSize(tier)) return (false, SIZE_EXCEEDS_TIER);
        if (contributionUSDC > maxContribution(tier)) {
            return (false, CONTRIBUTION_EXCEEDS_TIER);
        }
        return (true, ELIGIBLE);
    }
}
