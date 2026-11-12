# Acceptance criteria

Every item is recorded in the manifest with `result` and `environment`
(`local-devnet`, `public-testnet`, `mainnet`) and a path to the evidence. A result obtained
locally is never recorded as a public-testnet result. "Verified" means read from the chain
or reproduced, not read from a configuration file.

## M1 - chain is up

| Item | Evidence |
| --- | --- |
| Genesis published: `genesis.json`, `rollup.json`, L2 genesis hash, L1 anchor, rollup config hash | `chain/out/chain-record.json`, committed |
| Locked versions and actual L1 addresses published | `versions.lock`, `chain/out/l1-addresses.json`, `manifests/onchain-<block>.json` |
| Continuous block production (2 s) and transaction execution; production resumes after a restart of host A | `make status-a` output before/after restart |
| Batches on L1 with the calldata DA type | first batcher transaction hash, `safe` head advancing |
| First output proposal of the respected game type | game address and type from the factory; type equals the on-chain respected game type |
| Measured deployment cost and funding table for the active profile | `chain/out/deployment.json`, funding table output |

## M2 - independently verifiable

| Item | Evidence |
| --- | --- |
| Host B derives the same block hash and state root as host A at the same height (`finalized`) | `scripts/compare-heads.sh` output |
| `safe` and `finalized` advance on both hosts; the delays match the profile | sync status samples with timestamps |
| L1 -> L2 deposit credited through `OptimismPortal` | L1 tx hash, L2 balance before/after |
| Rebuild from L1 only: empty data volumes, no p2p peers, public genesis/rollup config and L1 data; reaches the target `finalized` height with identical hash and state root; A's database is not used | `manifests/evidence/rebuild-from-l1-*.json` |
| Public RPC answers over TLS at `rpc.finchain.one` with the chain id | curl transcript |
| Host B uses its own L1 provider and data volumes | `node-b/.env` (provider differs from A), volume names |

## M3 - covenant World and FOGA

| Item | Evidence |
| --- | --- |
| Twelve covenant ERC reference implementations deployed by ordinary transactions; completing block number and hash recorded | manifest `covenantWorld` section: contracts, code hashes, deployment and initialization txs |
| Address book published and consistent with on-chain code hashes | address book URI, verification script output |
| FOGA chain configuration for Finchain merged in the FOGA repository | commit reference |
| Two independent cells complete discovery -> eligibility -> task -> execution -> submission -> acceptance -> payment | transaction list |
| Organisation, collective decision, safety and dispute scenarios each exercised | per-scenario transaction lists |
| Rollback, resend and duplicate-event tests pass per `docs/foga-confirmation-policy.md` | test records (devnet for the induced rollback) |

## M4 - proofs and assets

| Item | Evidence |
| --- | --- |
| Resident challenger running on host B against the public chain; games resolved and bonds claimed | challenger logs, resolution txs |
| Trace self-check (`run-trace`) passes for a recent game | command output (not a substitute for the previous item) |
| Full VM dispute drill with adversarial driver: real `step()` executed, invalid root rejected | `docs/proof-plan.md` evidence list, `environment: local-devnet` |
| Prestate embeds Finchain configuration (hash recorded; embedding verified) | prestate hash, build log |
| Deposit -> proof -> withdrawal end to end with the actual waiting periods recorded | tx list and timestamps |
| Game implementation on the public chain carries a Finchain-embedding prestate (if done) | on-chain snapshot |

## M5 - mainnet readiness (planning items, not v0.1 deliverables)

Permissionless proofs, sequencer HA (op-conductor), governance key custody (Safe),
standalone vs shared SuperchainConfig decision, external assessment, mainnet chain id and
sovereignty arrangements frozen before mainnet deployment.

## Definitions

- **unsafe / safe / finalized**: op-node labels; `finalized` requires the L1 blocks carrying
  the batch data to be finalized.
- **Rebuild from L1 only**: reproduce the chain to a stated `finalized` height from the
  public genesis, rollup configuration, starting anchor and obtainable L1 history, on empty
  volumes, without host A's database, snapshots or result RPC except for the final hash
  comparison.
- **Respected game type**: the game type the portal accepts for withdrawals, read from the
  portal or anchor state registry at a fixed L1 block.
