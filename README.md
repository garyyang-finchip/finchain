# Finchain

Finchain is an EVM Layer 2 built on the upstream OP Stack and settled on Ethereum.
It is the reference chain for the twelve Finch agent-economy ERCs
(ERC-8338, 8414, 8419, 8434, 8436, 8444, 8447, 8454, 8468, 8471, 8489, 8490) and the
native runtime environment for FOGA (Finch OG Agent).

The first public network is **Finchain Sepolia**, settled on Ethereum Sepolia.
Mainnet is a separate, later deployment with its own genesis. `docs/handbook.md` is the
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
| `chain/` | Chain parameters, op-deployer workdir (`chain/deployer/`), exported artifacts and acceptance records (`chain/out/`), pinned contract builds (`chain/contracts/erc8004/`, `chain/contracts/probe/`), the FOGA world configuration and address book for Finchain (`chain/world/`) |
| `keys/` | Key material (git-ignored) and the key policy |
| `node-a/`, `node-b/` | Docker Compose stacks for the two hosts |
| `profiles/` | Runtime profiles: `demo` (fast batches) and `lowcost` (low L1 spend) |
| `scripts/` | Preflight, key generation, intent rendering, deployment, export, verification, funding table |
| `manifests/` | Reference-version manifest schema and template |
| `registry/` | Draft `ethereum-lists/chains` entry |
| `docs/` | Handbook, execution brief, runbook, funding model, proof plan, FOGA confirmation policy, covenant World design (M3), acceptance, governance, networking, versions, chain id |

## Status

v0.2.0-alpha.13: M3 in progress. Finchain Sepolia (chain id 85422) is live: L1 contracts
deployed 2026-11-11 at Sepolia block 12112920 (`chain/out/`), host A sequencing since the
same day, host B verifying independently; M1 and M2 acceptance records are in
`manifests/evidence/`; `versions.lock` is frozen (digests, 2026-11-12). The ERC-8004
identity root is deployed and owned (2026-11-12, `chain/out/erc8004.json`). M3 is three
acceptances (`docs/acceptance.md`, design in `docs/world.md`): Finchain on its own
(`make evm-acceptance`, `make verify-evm`; passed 2026-11-12,
`manifests/evidence/m3a-2026-11-12.json`), FOGA on its own (`make foga-isolation`; passed
2026-11-12 for the released 1.0.7, `manifests/evidence/m3b-2026-11-12.json`), and FOGA on
Finchain as an optional, explicit deployment with the released FOGA package and a world
configuration kept here (`chain/world/`; the reference World was deployed by 1.0.7 on
2026-11-13, verified by host B at a finalized block, and ran the genesis T0-T9 with both
ZK paths and the doctor; the Finch OG Agent lives on the chain since the same day as a cell
of its own at `https://og.finchain.one`, `docs/world.md` section 5.4; the two-cell business
loop is left for a later round). Finchain is usable without FOGA; FOGA runs
without Finchain; no Finchain milestone requires a FOGA release. The road to the chain went
through Sepolia's Glamsterdam rules (EIP-8037 state gas, new L1 header fields, EIP-7976
calldata floor); the adaptations are recorded in `docs/versions.md`. Public RPC:
`https://rpc.finchain.one`.

## License

Apache-2.0. See `LICENSE`.
