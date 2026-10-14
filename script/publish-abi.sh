#!/bin/sh
# Publish versioned ABIs (UNIFIED-PLAN 1.10).
#   ./script/publish-abi.sh          # regenerate abi/v1/ + SHA256SUMS from out/
#   ./script/publish-abi.sh --check  # CI gate: fail if committed ABIs differ
# Backend and frontend MUST import from abi/v1/ (never hand-copied ABIs).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/out"
DEST="$ROOT/abi/v1"
CONTRACTS="DeodesCircle DeodesFactory DeodesTreasury DeodesReputationRegistry DeoToken DeodesGovernance IDeodesEvents"

SOLC="$(grep -E '^solc_version' "$ROOT/foundry.toml" | sed 's/.*"\([^"]*\)".*/\1/')"
OPT="$(grep -E '^optimizer =' "$ROOT/foundry.toml" | sed 's/.*= *//')"
RUNS="$(grep -E '^optimizer_runs' "$ROOT/foundry.toml" | sed 's/.*= *//')"

work="$DEST"
if [ "${1:-}" = "--check" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work"

for c in $CONTRACTS; do
  # shellcheck disable=SC2012
  src="$(ls -d "$OUT"/*/"$c.json" 2>/dev/null | head -n 1)"
  if [ -z "$src" ]; then
    echo "missing artifact for $c (run forge build first)" >&2
    exit 1
  fi
  python3 - "$src" "$work/$c.json" "$c" "$SOLC" "$OPT" "$RUNS" <<'EOF'
import json, sys
src, dst, name, solc, opt, runs = sys.argv[1:7]
art = json.load(open(src))
doc = {
    "contract": name,
    "source": "deodes-contracts (UNIFIED-PLAN 1.10)",
    "solc": solc,
    "optimizer": opt == "true",
    "optimizer_runs": int(runs),
    "abi": art["abi"],
}
json.dump(doc, open(dst, "w"), indent=2)
open(dst, "a").write("\n")
EOF
done

(
  cd "$work"
  sha256sum DeodesCircle.json DeodesFactory.json DeodesTreasury.json \
    DeodesReputationRegistry.json DeoToken.json DeodesGovernance.json \
    IDeodesEvents.json > SHA256SUMS
)

if [ "${1:-}" = "--check" ]; then
  # Compare generated files only (README.md is source, not generated).
  if for f in DeodesCircle.json DeodesFactory.json DeodesTreasury.json \
      DeodesReputationRegistry.json DeoToken.json DeodesGovernance.json \
      IDeodesEvents.json SHA256SUMS; do cmp -s "$work/$f" "$DEST/$f" || exit 1; done; then
    echo "abi/v1 matches out/ -- OK"
  else
    echo "abi/v1 is stale: run ./script/publish-abi.sh and commit" >&2
    exit 1
  fi
else
  echo "published $(ls "$DEST"/*.json | wc -l) ABIs + SHA256SUMS to $DEST"
fi
