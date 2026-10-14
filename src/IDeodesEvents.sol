// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title IDeodesEvents — canonical EVM event schema for the Deodes indexer.
/// @notice UNIFIED-PLAN 1.9. Twelve events (the plan text says "11" but
///         enumerates twelve — the count is corrected here and in EVENTS.md).
///         Every event carries the circle address indexed first so the 2.6
///         poller filters with a single topic per circle.
///
///         Status: CircleCreated is LIVE (DeodesFactory inherits this
///         interface — the compiler enforces shape-match, so the factory
///         cannot drift from the schema). The other eleven are RESERVED for
///         the circle-lifecycle upgrade: their signatures are FROZEN here so
///         the 2.6 decoder can be built against them today, and
///         test/EventSchema.t.sol fails the build if any signature changes.
///         See EVENTS.md for the V0→canonical mapping and freeze policy.
interface IDeodesEvents {
    event CircleCreated(
        address indexed circle,
        address indexed organizer,
        address treasury,
        uint256 contribution,
        uint256 maxMembers,
        uint256 index
    );
    event MemberJoined(address indexed circle, address indexed member);
    event ContributionReceived(address indexed circle, address indexed member, uint256 amount);
    event PayoutExecuted(address indexed circle, address indexed recipient, uint256 net, uint256 fee);
    event FeeDeposited(address indexed circle, address indexed treasury, uint256 fee);
    event LateReported(address indexed circle, address indexed member, uint256 round);
    event MemberExited(address indexed circle, address indexed member);
    event DefaultRecorded(address indexed circle, address indexed member);
    event CircleCompleted(address indexed circle, uint256 paidCount);
    event AuctionBid(address indexed circle, address indexed bidder, uint256 amount, uint256 round);
    event VoteCast(address indexed circle, address indexed voter, bool support);
    event DisputeRaised(address indexed circle, address indexed raiser, uint256 round);
}
