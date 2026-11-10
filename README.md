# Finchain

Finchain is an EVM Layer 2 built on the upstream OP Stack and settled on Ethereum.
It is the reference chain for the ten Finch agent-economy ERCs
(ERC-8338, 8414, 8419, 8434, 8436, 8444, 8447, 8454, 8468, 8471) and the native
runtime environment for FOGA (Finch OG Agent).

The first public network is **Finchain Sepolia**, settled on Ethereum Sepolia.
Mainnet is a separate, later deployment with its own genesis.

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
- Chain id candidate: **83380** (parameterised; final uniqueness check before genesis). 8338 is excluded.
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
make deploy-l1                       # op-deployer apply (needs a funded deployer key)
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
| `chain/` | Chain parameters, op-deployer workdir (`chain/deployer/`), exported artifacts (`chain/out/`) |
| `keys/` | Key material (git-ignored) and the key policy |
| `node-a/`, `node-b/` | Docker Compose stacks for the two hosts |
| `profiles/` | Runtime profiles: `demo` (fast batches) and `lowcost` (low L1 spend) |
| `scripts/` | Preflight, key generation, intent rendering, deployment, export, verification, funding table |
| `manifests/` | Reference-version manifest schema and template |
| `registry/` | Draft `ethereum-lists/chains` entry |
| `docs/` | Execution brief, runbook, funding model, proof plan, FOGA confirmation policy, acceptance, governance, networking, versions |

## Status

v0.1.1: repository skeleton (scripts are run through `bash`, so the execute bit is not required). Nothing in this repository has been run against
Sepolia yet. Every version in `versions.lock` is a candidate until `make preflight`
and the M1 run have passed. See `docs/acceptance.md` for what "passed" means and
where (local devnet or public testnet) each item has been demonstrated.

## License

Apache-2.0. See `LICENSE`.
