# abi/v1 — versioned contract ABIs (UNIFIED-PLAN 1.10)

Regenerate: `./script/publish-abi.sh` (from `out/`). CI gate:
`./script/publish-abi.sh --check`. Manifest: `SHA256SUMS`
(`sha256sum -c SHA256SUMS` verifies). Each file records its solc +
optimizer settings so consumers can prove what they decode against.

## Consumption checklist (no hand-copied ABIs anywhere)

| Consumer | Action | Status |
|---|---|---|
| Backend `pkg/arc/abi.go` (2.6 poller) | import `IDeodesEvents.json` selectors + circle/factory ABIs; `DeodesCircle.json` for V0 decoding | TODO in 2.6 |
| Backend token/governance paths (2.10/2.11) | import `DeoToken.json` + `DeodesGovernance.json` | TODO in 2.10/2.11 |
| Frontend `adapters/arc-evm.ts` (3.1) | generate types from `DeodesCircle.json` + `DeodesFactory.json` | TODO in 3.1 |
| Indexer event map (2.6) | `IDeodesEvents.json` is the decoder input; topic0 values cross-checked against `EVENTS.md` + `test/EventSchema.t.sol` | TODO in 2.6 |

Rule: a consumer reporting an ABI mismatch first re-runs `./script/publish-abi.sh --check`.
Green check + mismatch = consumer bug. Red check = republish and commit.
