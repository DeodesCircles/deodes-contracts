# MAINNET INCIDENT REPORT — V0 DeodesCircle on Arc Mainnet (Phase 0.1)

Status: INVESTIGATED 2026-10-14. Decision: **FREEZE mainnet V0** (no funds, no further V0 deploys). V1 must use per-env deploys (UNIFIED-PLAN 1.11).

## 1. What happened (verified, no guesswork)

- Same contract `DeodesCircle` (`src/DeodesCircle.sol:10`, `FEE_BPS=50`, `pragma ^0.8.24`) deployed on **both** chains at the **same address** `0x70A7CCB7b5fe856384Aab3aAF553E09A10AF14A4`:
  - testnet (`deployments.testnet.json`): chain `arc-testnet`, chainId `5042002`, tx `0xed5ad7e5599d1fd9faa39d85c43b942f2599fd20bed66b27cbe53e1edf60373f`, block `67131574` (`0x40058b6`), `verified:true`.
  - mainnet (`deployments.mainnet.json:1-22`): chain `arc-mainnet`, chainId `5042`, tx `0xab14fe1864126da7fcf447899ab9f9c7ea6ffc2ed184ce2210c5a096bebf19bd`, block `25898475` (`0x18b2deb`), `verified:true`.
- Broadcast receipts confirm (`broadcast/Deploy.s.sol/5042002/run-latest.json:4-23` vs `5042/run-latest.json:4-23`):
  - Both `transactionType: CREATE` (plain `new DeodesCircle(...)`, **not** CREATE2), same `from` `0x51b45ba8570551e0d1fe818227d8baa8b556694d`, same `nonce: 0x0`, same args `[treasury 0x51b45B..., 10000000000000000000, 5]`, same `gas 0x1394fe`, `status 0x1`.
  - Timestamps ~33.5 min apart: testnet `1791966923106` → mainnet `1791968933177`. Testnet first, mainnet second.
- Identical constructor args both chains: treasury `0x51b45Ba8570551e0D1fe818227d8bAa8b556694D` (= deployer EOA), `contributionWei 10e18` (10 USDC, 18 dec), `maxMembers 5`.
- Compiled artifact: `out/DeodesCircle.sol/DeodesCircle.json` ABI 29 entries, bytecode 10728 hex chars (~5.3 KB), `foundry.toml solc 0.8.36 optimizer=false`, `evmVersion osaka`.

## 2. Why the same address (root cause)

CREATE-address rule: `address = keccak256(RLP(sender, nonce))[12:]`. The operator reused **one fresh EOA** (nonce 0) on **both** chains via `script/Deploy.s.sol:20-21` (`vm.startBroadcast(); new DeodesCircle(...)`). First tx on each chain (nonce 0, same sender) deterministically yields the same address. This is expected EVM behavior — **not** a collision bug and **not** CREATE2. Implication: the same private key controls `organizer` (= deployer, `DeodesCircle.sol:47`) and `treasury` on both chains.

## 3. Why this is an incident

