# Mainnet plan (M5)

Status: **deployed and running on both hosts, public RPC up** (2026-11-19). The L1 contracts of Finchain
(chain id 8454) were deployed on Ethereum mainnet on 2026-11-18 at L1 block 26443400 in one
transaction from the deployer (`0x7d8fa9b4...a611c5`, 10,659,717 gas limit, 0.012082 ETH at
1.36 gwei; op-deployer live mode, mainnet not yet under Glamsterdam rules), the L2 genesis
`0xd678465005d9ba96c23dd4ff112630e5fdfac42d540d4967b77d581bc708497d` is anchored at that block
(genesis time 2026-11-18 17:19:35 UTC), and host A's second stack (`finchain-mainnet-a`) has
been sequencing, batching to mainnet and proposing since about 18:05 UTC the same day. The
chain record is `chain/mainnet/` (`deployer/intent.toml`, `deployer/state.json`, `out/`) and
the on-chain snapshot `manifests/onchain-mainnet-26443627.json` (respected game type 1, initial
bond 0.08 ETH, owner `0xF8D8...A8E2`, proof maturity 7 days, finality delay 3.5 days). Host B's
mainnet stack (`finchain-mainnet-b` on E05, resized to t3.large that morning because a t3.medium
cannot hold a second op-reth, op-node and challenger beside the Sepolia stack) started on
2026-11-19 at 08:56 UTC, derived the chain from L1 and caught up with host A in 38 minutes, with
the challenger tracking the first game; `https://rpc.mainnet.finchain.one` answers through the
first stack's Caddy since 09:00 UTC the same day - `manifests/evidence/mainnet-start-2026-11-19.json`
is the record, the Sepolia stack's containers included (nothing of it restarted for the mainnet).
The chain is not yet called live: the gates of section 4.

What was decided on 2026-11-13: chain id 8454; ETH pays gas and FCT is a governance and utility
token; the mainnet runs on the same two hosts as Finchain Sepolia, as a second stack on each
(`docs/runbook.md` section 9), with other arrangements to follow later. The nine decisions
below were taken on 2026-11-15 (owner and advisor) and five of them were revised by the owner on
2026-11-18 and 2026-11-19 for the launch, in favour of the fastest complete path at no extra
cost; each row says what is in force. This document records the decisions with their reasons,
the sequence that followed from them, the isolation rules the second stack must satisfy on the
shared hosts, and the gates before the chain is called live.

Mainnet preparation proceeded in parallel with the M4 proof work (`docs/proof-plan.md`, K1 to
K4) and did not wait for it. Public statements about bridging, withdrawals or security do.

## 1. Decisions

