# Deodes Contracts (Arc EVM, Foundry)

V0: minimal rotating-savings circle (ROSCA). One contract, `src/DeodesCircle.sol` — members `join`/`contribute` a fixed native-USDC amount (18 decimals); anyone can trigger `payout(recipient)` for one unpaid member; 0.5% (`FEE_BPS=50`) goes to `treasury`. Rotation-without-repeat enforced on-chain.

> Status: **V0 frozen** — see `MAINNET-INCIDENT-REPORT.md` (testnet-on-mainnet diagnosis), `GAS-SNAPSHOT.md` (budgets + optimizer decision). V1 (Factory/Treasury/Reputation/Governance) is UNIFIED-PLAN 1.4–1.11. Do not redeploy V0.

## Deployments (source of truth)

| Network | Chain ID | Address | Block | Verified |
|---|---|---|---|---|
| Arc testnet | 5042002 | `0x70A7CCB7b5fe856384Aab3aAF553E09A10AF14A4` | 67131574 | yes (explorer API confirmed, solc 0.8.36, optimizer off) |
| Arc mainnet | 5042 | `0x70A7CCB7b5fe856384Aab3aAF553E09A10AF14A4` | 25898475 | claimed in `deployments.mainnet.json`, unconfirmed (explorer Cloudflare-blocked for bots — confirm in browser) |

Constructor args (both chains): treasury `0x51b45Ba8570551e0D1fe818227d8bAa8b556694D`, contribution `10000000000000000000` (10 USDC), maxMembers `5`. On-chain state 2026-10-14 (via `cast`): `memberCount 0, paidCount 0, balance 0` on **both** chains — pristine, nothing to migrate.

Full JSON: `deployments.testnet.json`, `deployments.mainnet.json`, `broadcast/Deploy.s.sol/{5042002,5042}/run-latest.json`.

## End-to-end wiring (TREASURY → explorer)

1. **Env (never commit real values):**
   ```sh
   export TREASURY=0xYourWallet            # protocol-fee vault (MUST differ from keeper escrow, Phase 0.6)
   export CONTRIBUTION_WEI=10000000000000000000  # 10 USDC, 18 decimals
   export MAX_MEMBERS=5
   export RPC_URL=https://rpc.testnet.arc.io   # testnet first — mainnet V0 frozen
   ```
2. **Deploy (key stays in YOUR terminal):**
   ```sh
   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
   # forge prompts for the key via --account (preferred) — never paste --private-key into chat/logs
   ```
3. **Record:** copy `contractAddress`/tx/block/args into `deployments.{testnet,mainnet}.json` (same schema as existing entries).
4. **Verify:** `forge verify-contract <address> src/DeodesCircle.sol:DeodesCircle --chain-id <5042002|5042> --compiler-version v0.8.36 --optimizer-runs 0 ...` (optimizer off for V0); explorer must show a green check before any frontend/backend wiring.
5. **Wire:** backend `DEODES_CIRCLE_ADDRESS` + `DEODES_TREASURY_ADDRESS` (see `deodes-backend/.env.example`); frontend `NEXT_PUBLIC_DEODES_CONTRACT_ID` (see `DEODES/.env.example`). Helpers fail fast: backend `checkMainnetIssues`, frontend `requireContractId()`.
6. **Explore:** testnet `https://explorer.testnet.arc.io/address/<address>`, mainnet `https://explorer.arc.io/address/<address>`. ABI: `out/DeodesCircle.sol/DeodesCircle.json`.

## Develop

```sh
forge build                 # solc 0.8.36, optimizer off (V0-frozen config)
forge test                  # 15 tests: join/contribute/payout, fee fuzz, rotation invariant
forge test --gas-report     # compare against GAS-SNAPSHOT.md before touching src/
forge snapshot --check --fuzz-seed 42  # CI regression gate (committed .gas-snapshot; seed pinned — unseeded checks drift on fuzz means)
forge fmt --check
cast call 0x70A7... "memberCount()(uint256)" --rpc-url https://rpc.testnet.arc.io
```

Docs: [Foundry book](https://book.getfoundry.sh/). Canonical plan: `/root/UNIFIED-PLAN.md`.
