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

## M3 - usable on its own, and the covenant World

Design, boundaries and rules: `docs/world.md`. M3 is three acceptances. The first two are
independent of each other and come first; the third is an integration that a user chooses
and that neither of the first two depends on. No item in this milestone requires a release
of FOGA.

### M3-A Finchain on its own

| Item | Evidence |
| --- | --- |
| Plain L2 transfer through the public RPC from an ordinary key to an ordinary wallet address (`make evm-acceptance`) | `chain/out/evm-acceptance.json`: transaction hash, block, recipient balance delta |
| An ordinary EVM contract unrelated to any covenant (`chain/contracts/probe/FinchainProbe`) deployed, written to and read back through the public RPC: runtime code hash equals the committed build, event emitted, value by call and by storage slot | the same record: deployment and write receipts, code hash, checks |
| Host B re-reads the record at a `finalized` block from its own node: receipts by hash, code hash and storage at the block, call at the block, recipient balance, completing block canonical and finalized (`make verify-evm`) | `manifests/evidence/evm-acceptance-verify-<block>.json` |
| A wallet user sends ETH through `rpc.finchain.one` by hand (MetaMask) | transaction hash in the M3 evidence file |
| ERC-8004 identity root deployed on Finchain (Identity and Reputation registries), verified and owned by the owner address; needed by no node and no wallet | `chain/out/erc8004.json` (checks, code hashes, ownership transfer) |

### M3-B FOGA on its own

| Item | Evidence |
| --- | --- |
| The released FOGA package, installed from the registry into a clean directory with a clean home and every name under `finchain.one` refused, passes the release check's own legs: help, chain table with Sepolia as the default, local quickstart, local genesis T0-T9, packaged Sepolia World read (`make foga-isolation VERSION=<version>`) | `manifests/evidence/foga-isolation-<version>-<date>.json`: legs, every host name used, zero names under `finchain.one`, instrumentation controls; recorded for 1.0.7 (2026-11-12, the baseline) and 1.0.8 (2026-11-13) |
| The same check recorded for every FOGA version Finchain adopts for a run on the chain, before that run; FOGA decides its own releases and release checks | one evidence file per version adopted, beside the baseline |
| An old cell store continued by the package under test (FOGA's own test suite) | FOGA release-check run reference |

### M3-C FOGA on Finchain, an optional explicit integration

| Item | Evidence |
| --- | --- |
| Twelve covenant ERC reference implementations deployed by ordinary transactions from the released FOGA's locked bundle by W, with the world configuration kept in this repository (`chain/world/finchain-sepolia.world.json`, passed with `--world`); `completionBlock` (last needed transaction) and `verifiedAt` (finalized block of the last check) recorded | `chain/world/finchain-sepolia.json` (the address book), manifest `covenantWorld` section: modules, contracts, code hashes, deployment and initialization txs, both blocks |
| Address book consistent with on-chain code at one fixed finalized block: raw code hashes from host B (`make verify-world`); build identity against the released package's bundle; links, permissions and wiring read from the chain | `manifests/evidence/world-verify-61794.json` (host B, finalized block 61794, the identity root's 4 and the World's 55 contracts MATCH, completion block 61548 canonical) and `manifests/covenant-world-finchain-sepolia.json` (build identity against the 1.0.7 bundle, `dependsOn` and initialization transactions per contract, `completionBlock`, `verifiedAt`) |
| Bare `foga join` of the released package still defaults to Sepolia; Finchain is reached only by `--world` and `--rpc` (shown by M3-B's chain-table leg and by the integration run's command lines) | the M3-B evidence file, the command transcripts |
| The OG lives on Finchain as a cell of its own (D8): born by `foga join --world chain/world/finchain-sepolia.json --rpc https://rpc.finchain.one` from the released package (the version with an isolation record), with the Sepolia OG's identity wallet; registered, holding and offering its skills, documents on chain, channel and market joined, served at a public name by its own service beside the Sepolia OG, which is unchanged | `manifests/evidence/og-finchain-2026-11-13.json`: cell account `0x9F7647013499C44B7E0432F5E9e22E4Afd447aD1`, ERC-8004 agent 6, skills tokens 3 and 4, channel and market ids, `https://og.finchain.one` (healthz, manifest and agent card read from outside), both services' `/healthz` answering their own chain |
| Two independent cells complete discovery -> eligibility -> task -> execution -> submission -> acceptance -> payment on Finchain through the public RPC; the second cell run by another operator from the released package with this repository's address book | transaction list, both cell accounts, task id, confirmation level per step, active profile (left for a later round by the decision of 2026-11-13) |
| Organisation, collective decision, safety and dispute scenarios each exercised (genesis T0-T9 on Finchain with the address book) | `manifests/evidence/foga-genesis-finchain-sepolia.json` (the released package's genesis evidence for the reference World: 197 of 197 checks, 213 operations with their transactions, blocks 61597-63560) and `manifests/evidence/foga-doctor-finchain-sepolia.json` (the doctor report: 278 Pass, 0 Fail, 2 Unknown, 25 NotApplicable at block 64557) |
| Funding reported in four lines (identity root, World deployment, genesis, business loop) with the three fee components of each receipt | the M3 evidence file |

The confirmation and recovery behaviour of a cell on an OP Stack chain
(`docs/foga-confirmation-policy.md`: mock chain, anvil reorg, public Finchain normal path)
is a specification handed to FOGA and accepted on FOGA's side; M3 records what the released
package does about confirmation levels and does not wait for it.

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
