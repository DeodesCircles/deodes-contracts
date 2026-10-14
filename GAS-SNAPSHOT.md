# V0 Gas Snapshot + Optimizer Decision (Phase 1.2)

Measured 2026-10-14: `forge test --gas-report` (solc 0.8.36, `optimizer=false` — the shipped V0 config) + `forge snapshot` → `.gas-snapshot` (15/15 passing). Comparison run: `forge test --optimize --optimizer-runs 200 --gas-report`.

## 1. Unoptimized (shipped V0 config)

| Function | Min | Avg | Max | Budget (analog) | Verdict |
|---|---|---|---|---|---|
| `join` | 21,329 | 111,339 | 134,016 | < 200,000 (create analog) | PASS |
| `contribute` | 23,545 | 39,310 | 47,412 | < 50,000 (record-payment analog) | PASS |
| `payout` | 24,178 | 84,351 | 123,005 | < 500,000 (execute analog) | PASS (< 200k too) |
| views (`memberCount`…`unpaidCount`) | 2,485 | — | 4,747 | < 10,000 | PASS |
| Deployment size | — | — | 5,459 bytes | < 24,576 (EIP-170) | PASS |

(Budgets adapted from UPGRADE Ph10 `<10k/<50k/<200k/<500k`; V0 has no governance fns so `create_proposal`/`calculate_collateral` rows are N/A until V1.)

## 2. Optimized (`--optimize --optimizer-runs 200`), same tests

| Function | Max | Δ vs unoptimized |
|---|---|---|
| `join` | 133,623 | −0.3% |
| `contribute` | 47,117 | −0.6% |
| `payout` | 121,668 | −1.1% |
| Deployment size | 2,942 bytes | **−46%** |

## 3. Decision (binding)

- **V0 keeps `optimizer=false`.** Runtime gas barely moves (~1%); the 46% deploy-size win is real but activating it changes bytecode, which requires redeploy + re-verify — forbidden under the mainnet freeze (Phase 0.1). V0 already passes every budget row, so there is nothing to buy.
- **V1 sets `optimizer=true, runs=200`** from genesis (`foundry.toml`), with this file's table as the regression baseline: any V1 function exceeding its analog row fails CI (`forge snapshot --check`).
- Reproduce: `forge test --gas-report`; regression check: `forge snapshot --check --fuzz-seed 42` (committed `.gas-snapshot`).
  The pinned seed is mandatory: fuzz gas means drift run-to-run, so an unseeded `--check` is red noise, not signal.
  Proven 2026-10-14: `snapshot` and `test` subcommands derive fuzz inputs
  differently (same seed → different means), so the gate pair must be
  snapshot-write + snapshot-check — never compare `forge test` means
  against the file.

## 4. V1-era baseline (UNIFIED-PLAN 1.4, `optimizer=true, runs=200`)

`foundry.toml` flipped at Factory genesis per §3. `.gas-snapshot` now tracks THIS config; §1 above is the preserved V0-shipped record.

| Function | Max | Budget | Verdict |
|---|---|---|---|
| `createCircle` (incl. child deploy) | 625,246 | < 750,000 (new-circle ceiling) | PASS |
| `join` (via factory circle) | 133,623 | < 200,000 | PASS |
| `contribute` | 47,117 | < 50,000 | PASS |
| `payout` | 121,668 | < 500,000 | PASS |
| `setProtocolTreasury` | 30,512 | < 50,000 (admin analog) | PASS |
| `transferOwnership` | 28,596 | < 50,000 (admin analog) | PASS |
| views (`circleAt` 4,670 / `allCircles` ≤ 16,166 / `circleCount` 2,323) | 16,166 | < 50,000 (paginated read) | PASS |

Note: `createCircle` max is the cold first-deploy (child CREATE ~3 KB optimized). `allCircles` max is a 5-circle page — cost grows with `limit`; indexers MUST page (see `DeodesFactory.allCircles` docs).

## 5. Treasury rows (UNIFIED-PLAN 1.5, `optimizer=true, runs=200`)

| Function | Max | Budget | Verdict |
|---|---|---|---|
| `deposit` | 45,190 | < 50,000 (record analog) | PASS |
| `receive` (plain transfer, V0 fee path) | 45,061 | < 50,000 (record analog) | PASS |
| `withdraw` | 104,878 | < 200,000 (execute analog) | PASS |
| `transferOwnership` | 28,552 | < 50,000 (admin analog) | PASS |

## 6. Reputation rows (UNIFIED-PLAN 1.6, `optimizer=true, runs=200`)

Cold numbers are first-writes per user (fresh storage slots); warm numbers are steady state. Budgets bind the max; averages show the common case.

| Function | Max (cold) | Avg (warm-ish) | Budget | Verdict |
|---|---|---|---|---|
| `recordContribution` (3 cold slots first write) | 93,266 | 42,300 | < 100,000 cold / < 50,000 warm | PASS / PASS |
| `recordCompletion` | 47,899 | 32,890 | < 50,000 | PASS |
| `recordDefault` | 52,862 | 36,668 | < 60,000 (first-write) | PASS |
| `scoreOf` (aggregate, 5 cold SLOADs) | 10,167 | 10,108 | < 15,000 (aggregate view) | PASS |
| `checkEligibility` | 10,874 | 10,688 | < 15,000 (aggregate view) | PASS |
| `setRecorder` | 47,861 | 45,823 | < 50,000 (admin analog) | PASS |

## 7. Governance rows (UNIFIED-PLAN 1.7, `optimizer=true, runs=200`)

`createProposal` max is the cold first-proposal (escrow transfer + full struct init). All rows steady-state green.

| Function | Max | Budget | Verdict |
|---|---|---|---|
| `createProposal` (incl. DEO escrow) | 296,419 | < 500,000 (execute analog) | PASS |
| `castVote` (first vote, cold checkpoint) | 92,790 | < 200,000 (create analog) | PASS |
| `finalize` | 104,839 | < 200,000 | PASS |
| `execute` (param apply + refund) | 126,897 | < 500,000 | PASS |
| `cancelByProposer` | 134,020 | < 200,000 | PASS |
| `cancelByVoters` | 83,798 | < 200,000 | PASS |
| `mint` (first, cold checkpoints) | 95,712 | < 200,000 | PASS |
| `delegate` | 117,548 | < 200,000 | PASS |
| `transfer` | 93,065 | < 200,000 | PASS |

## 8. Pause rows (UNIFIED-PLAN 1.8, `optimizer=true, runs=200`)

| Function | Max | Budget | Verdict |
|---|---|---|---|
| `pause` / `unpause` (all three contracts) | 27,754 | < 50,000 (admin analog) | PASS |
| `createCircle` with `whenNotPaused` | 627,433 | < 750,000 (new-circle ceiling) | PASS (+2.2k vs §4 for the modifier — negligible) |

## 9. Events + ABI + ceremony (1.9–1.11): no runtime code

`IDeodesEvents.sol` is an interface (no bytecode beyond the inheriting
factory, already metered in §4). `abi/v1` publication and `deploy/*.toml` +
`DeployAll` + `CEREMONY.md` are off-chain artifacts — no gas rows apply.
V1 deployments will record first-broadcast gas in `deployments.*.json`.
