# Finchain

Finchain is an EVM Layer 2 built on the upstream OP Stack and settled on Ethereum.
It is the reference chain for the twelve Finch agent-economy ERCs
(ERC-8338, 8414, 8419, 8434, 8436, 8444, 8447, 8454, 8468, 8471, 8489, 8490) and the
native runtime environment for FOGA (Finch OG Agent).

The first public network is **Finchain Sepolia**, settled on Ethereum Sepolia. **Finchain
mainnet** (chain id 8454) is a separate deployment with its own genesis on Ethereum mainnet,
running on both hosts since 2026-11-19 and not yet announced as live (`docs/mainnet.md`). `docs/handbook.md` is the
reader's entry point: chain facts, wallet and developer use, running a verifier node,
how the chain was built.

This repository holds everything needed to deploy and operate the network:
op-deployer intent handling, genesis and rollup artifacts, Docker Compose stacks
for the two operator hosts, runtime profiles, verification scripts, the funding
model, the proof plan, the FOGA confirmation policy, and the acceptance criteria.
No private keys are ever committed.

## Topology

| Host | Role | Services |
| --- | --- | --- |
| **A** (sequencing host) | Sequencing and submission | op-reth (archive), op-node (sequencer), op-batcher, op-proposer |
| **B** (verification host) | Independent derivation and challenge | op-reth (archive), op-node (verifier), op-challenger, Caddy (public RPC at `rpc.finchain.one`) |
| Ethereum Sepolia | Settlement, data availability, finality | external execution RPC per host, beacon API |

Finality comes from Ethereum. A and B are not a two-node BFT committee: A produces
and submits, B re-derives Finchain from L1 data on its own database and L1 data
source and challenges invalid proposals. See `docs/execution-brief.md`.

## Fixed decisions (v0.1)

- Stack: upstream OP Stack, candidate version set in `versions.lock` (verified as a set, then frozen).
- L1: Ethereum Sepolia (chain id 11155111). Intent type `standard-overrides`.
- Chain id: **85422** for Finchain Sepolia (parameterised; registry check done before genesis). 8338 is excluded; 83380 was the first candidate and was replaced before deployment.
- Gas asset: ETH, bridged from Sepolia. No custom gas token in v1.
- Data availability: L1 calldata.
- Genesis: official predeploys and system config only. No pre-minted native ETH on the public testnet; every balance enters through the L1 bridge.
- Covenant World: deployed by ordinary transactions after chain start; the completing block is recorded in the manifest.
- Domain: `finchain.one` (`rpc.finchain.one`, `ws.finchain.one`, `explorer.finchain.one`).

## Quick start (operators)

```bash
cp .env.example .env                 # shared parameters (chain id, domain, L1 endpoints)
cp node-a/.env.example node-a/.env   # host A parameters
cp node-b/.env.example node-b/.env   # host B parameters
make preflight                       # host, Docker, image architecture, flag and L1 checks
make keys                            # generate role keys into keys/ (never committed)
make intent                          # op-deployer init + Finchain overrides -> chain/deployer/intent.toml
make funding-table                   # itemised Sepolia ETH budget for the chosen profile
make deploy-l1                       # L1 contracts (needs a funded deployer key; auto-selects the calldata path on EIP-8037 L1s)
make export                          # genesis.json, rollup.json, L1 addresses -> chain/out/
make verify-onchain                  # on-chain configuration snapshot at a fixed L1 block
make up-a PROFILE=demo               # on host A
make up-b PROFILE=demo               # on host B
make status
```

The full procedure, with expected outputs and acceptance checks, is in
`docs/runbook.md`.

## Repository map

