# Mainnet plan (M5)

Status: planning. Nothing is deployed on Ethereum mainnet. What is decided (owner,
2026-11-13): chain id 8454; ETH pays gas and FCT is a governance and utility token; the
mainnet runs on the same two hosts as Finchain Sepolia, as a second stack on each
(`docs/runbook.md` section 9), with other arrangements to follow later. The nine decisions
below were taken on 2026-11-15 (owner and advisor); what this document does is record them
with their reasons, the sequence that follows from them, the isolation rules the second
stack must satisfy on the shared hosts, and the gates before the chain is called live.

Mainnet preparation proceeds in parallel with the M4 proof work (`docs/proof-plan.md`, K1 to
K4) and does not wait for it. Public statements about bridging, withdrawals or security do.

## 1. Decisions

| # | Decision | What was decided and why |
| --- | --- | --- |
| 1 | Public hostnames | `rpc.mainnet.finchain.one` and `ws.mainnet.finchain.one`. `rpc.finchain.one` / `ws.finchain.one` stay with Finchain Sepolia: they are written into the released FOGA chain table and into the Sepolia manifest, and renaming a live testnet buys nothing. The first chain's Caddy on host B serves both sets of names (section 3, ingress). |
| 2 | Initial bond of the respected game type | The standard 0.08 ETH, not zero: zero was a testnet measure for a game type with two trusted roles, and mainnet bonds are what a challenger is paid with. Verified against the deployment parameters before `make deploy-l1`. Capital in flight at the steady cadence (4 proposals a day): a bond is locked for the game's clock (3.5 days) plus the DelayedWETH withdrawal delay (7 days), about 10.5 days, so about 42 games and 3.36 ETH are in flight at any time; `docs/funding-model.md` carries the line and the funding table includes it (decision 7). |
| 3 | L1 endpoints for the two hosts | Paid providers first, the operator's own L1 node later (a machine of its own, about 2 TB for execution plus consensus). One provider per host, execution and beacon endpoints each (the A/B independence rule); free public endpoints do not carry the challenger (`docs/funding-model.md` section 5). Added by the proof work: the endpoint of any host that runs the `cannon-kona` challenger, or `run-trace`, must serve `debug_getRawHeader` and `debug_getRawReceipts` (kona-host reads raw RLP; `docs/proof-plan.md`), which is a selection criterion for the provider and the plan. |
| 4 | Owner custody | A Safe is the owner from genesis (2-of-3), not a later migration. The deployment hot wallet is only the executor of the deployment transactions and holds no role afterwards; whatever op-deployer must receive as the owner address at deployment is the Safe's. |
| 5 | Data availability | Blobs first (`--data-availability-type=blobs`, the beacon endpoint already configured; the batcher's cost is then a blob-fee line), with calldata as the fallback - verified on Sepolia before it is relied on, including what op-batcher's `auto` mode does when it switches, so that the fallback is a known state and not a surprise. |
| 6 | Prestate at launch | The default prestate op-deployer installs (a 32-bit image, registry chains only; `docs/proof-plan.md`) is acceptable only as an internal stage: the chain may run with it while the Finchain-embedding kona-client prestate and its game implementation are prepared (`make prestate CHAIN=mainnet` after `make export`, then the OPCM's `updatePrestate` by the owner), and is not announced as live before that. The proof route and its acceptance are M4's (K1 to K4). |
| 7 | Budget | `make funding-table CHAIN=mainnet GAS_GWEI=<current>` once `.env.mainnet` exists: the deployment (about 56M gas with state gas, measured on Sepolia), daily operations at the steady profile, the bond line of decision 2 at the 10.5-day cycle, the L2 deposit that funds the World and the first cells, and an emergency reserve (a dispute that has to be answered, a provider change, a replacement host). The figure to hold on the deployer before `make deploy-l1` is gas limit times fee cap at that moment. |
| 8 | FOGA chain table | FOGA 1.1.0 adds chain 8454 (RPC hostname, explorer) after the chain has run stably, as an incremental release; FOGA never depends on Finchain, the entry is an option offered to cells. |
| 9 | Explorer and registries | An explorer instance for mainnet beside Sepolia's; the `ethereum-lists/chains` entry (`registry/`); the manifest `manifests/finchain-mainnet/`. |

## 2. Sequence

Every command with `CHAIN=mainnet` (`docs/runbook.md` section 9), nothing touching the
first chain's files, volumes or ports:

1. `make init-env CHAIN=mainnet`; fill `.env.mainnet` (chain id 8454, L1 chain id 1, the two
   providers, `PUBLIC_RPC_URL=https://rpc.mainnet.finchain.one`), `node-a/.env.mainnet` and
   `node-b/.env.mainnet` (ports, `SEQUENCER_HTTP` and `P2P_STATIC_PEERS` at the mainnet
   ports). The example files carry Sepolia's values; every `CHAIN=<name>` command refuses an
   env that still has Finchain Sepolia's chain id or slug (`scripts/common.sh`).
2. `make keys CHAIN=mainnet`: new role keys; the Safe created and its signers verified; fund
   the deployer and the hot roles on mainnet per the funding table.
3. `make intent CHAIN=mainnet`, review `chain/mainnet/deployer/intent.toml` (owner = the Safe,
   initial bond, blobs); `make deploy-l1 CHAIN=mainnet`; `make export CHAIN=mainnet`; commit
   `chain/mainnet/`.
4. `make secrets-a CHAIN=mainnet`, `make up-a CHAIN=mainnet`; on host B `make install-bundle-b
   CHAIN=mainnet`, `make up-b CHAIN=mainnet`; the Caddy sites for the mainnet hostnames.
5. `make verify-onchain CHAIN=mainnet` (`manifests/onchain-mainnet-<block>.json`), the
   initial bond and the owner verified, `make prestate CHAIN=mainnet` and `updatePrestate`
   per decision 6.
6. The manifest `manifests/finchain-mainnet/<version>.json`, the registry entry, the
   handbook's mainnet section, the FOGA 1.1.0 release after stability.

A dry run of steps 1 to 5 on the Sepolia hosts with a throwaway chain name (and no L1
deployment: `make intent` and the compose rendering only) precedes the real sequence; it is
what the isolation rules below are checked against.

## 3. Isolation of the second stack on shared hosts

The two chains share two machines and nothing else. The checklist, by layer:

- Configuration: `chain/mainnet/`, `.env.mainnet`, `node-*/.env.mainnet`, `keys/mainnet/`,
  `node-*/secrets.mainnet/`; no file of the first chain is read or written by a
  `CHAIN=mainnet` command (`scripts/common.sh`, `Makefile`).
- Data: compose projects `finchain-mainnet-a` / `-b`, so every volume carries that prefix;
  the first chain's volumes (`finchain-a_*`, `finchain-b_*`) are never mounted.
- Network: distinct host ports for RPC, WS, metrics, op-node RPC, P2P on both hosts
  (`node-*/.env.example` lists the variables); distinct compose networks; the P2P advertise
  address uses the mainnet port.
- Runtime: separate containers, separate images only if `versions.lock` differs (it is
  shared by default); the host's memory and disk sized for both stacks (`docs/runbook.md`
  section 9) before the second starts.
- Operational: one profile per chain; `make restart-<host>` scoped by `CHAIN`; the Sepolia
  stack is never restarted to validate anything about mainnet.
- Ingress: the Caddy on host B is an independent service with one site per hostname and a
  health check per chain; a mainnet site that fails does not take the Sepolia site with it.
- Evidence: records under `manifests/evidence/` name their chain id; mainnet records in
  `manifests/finchain-mainnet/`.
- Recovery: the first chain's rebuild procedure (`make rebuild-b`) unchanged; the second
  chain's documented beside it before it goes live.

Runtime non-interference acceptance (Sepolia, before and after the dry run and before and
after each mainnet start on a host): the Sepolia containers' ids and start times, their
volumes, the chain id answered on the public RPC, the safe and finalized heads, and the
challenger's status are recorded before and after; the acceptance is that the ids and start
times are the same (nothing restarted), the heads advanced, and the challenger kept tracking.
No mainnet container is started until that record exists for the dry run.

## 4. Gates before the chain is called live

- The Sepolia withdrawal cycle finalized end to end (M4, due 2026-11-21): the exit path works.
- `make prestate` reproduces the published kona prestate and the Finchain kona-client prestate
  passes `run-trace` against Sepolia (M4, K2); the devnet drill done (K3): the replacement
  implementation is known to work before mainnet receives one.
- The two-chain layout proven on the Sepolia hosts without touching the first chain (the
  non-interference record above).
- The Safe in place as owner; the funding table funded, including the bond cycle and the
  reserve; the L1 providers under contract and serving the debug methods.
- Blobs working and the calldata fallback verified.