| # | Decision | What was decided and why |
| --- | --- | --- |
| 1 | Public hostnames | In force; the DNS records and the Caddy site (`node-b/caddy-sites/mainnet.caddy`, from the example beside it) go live with host B's mainnet stack. `rpc.mainnet.finchain.one` and `ws.mainnet.finchain.one`. `rpc.finchain.one` / `ws.finchain.one` stay with Finchain Sepolia: they are written into the released FOGA chain table and into the Sepolia manifest, and renaming a live testnet buys nothing. The first chain's Caddy on host B serves both sets of names (section 3, ingress). |
| 2 | Initial bond of the respected game type | In force: the deployment installed 0.08 ETH (`manifests/onchain-mainnet-26443627.json`). Cadence revised 2026-11-19: one proposal a day (`profiles/mainnet.env`, `PROPOSER_INTERVAL=24h`) instead of four, so with mainnet's 7-day DelayedWETH delay about 10.5 games and 0.84 ETH are in flight instead of 42 and 3.36 ETH; the proposer was funded 0.15 ETH for the first games, 1.2 ETH is the standing float. The standard 0.08 ETH, not zero: zero was a testnet measure for a game type with two trusted roles, and mainnet bonds are what a challenger is paid with. Verified against the deployment parameters before `make deploy-l1`. Capital in flight at the steady cadence (4 proposals a day): a bond is locked for the game's clock (3.5 days) plus the DelayedWETH withdrawal delay (7 days), about 10.5 days, so about 42 games and 3.36 ETH are in flight at any time; `docs/funding-model.md` carries the line and the funding table includes it (decision 7). |
| 3 | L1 endpoints for the two hosts | Revised 2026-11-19 for the launch: both hosts start on the free publicnode mainnet endpoints (execution and beacon), the only keyless endpoint that carried the challenger's request pattern in the 2026-11-18 probe (`docs/funding-model.md` section 5), with the challenger's 60-second cycle and 14-day window; a paid provider or the operator's own node follows, and publicnode's archive reads (state at a block older than its window) need a personal token, which `make verify-onchain` met on 2026-11-18 (the snapshot was taken at a recent block instead). The A/B independence rule is therefore relaxed at launch and restored with the second provider. The original decision: paid providers first, the operator's own L1 node later (a machine of its own, about 2 TB for execution plus consensus). One provider per host, execution and beacon endpoints each (the A/B independence rule); free public endpoints do not carry the challenger (`docs/funding-model.md` section 5). Added by the proof work: the endpoint of any host that runs the `cannon-kona` challenger, or `run-trace`, must serve `debug_getRawHeader` and `debug_getRawReceipts` (kona-host reads raw RLP; `docs/proof-plan.md`), which is a selection criterion for the provider and the plan; no public Sepolia endpoint checked on 2026-11-16 does. The host's own op-reth must allow `eth_getProof` at past blocks (`--rpc.eth-proof-window`, set on host B today, to be set on host A in a maintenance window), and a `cannon-kona` challenger for a chain outside the registry needs a kona-host with the chain in its registry behind `drill/kona-host-wrapper.sh` (`docs/proof-plan.md`). |
| 4 | Owner custody | Ruled by the owner on 2026-11-19: the owner's own account `0xF8D8...A8E2` holds the three owner roles (L1 ProxyAdmin, SystemConfig, DisputeGameFactory) for the whole build-out of the AI-cell and PoUW layers, the owner answering for its custody; the Safe (2-of-3) is taken up again at the milestone the owner calls the maturity of the AI-PoUW chain, not before, so that the coming development is not slowed by multisig ceremony; the migration then is one `transferOwnership` per owned contract (listed in `manifests/onchain-mainnet-26443627.json`). The original decision: a Safe is the owner from genesis, not a later migration. The deployment hot wallet is only the executor of the deployment transactions and holds no role afterwards; the owner address op-deployer received at deployment is the owner's account above (`manifests/onchain-mainnet-26443627.json`). |
| 5 | Data availability | Revised 2026-11-19: calldata at launch, the state proven on Sepolia; blobs (or the batcher's `auto` mode) after the first weeks, once the fallback behaviour has been watched on Sepolia. The original decision: blobs first (`--data-availability-type=blobs`, the beacon endpoint already configured; the batcher's cost is then a blob-fee line), with calldata as the fallback - verified on Sepolia before it is relied on, including what op-batcher's `auto` mode does when it switches, so that the fallback is a known state and not a surprise. |
| 6 | Prestate at launch | In force, with the route fixed on 2026-11-19: the deployment installed op-deployer's default prestate `0x038512e0...d54c` for the permissioned type (1). The Finchain-embedding kona-client prestate for chain 8454 was built on the scratch host the same day with the K2 pipeline (`make prestate CHAIN=mainnet`: `0x03f1d952437b64614622d35656242d6149ad8552386f73f6ca4369c2f25ab685`, embedding check passed, `manifests/evidence/prestate-8454-20261119T105453Z.json`; the registry files `kona-configs-8454-20261119T105341Z.json`, 28 of 28 fields equal to `chain/mainnet/out/rollup.json`; the embedded kona-host `kona-host-8454-20261119T113826Z.json`, `drill/out/bin/kona-host-finchain-8454-kona-client-v1.9.0`) and was installed as game type 8 (`CANNON_KONA`), a non-default type, by the owner on 2026-11-19 at 13:01 UTC with the console and `make k4-readiness CHAIN=mainnet` - the same route as Sepolia's K4 - (`setImplementation` in block 26449292, `setInitBond` 0.08 ETH in block 26449295, `manifests/evidence/mainnet-type8-install-2026-11-19.json`, the readiness read-back `k4-readiness-20261119T130854Z.json`), host B's mainnet challenger playing it since the same hour (`KONA=1`, the 8454 prestate and kona-host); the first Type 8 game follows once the anchor root has left op-deployer's placeholder, which game 0's `closeGame()` does after its clock and finality delay (2026-11-25T18:29:59Z at the earliest), `make k4-create-game CHAIN=mainnet` on host A. Type 1 keeps the default prestate because op-challenger plays type 1 with op-program and only type 8 with kona-client (the registration in op-challenger v1.9.6 and its development branch alike), and because the respected game type is not the owner's to change: `AnchorStateRegistry.setRespectedGameType` is the guardian's, and under `standard-overrides` the guardian is the shared SuperchainConfig's - the switch is a Superchain governance step for a standard chain, or a departure from the standard set; that question is the "proof mode" item of M5 for the owner and the advisor. The default prestate op-deployer installs (a 32-bit image, registry chains only; `docs/proof-plan.md`) is acceptable only as an internal stage: the chain may run with it while the Finchain-embedding kona-client prestate and its game implementation are prepared (`make prestate CHAIN=mainnet` after `make export`, then the OPCM's `updatePrestate` by the owner), and is not announced as live before that. The proof route and its acceptance are M4's (K1 to K4). |
| 7 | Budget | Measured at launch: the deployment cost 0.012082 ETH (10.66M gas limit at 1.36 gwei, no state gas on mainnet yet); the hot roles were seeded from the deployer (`make fund-roles CHAIN=mainnet ROLES="batcher=0.1 proposer=0.15"`) and are topped up from the owner's wallet to the standing figures (batcher 0.3, proposer 1.2, challenger 0.1 ETH). `make funding-table CHAIN=mainnet GAS_GWEI=<current>` once `.env.mainnet` exists: the deployment (about 56M gas with state gas, measured on Sepolia), daily operations at the steady profile, the bond line of decision 2 at the 10.5-day cycle, the L2 deposit that funds the World and the first cells, and an emergency reserve (a dispute that has to be answered, a provider change, a replacement host). The figure to hold on the deployer before `make deploy-l1` is gas limit times fee cap at that moment. |
| 8 | FOGA chain table | FOGA 1.1.0 adds chain 8454 (RPC hostname, explorer) after the chain has run stably, as an incremental release; FOGA never depends on Finchain, the entry is an option offered to cells. |
| 9 | Explorer and registries | An explorer instance for mainnet beside Sepolia's; the `ethereum-lists/chains` entry (`registry/`); the manifest `manifests/finchain-mainnet/`. |

## 2. Sequence

Every command with `CHAIN=mainnet` (`docs/runbook.md` section 9), nothing touching the
first chain's files, volumes or ports. Status per step (2026-11-19):

1. Done 2026-11-18. `make init-env CHAIN=mainnet`; `.env.mainnet` filled (chain id 8454, L1
   chain id 1, publicnode's mainnet endpoints, `PUBLIC_RPC_URL=https://rpc.mainnet.finchain.one`,
   `OPCM_ADDRESS=0x9ce712ff84e02659846dc6450bb9b7642fe8be5d`, the OP Contracts Manager of
   op-contracts/v7.0.0 on mainnet in the superchain registry, which `make intent` confirmed from
   op-deployer's own init); `node-a/.env.mainnet` with the second stack's ports (18545, 18546,
   19001, 18547, 17300, 18548, 18560, p2p 9223) and the tailnet address; `node-b/.env.mainnet`
   to be filled with host B's stack. The example files carry Sepolia's values; every
   `CHAIN=<name>` command refuses an env that still has Finchain Sepolia's chain id or slug
   (`scripts/common.sh`).
2. Done 2026-11-18. `make keys CHAIN=mainnet`: new role keys on host A (`keys/mainnet/`, backed
   up encrypted off the host): deployer `0xA562e36379c94880224D8005D003033e815FBe81`, unsafe
   block signer `0x4Ba4b8d96d4d2b27e8b76079Aa83bB992230E38D`, batcher
   `0xaEBc426e48370992437956C3EFbA4A8572397968`, proposer
   `0x7c2b388303cEBAE84aD3448057e074f2b2A65bbB`, challenger
   `0xc666b76dAa39016bf4eeAa213deB58E612a92Dc7`; the deployer funded with 0.3 ETH from the
   owner's wallet; the Safe deferred (decision 4).
3. Done 2026-11-18. `make intent CHAIN=mainnet` (owner roles and vault recipients the owner's
   account, `fundDevAccounts = false`); `TX_PRIORITY_GWEI=1 make deploy-l1 CHAIN=mainnet` (live
   mode; L1 blocks 26443394 to 26443400); `make export CHAIN=mainnet`; `chain/mainnet/`
   committed the same day.
4. Host A done 2026-11-18: `make secrets-a CHAIN=mainnet`, `make fund-roles CHAIN=mainnet
   ROLES="batcher=0.1 proposer=0.15"`, `make up-a CHAIN=mainnet PROFILE=mainnet`
   (`profiles/mainnet.env`: steady batching, one proposal a day); the unsafe head was at #2288
   and the safe head at #2209 forty minutes later, the finalized head following L1 finality; the
   proposer created game 0 at 18:29:59 UTC. Host B done 2026-11-19 after the resize of E05
   (section 3): `make bundle-b CHAIN=mainnet` on host A, the bundle moved once as for Sepolia,
   `make init-env CHAIN=mainnet` and the two env files on host B (`P2P_STATIC_PEERS` from `make
   peers-a CHAIN=mainnet`, at the mainnet p2p port 9223; `SEQUENCER_HTTP` at port 18545),
   `make install-bundle-b CHAIN=mainnet`, `make up-b CHAIN=mainnet` (Caddy stays with the first
   stack), the mainnet site file for the first stack's Caddy (`node-b/caddy-sites/mainnet.caddy`,
   one `make restart-b SVC=caddy`), the DNS records of decision 1; the non-interference record is
   part of `manifests/evidence/mainnet-start-2026-11-19.json`.
5. Done 2026-11-19: `make verify-onchain CHAIN=mainnet BLOCK=26443627`
   (`manifests/onchain-mainnet-26443627.json`; the deployment block itself is an archive read
   publicnode does not serve without a token), the initial bond and the owner verified; `make
   kona-configs`, `make prestate` and `make kona-host` for `CHAIN=mainnet` on the scratch host (the
   three 8454 records in `manifests/evidence/`), the prestate installed as game type 8 by the owner
   and host B's challenger recreated with `KONA=1` the same day (decision 6). The scratch host was
   stopped afterwards. Open on the clocks: the mainnet withdrawal cycle (initiated 2026-11-19,
   `withdrawal-20261119T102234Z.json`: prove after the second proposal, finalize about 2026-11-27),
   game 0's close (2026-11-25, the anchor leaving the placeholder), then the first Type 8 game.
   Game 0 resolved `DEFENDER_WINS` on 2026-11-22 at 06:31:47 UTC by host B's challenger, 108 s
   after its clock, the 0.08 ETH bond credited to the proposer
   (`manifests/evidence/games-20261122T174848Z.json`).
6. Remaining: the manifest `manifests/finchain-mainnet/<version>.json`, the registry entry, the
   handbook's mainnet section (the facts are in `docs/handbook.md` already), the FOGA 1.1.0
   release after stability.

The separate dry run with a throwaway chain name was dropped by the owner on 2026-11-19 as a
self-imposed wait; what remains of it is the compose rendering check (`make lint` renders the
host files with the example env) and the runtime non-interference record below, taken before
and after host B's mainnet stack starts. Host A's mainnet stack started beside the Sepolia
stack on 2026-11-18 without touching it (the Sepolia containers kept their ids and start times;
both chains' heads advanced).

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
  section 9) before the second starts. Host B's figure: a t3.medium (4 GB) holds one op-reth,
  op-node and challenger; the second stack needs t3.large (8 GB), a stop, type change and start
  of the instance (the Sepolia containers come back on their own; the Elastic IP and the volumes
  stay), done once host B's other work allows it. Host A (the Mac mini) held both stacks from
  the start.
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

- The Sepolia withdrawal cycle finalized end to end (M4): done 2026-11-22, the exit path works
  (`manifests/evidence/withdrawal-20261113T174622Z.json`); the mainnet cycle of 2026-11-19 is
  proven and finalizes about 2026-11-27.
- `make prestate` reproduces the published kona prestate and the Finchain kona-client prestate
  passes `run-trace` against Sepolia (M4, K2; done 2026-11-16); the devnet drill done (K3; done
  2026-11-16, `manifests/evidence/devnet-dispute-854220-20261116T161502Z.json`, a real `step()`
  and `DEFENDER_WINS` on the devnet): the replacement implementation is known to work before
  mainnet receives one. Two things K3 adds to this plan: a Type 8 game on a fresh op-deployer
  chain is playable only once the anchor state registry has left the placeholder root, which the
  first `closeGame()` of the permissioned type does (the chain runs with the default type until
  then anyway, decision 6); and the standard bond schedule asks the honest side of one
  full-depth game for about 330 ETH until resolution (decision 2's bond line, `docs/funding-model.md`).
- The two-chain layout proven on the Sepolia hosts without touching the first chain (the
  non-interference record above): done, host A 2026-11-18 and host B 2026-11-19
  (`manifests/evidence/mainnet-start-2026-11-19.json`).
- The funding table funded, including the bond cycle and the reserve; the L1 providers under
  contract and serving the debug methods (decision 3, now a later step; publicnode carries the
  launch). The Safe is no longer a gate before the chain is called live: by the owner's ruling of
  2026-11-19 (decision 4) it comes at the AI-PoUW maturity milestone.
- Blobs working and the calldata fallback verified (decision 5, now after launch; the chain runs
  on calldata).
- The Sepolia K4 check done (2026-11-19, `docs/proof-plan.md`): the proof route's installation
  path is known on the public testnet before mainnet receives the Finchain prestate. Mainnet
  received it the same day as game type 8 (`manifests/evidence/mainnet-type8-install-2026-11-19.json`);
  its first Type 8 game and that game's resolution by host B's `cannon-kona` challenger are the
  remaining steps of this item.