| Path | Content |
| --- | --- |
| `versions.lock` | Candidate version set and image references; digests filled by `make lock` |
| `chain/` | Chain parameters, op-deployer workdir (`chain/deployer/`), exported artifacts and acceptance records (`chain/out/`), pinned contract builds (`chain/contracts/erc8004/`, `chain/contracts/probe/`), the FOGA world configuration and address book for Finchain (`chain/world/`); a second chain lives in `chain/<name>/` and is selected with `CHAIN=<name>` (`docs/runbook.md` section 9) - `chain/mainnet/` is Finchain mainnet's record |
| `keys/` | Key material (git-ignored) and the key policy |
| `node-a/`, `node-b/` | Docker Compose stacks for the two hosts |
| `profiles/` | Runtime profiles: `steady` (fast batches, one proposal every 6 hours; the default), `demo` (hourly proposals), `lowcost` (low L1 spend) and `mainnet` (steady batching, one proposal a day) |
| `scripts/` | Preflight, key generation, intent rendering, deployment, export, verification, funding table |
| `manifests/` | Reference-version manifest schema and template, the published manifests (`finchain-sepolia/`), the on-chain snapshot, the covenant World section, the acceptance evidence |
| `registry/` | Draft `ethereum-lists/chains` entry |
| `docs/` | Handbook, execution brief, runbook, funding model, proof plan, FOGA confirmation policy, covenant World design (M3), acceptance, governance, networking, versions, chain id, mainnet plan (M5) |
| `drill/` | The M4 proof-system exercises for a scratch host: the kona-client registry files and their validation (K1), the Finchain-embedding kona-client prestate and the trace self-check (K2), then the isolated-devnet dispute drill (K3) |

## Status

