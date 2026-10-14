# Access-Control Matrix (UNIFIED-PLAN 1.8 review)

Pre-ceremony authority everywhere is the **deployer EOA Density** (one per network,
fresh keys — see `MAINNET-INCIDENT-REPORT.md`). Post-ceremony target is the
**multisig** (1.11), with day-to-day parameter changes flowing through
governance proposals executed by the multisig after the timelock. Pause and
ownership move in lockstep (`transferOwnership` moves both, enforced in code);
`transferPauseOwnership` alone exists only for ceremony flexibility and its use
must be logged in the ceremony record.

| Contract | Function | Who (pre-ceremony) | Who (post-ceremony) | Notes |
|---|---|---|---|---|
| Factory | `setProtocolTreasury` | deployer | multisig | affects only future circles; deployed circles immutable |
| Factory | `transferOwnership` | deployer | multisig (moves pause too) | zero address rejected |
| Factory | `pause/unpause` | deployer | multisig | freezes `createCircle` only; reads open |
| Factory | `createCircle` | anyone | anyone | permissionless by design; bounds-checked |
| Treasury | `withdraw` | deployer | multisig | every movement event-logged; rogue owner visible |
| Treasury | `deposit/receive` | anyone (payable) | anyone | paused as a unit with withdraw |
| Treasury | `transferOwnership` | deployer | multisig (moves pause too) | → timelock when 1.7-timelock contract exists |
| Treasury | `pause/unpause` | deployer | multisig | full freeze (accepts + releases nothing) |
| Registry | `setRecorder` | deployer | multisig | circles/factory registered post-deploy |
| Registry | `record*` | recorders only | recorders only | `NotRecorder` otherwise; reads permissionless |
| Registry | `transferOwnership` | deployer | multisig | no pause surface (allowlist is the control) |
| DEO | `mint` | deployer | multisig/timelock | hard cap 1B; every mint emits `Transfer(0x0,…)` |
| DEO | `transferOwnership` | deployer | multisig/timelock | no pause surface by design (would brick escrow/votes) |
| DEO | `transfer/approve/transferFrom/delegate` | anyone (holder) | anyone | standard ERC-20 + delegation |
| Governance | `setTreasury` | deployer | multisig | operational, not votable (yet) |
| Governance | `transferOwnership` | deployer | multisig (moves pause too) | → timelock contract when one exists |
| Governance | `pause/unpause` | deployer | multisig | freezes propose/vote/finalize/execute; **cancels stay open** |
| Governance | `createProposal/castVote` | anyone with (snapshot) power | anyone | zero-power reverts |
| Governance | `finalize/execute/cancelByVoters` | anyone | anyone | guard-gated (window/timelock/threshold) |
| Governance | `cancelByProposer` | proposer only | proposer only | cooperative, refunds |
| V0 Circle | — (none) | — | — | frozen; `organizer`/`NotOrganizer` unused |

## Residue risks (carried to 5.7)

1. Pre-ceremony single-EOA Density on every contract (same class as the V0 incident) — cleared only by an executed 1.11 ceremony with on-chain ownership reads recorded.
2. No timelock *contract* exists in V1 scope: timelockDelay lives inside governance for params, but contract-ownership moves are multisig-operations, not proposal-executions. A dedicated timelock is future work — recorded, not silently assumed.
3. `setTreasury`/`setRecorder`/mint are multisig-operational forever (not votable) — acceptable; changing that is a new subphase.
