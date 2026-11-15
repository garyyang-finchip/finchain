# Mainnet plan (M5)

Status: planning. Nothing is deployed on Ethereum mainnet. What is decided (owner,
2026-11-13): chain id 8454; ETH pays gas and FCT is a governance and utility token; the
mainnet runs on the same two hosts as Finchain Sepolia, as a second stack on each
(`docs/runbook.md` section 9), with other arrangements to follow later. What this document
does: name the decisions still open, the sequence once they are taken, and the gates before
the chain is called live.

## 1. Decisions before deployment

| # | Decision | Options and what they cost |
| --- | --- | --- |
| 1 | Public hostnames | `rpc.finchain.one` / `ws.finchain.one` stay with Finchain Sepolia: they are written into the released FOGA 1.0.9 chain table and into the Sepolia manifest. Mainnet needs names of its own (for example `rpc.mainnet.finchain.one`, `ws.mainnet.finchain.one`, or `mainnet-rpc.finchain.one`); the first chain's Caddy on host B serves them through a shared network (delivered with the mainnet stack). A later FOGA release may rename, with both names served during a transition. |
| 2 | Initial bond of the respected game type | 0 as on Sepolia (owner call after deployment; the permissioned game has only the two trusted roles) or the standard 0.08 ETH: at the steady cadence (4 proposals a day, 7 days to recover) 28 games are in flight, 2.24 ETH locked in bonds. |
| 3 | L1 endpoints for the two hosts | Ethereum mainnet execution and beacon endpoints, one provider per host (independence rule). Free public endpoints do not carry the challenger (`docs/funding-model.md` section 5), so this is a paid plan per host, or the operator's own L1 node, which needs a machine of its own (about 2 TB of disk for execution plus consensus). The plan for the first months is the paid plan; the own node is the later step. |
| 4 | Owner custody | The owner address at deployment: the existing external wallet (the owner console drives it), or a Safe from the first day. The Safe is the M5 target either way; what is decided here is whether the deployment itself happens behind it. |
| 5 | Data availability | Blobs are the standard on mainnet (`--data-availability-type=blobs`, the beacon endpoint already configured); Sepolia runs calldata. Blobs make the batcher's cost a blob-fee line instead of a calldata line in the funding table. |
| 6 | Budget | `make funding-table CHAIN=mainnet GAS_GWEI=<current>` once `.env.mainnet` exists: the deployment (about 56M gas with state gas, measured on Sepolia), daily operations at the steady profile, the bond line of decision 2, and the L2 deposit that funds the World and the first cells. The figure to hold on the deployer before `make deploy-l1` is gas limit times fee cap at that moment. |
| 7 | Prestate | op-deployer deploys the game implementation with its default prestate (`docs/proof-plan.md`: a 32-bit image, registry chains only). The replacement is `make prestate CHAIN=mainnet` after `make export`, then the OPCM's `updatePrestate` by the owner - the same procedure the Sepolia implementation gets first (M4, L3). Decide whether mainnet goes live with the default and is upgraded, or is upgraded before the first public announcement. |
| 8 | FOGA chain table | A FOGA release adds chain 8454 (RPC hostname, explorer) once the chain is live. FOGA never depends on Finchain; the entry is an option offered to cells. |
| 9 | Explorer and registries | An explorer instance for mainnet beside Sepolia's; the `ethereum-lists/chains` entry (`registry/`); the manifest `manifests/finchain-mainnet/`. |

## 2. Sequence once decided

Every command with `CHAIN=mainnet` (`docs/runbook.md` section 9), nothing touching the
first chain's files, volumes or ports:

1. `make init-env CHAIN=mainnet`; fill `.env.mainnet` (chain id 8454, L1 chain id 1, the two
   providers, `PUBLIC_RPC_URL`), `node-a/.env.mainnet` and `node-b/.env.mainnet` (ports,
   `SEQUENCER_HTTP` and `P2P_STATIC_PEERS` at the mainnet ports).
2. `make keys CHAIN=mainnet`: new role keys; fund the deployer and the hot roles on mainnet.
3. `make intent CHAIN=mainnet`, review `chain/mainnet/deployer/intent.toml`;
   `make deploy-l1 CHAIN=mainnet`; `make export CHAIN=mainnet`; commit `chain/mainnet/`.
4. `make secrets-a CHAIN=mainnet`, `make up-a CHAIN=mainnet`; on host B `make install-bundle-b
   CHAIN=mainnet`, `make up-b CHAIN=mainnet`; the Caddy site for the mainnet hostnames.
5. `make verify-onchain CHAIN=mainnet` (`manifests/onchain-mainnet-<block>.json`), the
   initial bond per decision 2, `make prestate CHAIN=mainnet` and `updatePrestate` per
   decision 7.
6. The manifest `manifests/finchain-mainnet/<version>.json`, the registry entry, the
   handbook's mainnet section, the FOGA release.

## 3. Gates before the chain is called live

- The Sepolia withdrawal cycle finalized end to end (M4, due 2026-11-21): the exit path works.
- `make prestate` reproduces the published prestate and the Finchain prestate passes
  `run-trace` against Sepolia games (M4): the replacement implementation is known to work
  before mainnet receives one.
- The two-chain layout proven on the Sepolia hosts without touching the first chain.
- Funding in place for the deployment and three months of operation; owner custody decided.