v0.3.0-alpha.32: **M4 closed on 2026-11-22** (the Sepolia withdrawal finalized, the K4 game resolved
by the `cannon-kona` challenger; the `recommended` manifest follows in v0.3.0) and **Finchain mainnet
(chain id 8454) is deployed on Ethereum mainnet and running on both hosts** (`docs/mainnet.md`: L1 contracts in one transaction at block 26443400 on 2026-11-18,
0.012 ETH; L2 genesis `0xd678...497d`; `chain/mainnet/` is the chain record,
`manifests/onchain-mainnet-26443627.json` the first snapshot; host A sequencing, batching and
proposing once a day since 2026-11-18, `make up-a CHAIN=mainnet PROFILE=mainnet`; host B deriving
from L1 with its challenger since 2026-11-19, `make up-b CHAIN=mainnet`, and the public RPC
`https://rpc.mainnet.finchain.one` served by the first stack's Caddy (`node-b/caddy-sites/`) -
`manifests/evidence/mainnet-start-2026-11-19.json`). The Finchain-embedding prestate for 8454
(`0x03f1d952...b685`, built 2026-11-19 with the K2 pipeline, `manifests/evidence/prestate-8454-*.json`)
is installed as game type 8 since the same day, by the owner with `owner-console.html` (which now
serves both chains) and read back by `make k4-readiness CHAIN=mainnet`
(`manifests/evidence/mainnet-type8-install-2026-11-19.json`), host B's challenger playing it with
`cannon-kona`; a mainnet withdrawal cycle (initiated 2026-11-19), the first Type 8 game (after the
anchor leaves the placeholder, 2026-11-25) and the paid L1 providers follow; the Safe comes at a
later milestone by the owner's ruling; until then the mainnet is not announced as live and nothing
should be bridged to it. M4 on Sepolia: K1-K4 done on the kona-client route (`docs/proof-plan.md`:
the op-program client cannot follow the current Sepolia L1, its prestate `0x03e76631...5af1` is
superseded; `make kona-check` validated Finchain's registry files against the kona-registry crate
on two hosts (K1); `make prestate` built the kona-client prestate with Finchain embedded on
2026-11-16, `0x038b60ac...d9fb`, and `make run-trace` passed the `cannon-kona` self-check against a
live block the same day (K2, `drill/README.md`); K3, the isolated-devnet dispute with a real
`step()`, passed on 2026-11-16 and again on 2026-11-17 with the step in the middle of the trace
(`drill/devnet/`, `manifests/evidence/devnet-dispute-854220-*.json`); K4, the Sepolia integration
check, closed on 2026-11-19: the Type 8 (`CANNON_KONA`) implementation installed by the owner as a
non-default type with the K2 prestate and a 0.08 ETH bond (`owner-console.html`, `make
k4-readiness`), game #74 created by host A's proposer with `make k4-create-game` the moment the
anchor root left op-deployer's placeholder, tracked by host B's `cannon-kona` challenger
(`node-b/docker-compose.kona.yml`, `KONA=1`) without a validation error and resolved
`DEFENDER_WINS` by it on 2026-11-22, 72 s after the clock (`games-20261122T175024Z.json`). `make
withdraw` drives the deposit -> proof -> withdrawal cycle step by step; the withdrawal proven on
2026-11-14 was finalized on 2026-11-22, 0.01 ETH back on L1 after 215.64 h
(`withdrawal-20261113T174622Z.json`), which closed M4 (`docs/acceptance.md`). Every target takes
`CHAIN=<name>` so that the same hosts run a second chain beside the first (`docs/runbook.md`
section 9), which is how the mainnet runs. `make games` reads the dispute games back from L1 -
the resident challenger resolved the first ten games on 2026-11-15, 72-168 s after their clocks,
`manifests/evidence/m4-challenger-2026-11-15.json`; the `steady` profile, the challenger's own
cadence and horizon since alpha.24 (one update cycle a minute, a 14-day game window;
`CHALLENGER_MIN_UPDATE_INTERVAL`, `CHALLENGER_GAME_WINDOW`) and `CHALLENGER_L1_RPC_URL` answer the
L1 rate limiting that report uncovered, `docs/funding-model.md` section 5. v0.2.0 (2026-11-13)
closed M3: the reference-version manifest `manifests/finchain-sepolia/2026.11-rc1.json` is
published with status `candidate` (M1, M2 and the three M3 acceptances passed on public-testnet,
M4 and M5 not run). Finchain Sepolia (chain id 85422) is live: L1 contracts deployed 2026-11-11 at
Sepolia block 12112920 (`chain/out/`), host A sequencing since the same day, host B verifying
independently; M1 and M2 acceptance records are in `manifests/evidence/`; `versions.lock` is
frozen (digests, 2026-11-12). The ERC-8004 identity root is deployed and owned (2026-11-12,
`chain/out/erc8004.json`). M3 is three acceptances (`docs/acceptance.md`, design in
`docs/world.md`): Finchain on its own (`make evm-acceptance`, `make verify-evm`; passed 2026-11-12,
`manifests/evidence/m3a-2026-11-12.json`), FOGA on its own (`make foga-isolation`; passed
2026-11-12 for the released 1.0.7, `manifests/evidence/m3b-2026-11-12.json`), and FOGA on Finchain
as an optional, explicit deployment with the released FOGA package and a world configuration kept
here (`chain/world/`; the reference World was deployed by 1.0.7 on 2026-11-13, verified by host B
at a finalized block, and ran the genesis T0-T9 with both ZK paths and the doctor; the Finch OG
Agent lives on the chain since the same day as a cell of its own at `https://og.finchain.one`,
`docs/world.md` section 5.4; the two-cell business loop ran at its integration stage on
2026-11-13 - the OG minting a tender, a second cell joined from the registry's 1.0.9 by this
repository's address book at its URL taking it, accepted and paid,
`manifests/evidence/business-loop-2026-11-13.json`; the four funding lines read from the
receipts, `make fee-lines`; the M3-C summary is `manifests/evidence/m3c-2026-11-13.json`; the run
by another operator stays open). Finchain is usable without FOGA; FOGA runs without Finchain; no
Finchain milestone requires a FOGA release. The road to the chain went through Sepolia's
Glamsterdam rules (EIP-8037 state gas, new L1 header fields, EIP-7976 calldata floor); the
adaptations are recorded in `docs/versions.md`. Public RPC: `https://rpc.finchain.one`.

## License

Apache-2.0. See `LICENSE`.
