# Canonical EVM Event Schema (UNIFIED-PLAN 1.9)

Source: `src/IDeodesEvents.sol`. Freeze test: `test/EventSchema.t.sol`
(machine-checked against the compiled artifact — any signature change fails
the build). Count correction: the plan text says "11" but enumerates twelve;
the schema carries all twelve.

## Table (indexed args marked *)

| # | Event | topic0 | Status | Emitter |
|---|---|---|---|---|
| 1 | `CircleCreated(circle*, organizer*, treasury, contribution, maxMembers, index)` | `0xd8d91e…08d849` | LIVE | `DeodesFactory` (inherits the interface — compiler-enforced shape match, proven by `test_FactoryEmitsCanonicalTopic`) |
| 2 | `MemberJoined(circle*, member*)` | `0xb168e0…1b119a` | RESERVED | circle-lifecycle upgrade |
| 3 | `ContributionReceived(circle*, member*, amount)` | `0xe482e8…12323b3` | RESERVED | circle-lifecycle upgrade |
| 4 | `PayoutExecuted(circle*, recipient*, net, fee)` | `0x102ce4…112b48` | RESERVED | circle-lifecycle upgrade |
| 5 | `FeeDeposited(circle*, treasury*, fee)` | `0x652893…46a4d1` | RESERVED | circle-lifecycle upgrade |
| 6 | `LateReported(circle*, member*, round)` | `0x8f4c79…0b720` | RESERVED | circle-lifecycle upgrade |
| 7 | `MemberExited(circle*, member*)` | `0x13288d…61a2aff0` | RESERVED | circle-lifecycle upgrade |
| 8 | `DefaultRecorded(circle*, member*)` | `0x491fa3…21bf7` | RESERVED | circle-lifecycle upgrade |
| 9 | `CircleCompleted(circle*, paidCount)` | `0xd645ce…85897e` | RESERVED | circle-lifecycle upgrade |
| 10 | `AuctionBid(circle*, bidder*, amount, round)` | `0x84fd05…877de` | RESERVED | circle-lifecycle upgrade |
| 11 | `VoteCast(circle*, voter*, support)` | `0xcc194f…3d550` | RESERVED | circle-lifecycle upgrade |
| 12 | `DisputeRaised(circle*, raiser*, round)` | `0xe64f7a…111e8` | RESERVED | circle-lifecycle upgrade |

(Full hashes in `test/EventSchema.t.sol` constants.)

## V0 → canonical mapping (for the 2.6 decoder)

V0 is frozen and keeps its own names. The backend poller MUST decode both:

| V0 emission | Canonical meaning | Notes |
|---|---|---|
| `Joined(member)` | `MemberJoined` | circle address = the emitting contract (log `address`, not a topic) |
| `Contributed(member, amount)` | `ContributionReceived` | same; no round in V0 (round = derived off-chain) |
| `PaidOut(recipient, net, fee)` | `PayoutExecuted` + `FeeDeposited` | one V0 log fans out to two canonical handlers; fee leg targets `treasury` |

## Filter design (why this shape)

Every event leads with `address indexed circle`: the poller subscribes with
`topics[0] = <selector> AND topics[1] = <circle>` per watched circle — one
filter per circle, no client-side fan-in. Member-level filters add `topics[2]`.

## Freeze policy (binding)

Any addition, removal, rename, reorder, or indexed↔non-indexed flip requires a
new UNIFIED-PLAN subphase that (1) updates `IDeodesEvents.sol`, (2) updates the
frozen table here + in `EventSchema.t.sol`, (3) updates the 2.6 decoder in the
same release. Silent edits break production indexing — the freeze test exists
to make them loud.