- Contract header declares `V0 learning deployment for Arc TESTNET only` (`DeodesCircle.sol:5`), yet a mainnet deployment exists and is verified. Policy violated.
- `payout(recipient)` is **permissionless** (`DeodesCircle.sol:77-93`: anyone can trigger; only rotation-without-repeat enforced). On mainnet with real funds, any caller can force payout order.
- Immutable risk surface: `treasury/contribution/maxMembers` immutable, `FEE_BPS` constant — no governance setter, no pause, no ownable. `organizer == treasury` single EOA: one key compromise drains fees + controls deploys on both chains.
- Unoptimized (`optimizer=false`): 2–5x gas overhead vs Phase 1.2 budgets.
- `evmVersion osaka`: Arc hardfork support for Osaka opcodes unproven in-repo (see UNIFIED-PLAN T3).
- `forge build` (2026-10-14) emits `reentrancy-events` lint: `emit PaidOut` after external calls (`DeodesCircle.sol:87-92`), and `totalCollected = 0` is set *after* the two `.call`s. `hasBeenPaid`/`paidCount` are set before (good), but the post-call state write + event is a findings-grade reentrancy smell for the Phase 5.7 audit.
- V0 test suite (`test/DeodesCircle.t.sol`, 15/15 passing 2026-10-14) proves `RotationComplete` is unreachable while `members.length` only grows: `paidCount` (paid members) can never exceed length, and any unpaid-member recipient passes the first two checks with `paidCount < length`. Defense-in-depth, not a live branch — V1 factory must decide whether to keep it.
- `forge build` lint triage 2026-10-14 (all V0-only; V0 frozen, findings carry to the Phase 5.7 audit):
  - `reentrancy-events` (`DeodesCircle.sol:92` + post-call `totalCollected = 0`): findings-grade, see §3-adjacent note above.
  - `arbitrary-send-eth` (`DeodesCircle.sol:89` recipient call): known-by-design (permissionless payout, §3) — V1 must gate or document.
  - `missing-zero-check` (`payout(address recipient)`): benign — recipient must be a joined member, and members are `msg.sender` EOAs (never zero). No fix in V0.
  - `DeodesFactory.sol`: zero lint warnings.
  - `DeodesReputationRegistry.sol` (1.6): `missing-events-access-control` on `isRecorder` is a false positive (`RecorderUpdated` emitted next line, NatSpec-noted); `block-timestamp` on recency tiers accepted risk (30/90/180-day edges make validator time games irrelevant, NatSpec-noted).
  - `DeoToken`/`DeodesGovernance` (1.7): `block-timestamp` on vote/timelock windows accepted risk (7d/48h granularity, NatSpec-noted); one `environment-read-across-mutation` on `execute()` is a false positive (no cheatcodes in src); `unsafe-typecast` on `uint32(block.number)` accepted (4.29B-block wrap horizon, NatSpec-noted); 9 remaining `environment-read-across-mutation` hits are all in `test/*.t.sol` (vm.roll patterns, no src impact).
  - `DeodesTreasury.sol` (1.5): `reentrancy-eth` + `reentrancy-events` on `withdraw` triaged as heuristic false positives — custom `nonReentrant` lock engages pre-body (proven by `test_ReentrantWithdrawFailsOnLockNotAuth`, inner fails on `Reentrant` not auth), effects precede interaction, post-call event logs post-transfer balance and reverts with failed transfers. Triage recorded in code NatSpec.

## 4. Funds check (operator action, requires RPC)

Resolved 2026-10-14 via `cast` (no migration needed):

- Testnet (`rpc.testnet.arc.io`, chainId `0x4cef52` = 5042002 ✓): `memberCount 0, paidCount 0, totalCollected 0, balance 0`.
- Mainnet (`rpc.mainnet.arc.io`, chainId `0x13b2` = 5042 ✓): `memberCount 0, paidCount 0, balance 0`.
- Testnet explorer API: `is_verified True, compiler v0.8.36, optimization False` — matches `deployments.testnet.json`.
- Mainnet explorer API unreachable programmatically (Cloudflare challenge); `deployments.mainnet.json` claims `verified:true` — operator to confirm in browser. Freeze stands regardless: **both deployments pristine, zero members, zero funds.**

Supersedes the manual `cast` commands below (kept for re-checks):

```sh
cast balance 0x70A7CCB7b5fe856384Aab3aAF553E09A10AF14A4 --rpc-url https://rpc.arc.io
cast call 0x70A7CCB7b5fe856384Aab3aAF553E09A10AF14A4 "paidCount()(uint256)" --rpc-url https://rpc.arc.io
cast call 0x70A7CCB7b5fe856384Aab3aAF553E09A10AF14A4 "memberCount()(uint256)" --rpc-url https://rpc.arc.io
```

If balance > 0 or `paidCount/memberCount` > 0 on mainnet: treat as live-funds incident (coordinate withdrawals, do NOT redeploy over the address). If zero: keep frozen, leave untouched.

## 5. Freeze decision (binding)

- No further V0 deploys. No testnet-key reuse on mainnet. No funds to mainnet V0.
- V1 (UNIFIED-PLAN 1.4–1.11): fresh per-env keys, distinct addresses per chain, `Factory + Treasury + timelock`, `optimizer=true`, verify on deploy, multisig ceremony.
- This file is the 0.1 completion evidence.
