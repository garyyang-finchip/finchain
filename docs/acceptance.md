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

M3 closed on 2026-11-13 (finchain 0.2.0): the three acceptances have their records
(`manifests/evidence/m3a-2026-11-12.json`, `m3b-2026-11-12.json`, `m3c-2026-11-13.json`)
and the reference-version manifest `manifests/finchain-sepolia/2026.11-rc1.json` is
published with status `candidate` (D14): M1, M2 and the three M3 acceptances `passed` on
`public-testnet`, M4 and M5 `not-run`. One M3-C row is met at its integration stage only -
the second cell was run by the project owner, not by another operator - and stays open
without blocking the candidate; the candidate becomes `recommended` when M4's items run.

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
| The released FOGA package, installed from the registry into a clean directory with a clean home and every name under `finchain.one` refused, passes the release check's own legs: help, chain table with Sepolia as the default, local quickstart, local genesis T0-T9, packaged Sepolia World read (`make foga-isolation VERSION=<version>`) | `manifests/evidence/foga-isolation-<version>-<date>.json`: legs, every host name used, zero names under `finchain.one`, instrumentation controls; recorded for 1.0.7 (2026-11-12, the baseline), 1.0.8 (2026-11-13) and 1.0.9 (2026-11-13) |
| The same check recorded for every FOGA version Finchain adopts for a run on the chain, before that run; FOGA decides its own releases and release checks | one evidence file per version adopted, beside the baseline |
| An old cell store continued by the package under test (FOGA's own test suite) | FOGA release-check run reference |

### M3-C FOGA on Finchain, an optional explicit integration

| Item | Evidence |
| --- | --- |
| Twelve covenant ERC reference implementations deployed by ordinary transactions from the released FOGA's locked bundle by W, with the world configuration kept in this repository (`chain/world/finchain-sepolia.world.json`, passed with `--world`); `completionBlock` (last needed transaction) and `verifiedAt` (finalized block of the last check) recorded | `chain/world/finchain-sepolia.json` (the address book), manifest `covenantWorld` section: modules, contracts, code hashes, deployment and initialization txs, both blocks |
| Address book consistent with on-chain code at one fixed finalized block: raw code hashes from host B (`make verify-world`); build identity against the released package's bundle; links, permissions and wiring read from the chain | `manifests/evidence/world-verify-61794.json` (host B, finalized block 61794, the identity root's 4 and the World's 55 contracts MATCH, completion block 61548 canonical) and `manifests/covenant-world-finchain-sepolia.json` (build identity against the 1.0.7 bundle, `dependsOn` and initialization transactions per contract, `completionBlock`, `verifiedAt`) |
| Bare `foga join` of the released package still defaults to Sepolia; Finchain is reached only by `--world` and `--rpc` (shown by M3-B's chain-table leg and by the integration run's command lines) | the M3-B evidence file, the command transcripts |
| The OG lives on Finchain as a cell of its own (D8): born by `foga join --world chain/world/finchain-sepolia.json --rpc https://rpc.finchain.one` from the released package (the version with an isolation record), with the Sepolia OG's identity wallet; registered, holding and offering its skills, documents on chain, channel and market joined, served at a public name by its own service beside the Sepolia OG, which is unchanged | `manifests/evidence/og-finchain-2026-11-13.json`: cell account `0x9F7647013499C44B7E0432F5E9e22E4Afd447aD1`, ERC-8004 agent 6, skills tokens 3 and 4, channel and market ids, `https://og.finchain.one` (healthz, manifest and agent card read from outside), both services' `/healthz` answering their own chain |
| Two independent cells complete discovery -> eligibility -> task -> execution -> submission -> acceptance -> payment on Finchain through the public RPC; the second cell run by another operator from the released package with this repository's address book | `manifests/evidence/business-loop-2026-11-13.json` (integration stage, 2026-11-13): the OG as the demander and `cell-b` as the fulfiller, both on 1.0.9, tender 5, six transactions with blocks and fee components, both accounts, the confirmation level of each step (the package's `latest`; the finalized re-read in the fee-lines report), the demo profile. The second cell was joined from the registry's package by this repository's address book at its URL - but by the project owner, not another operator (D9 integration stage); the acceptance stage stays open |
| Organisation, collective decision, safety and dispute scenarios each exercised (genesis T0-T9 on Finchain with the address book) | `manifests/evidence/foga-genesis-finchain-sepolia.json` (the released package's genesis evidence for the reference World: 197 of 197 checks, 213 operations with their transactions, blocks 61597-63560) and `manifests/evidence/foga-doctor-finchain-sepolia.json` (the doctor report: 278 Pass, 0 Fail, 2 Unknown, 25 NotApplicable at block 64557) |
| Funding reported in four lines (identity root, World deployment, genesis, business loop) with the three fee components of each receipt | `manifests/evidence/fee-lines-20261113T151307Z.json` (`make fee-lines`, `scripts/fee-lines.sh`: 292 receipts read through the public RPC; execution fee, L1 data fee and operator fee per line; the seven business-loop receipts FINAL at 83370) and the summary `manifests/evidence/m3c-2026-11-13.json` |

The confirmation and recovery behaviour of a cell on an OP Stack chain
(`docs/foga-confirmation-policy.md`: mock chain, anvil reorg, public Finchain normal path)
is a specification handed to FOGA and accepted on FOGA's side; M3 records what the released
package does about confirmation levels and does not wait for it.

## M4 - proofs and assets

| Item | Evidence |
| --- | --- |
| Resident challenger running on host B against the public chain; games resolved and bonds claimed | `manifests/evidence/games-<date>.json` (`make games`, `scripts/games.sh`: every game of the respected type with its status, the resolving transaction and its sender, the credit each party holds) and the challenger's own log excerpt from host B (`manifests/evidence/challenger-log-<date>.jsonl`). The initial bond is 0 on this deployment (owner's `setInitBond(1, 0)`, 2026-11-11), so the credit columns read zero and the item rests on the resolutions and their sender. Snapshot before any clock expired: `manifests/evidence/games-20261113T181336Z.json` (48 games in progress, one claim each). Done 2026-11-15: the first ten games resolved DEFENDER_WINS by the challenger 72-168 s after their clocks, the chain and the service log naming the same ten transactions - `manifests/evidence/m4-challenger-2026-11-15.json` (index and cross-check), `games-20261115T160409Z.json`, `challenger-log-20261115T162118Z.jsonl`; the bond half moves to the devnet drill |
| K1: Finchain's configuration in the kona-client registry format, merged by the registry's own build script, the derived rollup configuration equal to `rollup.json` | `manifests/evidence/kona-configs-<chainId>-<date>.json` (`make kona-check`, `drill/kona-check.sh`: the three generated files, the probe against the stock and the merged registry, the field-by-field comparison). Done 2026-11-15: `kona-configs-85422-20261115T185730Z.json` - stock registry 55 chains without 85422, merged 56 with it, 28 of 28 fields equal |
| K2: prestate embeds Finchain configuration (hash recorded; embedding verified; the published kona prestate reproduced first) | `manifests/evidence/prestate-<chainId>-<date>.json` (`make prestate`, `drill/prestate.sh`: tag and commit, the recipe, digests of the embedded files, the hash, the embedding check, the upstream reproduction). Done 2026-11-16 on the scratch host: kona-client/v1.9.0 with the K1 files embedded gave `0x038b60ac8db81e83cb87229ef9119b500c5723767806cb93a639d70618cad9fb` (1.86 MB gzip, embedding check PASS, identifier `sepolia/finchain` found), the published `cannon64-kona` `0x03f872c2...6b0b` and its interop variant reproduced bit for bit first - `prestate-85422-20261116T012620Z.json`. The first route's result, `0x03e76631...5af1` from op-program/v1.9.0 (`prestate-85422-20261115T162912Z.json`, 2026-11-15), is superseded: that client cannot follow the current L1 (`docs/proof-plan.md`; the raw header in `l1-header-12141687-20261116T021736Z.json`, `make l1-header`) |
| K2: trace self-check (`run-trace`, `cannon-kona`) passes for a recent block, the client booted from the embedded configuration | `manifests/evidence/run-trace-<date>.json` (`make run-trace`, `drill/run-trace.sh`: the prestate, the image, the trace type and preimage server, the endpoints and shims, the L1 head and L2 block the VM executed, which configuration the client booted from, the verdict) and the service log excerpt (not a substitute for the challenger item). Done 2026-11-16 on the scratch host against the live chain: `run-trace-20261116T080811Z.json` - L2 block 200126 at L1 head 12145948 verified in 542 s by kona-client from prestate `0x038b60ac...d9fb`, with the kona-host built with the chain in its registry (`kona-host-85422-20261116T055801Z.json`, sha256 `7931020b...10c0`) behind `drill/kona-host-wrapper.sh`; `clientBoot.embeddedConfigUsed: true`, no oracle fallback in the guest's output; L1 raw methods synthesised by the shim (133 headers, 66 receipt sets, 0 failures), `eth_getProof` routed to host B. A first run the same day (`run-trace-20261116T045749Z.json`, 502 s) verified the claim with the image's kona-host, which hands the client chain id 0, so that client used the oracle-supplied configuration; it is kept as what it is and is not the closing run |
| K3: full VM dispute drill on an isolated devnet: a `CANNON_KONA` game on an honest root, a dishonest challenger driven down to the leaf, the honest challenger's real `step()` executed on chain, resolution for the honest root | `manifests/evidence/devnet-dispute-<chainId>-<date>.json` (`make devnet-dispute` then `make devnet-resolve`, `drill/devnet/adversary.sh`, schema `finchain.devnet-dispute/1`, `environment: local-devnet`: the devnet and its images, the deployment, the type 8 installation, prestate and kona-host records, the game, every attack transaction, the `step()` transaction and the leaf it disproved, the resolution with credits and anchor root) beside the devnet's own K1/K2 records (`kona-configs`, `prestate`, `kona-host` for chain 854220). Tooling delivered 2026-11-16 (`drill/devnet/`, `docs/proof-plan.md` K3); not run yet. A game won on the clock without a step is not a result for this item |
| K4: minimal integration check against Sepolia (what a Type 8 implementation needs there; a non-default type if deployed at all; the respected game type unchanged) | record to be defined with K3; what K3 established so far: the installation on an op-contracts/v7.0.0 chain is one owner transaction, `DisputeGameFactory.setImplementation(8, FaultDisputeGameImpl, args)` with the prestate among the packed arguments, plus `setInitBond(8, ...)`; and it is playable only once the anchor state registry has left op-deployer's placeholder root (the first `closeGame()` of the permissioned type), which `make games` should read back before any Type 8 game is created |
| Deposit -> proof -> withdrawal end to end with the actual waiting periods recorded | `manifests/evidence/withdrawal-<date>.json` (`make withdraw`, `scripts/withdraw.sh`: the deposit that funded the cycle, the L2 initiation, the covering game, the proof with its output root recomputed against the game's root claim, the finalization; the timeline in hours) |
| Game implementation on the public chain carries a Finchain-embedding prestate (if done; a non-default game type, the respected type unchanged - anything beyond that is a separate decision) | on-chain snapshot |

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
