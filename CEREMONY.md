# V1 Deployment Ceremony Runbook (UNIFIED-PLAN 1.11)

Two operators required for mainnet. Every step logs tx hashes below; the
ceremony is done only when §7 reads green on-chain.

## 0. Preconditions

- [ ] `deploy/{testnet,mainnet}.toml` reviewed; `ceremony.multisig` is a REAL
      multisig (not EOA, not REPLACE-ME); it differs per network and differs
      from keeper escrow (0.6) and from the V0 treasury `0x51b45B…` (fresh start).
- [ ] FRESH deployer key per network (`cast wallet new --account <net>-deployer`;
      never reuse across chains — see `MAINNET-INCIDENT-REPORT.md`).
- [ ] Deployer funded with native USDC for gas + deployment (~0.5 USDC buffer).
- [ ] `forge build` clean, `forge test` 95+ green, `GAS-SNAPSHOT.md` current.

## 1. Broadcast (order is load-bearing)

```sh
export RPC_URL=https://rpc.testnet.arc.io   # or mainnet (2 operators present)
forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --account <net>-deployer
```

Record (fill as you go):

| Contract | Address | Deploy tx | Block |
|---|---|---|---|
| Treasury | | | |
| DEO token | | | |
| Registry | | | |
| Factory | | | |
| Governance | | | |

## 2. Verify (each contract, green check before proceeding)

```sh
forge verify-contract <addr> src/DeodesTreasury.sol:DeodesTreasury --chain-id <5042002|5042> --compiler-version v0.8.36 --verifier blockscout --verifier-url <explorer>/api/
# … repeat for DeoToken, DeodesReputationRegistry, DeodesFactory
# (--constructor-args $(cast abi-encode "constructor(address)" <treasury>) for Factory),
# DeodesGovernance (--constructor-args $(cast abi-encode "constructor(address,address)" <token> <treasury>))
```

## 3. Record in `deployments.{testnet,mainnet}.json`

Append one entry per contract in the V0 schema + `deployer` + `ceremonyTx`
(ownership-transfer hash from §4). Schema example:

```json
{"chain":"arc-testnet","chainId":5042002,"contract":"DeodesFactory",
"address":"0x…","deployTx":"0x…","block":0,
"constructorArgs":{"protocolTreasury":"0x…"},
"compiler":"v0.8.36","optimizer":true,"optimizerRuns":200,
"evmVersion":"osaka","license":"Apache-2.0","verified":true,
"explorer":"https://explorer.testnet.arc.io/address/0x…",
"deployer":"0x…","ceremonyTx":"0x…"}
```

## 4. Ownership handover (auditable txs, multisig executes its own acceptance)

From the DEPLOYER, one tx per contract (use `cast send … --account`):

1. `treasury.transferOwnership(<multisig>)` (moves pause too — lockstep)
2. `token.transferOwnership(<multisig>)`
3. `registry.transferOwnership(<multisig>)`
4. `factory.transferOwnership(<multisig>)` (moves pause too)
5. `gov.transferOwnership(<multisig>)` + `gov.setTreasury(<treasury>)` if changed (moves pause too)

Record all five `ceremonyTx` hashes in §1 + the deployments entries.

## 5. Wiring

- `registry.setRecorder(<factory>, true)` (+ first circles when they exist) from multisig.
- Backend: `DEODES_CIRCLE_ADDRESS`/`DEODES_TREASURY_ADDRESS` (0.5/2.5); frontend `NEXT_PUBLIC_DEODES_CONTRACT_ID` (3.1).
- Keeper escrow MUST NOT equal treasury — the mainnet guard (0.6) rejects it.

## 6. Operating model (binding until a timelock contract exists)

No timelock *contract* ships in V1 scope (see `ACCESS-MATRIX.md` residue risk 2):
param changes flow as governance proposals → pass timelock → the MULTISIG
executes the corresponding action. `setTreasury`/`setRecorder`/mint stay
multisig-operational. Changing this model is a new subphase.

## 7. Close-out reads (all must print the multisig)

```sh
for c in <treasury> <token> <registry> <factory> <gov>; do
  cast call $c "owner()(address)" --rpc-url $RPC_URL
done
cast call <factory> "protocolTreasury()(address)" --rpc-url $RPC_URL
cast call <gov> "treasury()(address)" --rpc-url $RPC_URL
```

Rollback: chains are pristine for V1 (fresh addresses) — a failed ceremony
redeploys; NEVER reuse a compromised ceremony's keys or addresses.
