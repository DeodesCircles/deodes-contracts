# Slither Triage (UNIFIED-PLAN 1.8) — run 2026-10-14

Command: `slither . --solc solc-0.8.36 --exclude-dependencies --filter-paths "test|script|lib"`
(slither-analyzer 0.11.6, solc-select 0.8.36, 7 contracts, 102 detectors.)
Raw output: `slither-report-2026-10-14.txt`. Rerun per release; new detectors fail
the 5.7 audit gate until triaged here.

## Verdicts (no HIGH-severity findings; nothing above INFO)

| # | Detector | Location | Verdict |
|---|---|---|---|
| 1 | `arbitrary-send-eth` | `DeodesCircle.payout` → `recipient.call{value: net}` | Known-by-design (V0 frozen): recipient must be a joined member; permissionless payout is the product. Carried in incident report. |
| 2 | `incorrect-equality` | `DeoToken._writeCheckpoint` (`blockNumber == blk`) | Benign: Compound-identical same-block coalescing, equality on checkpoint slot, not funds. |
| 3 | `incorrect-equality` | `recencyScore` (`last == 0`) | Benign: never-active sentinel check. |
| 4 | `low-level-calls` | V0 payout 2× `call`, treasury `withdraw` `call` | Required pattern: only way to move native value; both check `ok`; treasury additionally `nonReentrant` + owner-gated (proven by live reentry test). |
| 5 | `reentrancy-benign` | `createProposal` (transferFrom before writes) | Benign: DEO makes zero external calls (no hooks), so no reentry path exists through it. If DEO ever gains hooks, revisit. |
| 6 | `reentrancy-benign` | V0 `totalCollected = 0` post-call | Known finding, incident report. V0 frozen. |
| 7 | `reentrancy-events` | governance post-call events (7 sites) + V0 `PaidOut` | Accepted: events intentionally log post-transfer state; a revert rolls them back, so no fabricated log can survive a failed transfer. Same class as the treasury NatSpec triage. |
| 8 | `timestamp` | governance windows + recency tiers | Accepted risk (7d/48h, 30/90/180d granularity). NatSpec-noted in code. |

## Absences that matter (explicitly verified, not assumed)

No `reentrancy-eth` on V1 (treasury guarded + tested), no `controlled-delegatecall`,
no `arbitrary-send-eth` on V1 (treasury `withdraw` is owner-gated; governance
refunds go to fixed parties), no missing access-control on state writes, no
`suicidal`/`unprotected-upgrade`. `Pausable` produced zero findings.
