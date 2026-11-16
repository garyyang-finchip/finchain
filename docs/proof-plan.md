# Proof plan

Finchain Sepolia launches with the standard permissioned path. The ability to run a real
fault proof is demonstrated separately, on an isolated environment, with a dedicated
adversarial driver and transaction-level evidence. Nothing in between is claimed.

## What the contracts and clients provide

- Contracts (op-contracts/v7.0.0): `PermissionedDisputeGame` inherits `FaultDisputeGame`;
  `move()` and `step()` add an authorisation check and then call the parent
  implementation. The VM single-step proof is available to the authorised proposer and
  challenger. The same release defines the permissionless game type `CANNON_KONA` (8), a
  `FaultDisputeGame` whose VM runs kona-client; op-deployer's address output has a slot for
  its implementation (`FaultDisputeGameCannonKonaImpl`, zero on Finchain Sepolia: none is
  deployed).
- Client (op-challenger v1.9.x): trace type `permissioned` is registered on the Cannon +
  op-program path and skips prestate validation; trace type `cannon-kona` is the Cannon +
  kona-client path, with kona-host (shipped in the image) as the preimage server, and is the
  default trace type of this release. Running `permissioned` with a Kona prestate does not
  produce "authorised participants with Kona proofs"; `run-trace` is a trace self-check and
  is not the resident service. kona-host takes raw RLP from the nodes - `debug_getRawHeader`
  and `debug_getRawReceipts` on L1, `debug_getRawHeader` and `debug_dbGet` on L2 - so the L1
  endpoint of anything that runs it must serve those methods.
- The public testnet's game type is deployed with the absolute prestate configured at
  deployment. Unless that prestate embeds Finchain's rollup and genesis configuration, a real
  dispute on that game type cannot reach a valid step. A game type whose prestate embeds
  Finchain must be installed before full-VM capability is claimed on the public chain. In
  op-contracts/v7.0.0 the factory holds one shared `FaultDisputeGame` implementation and
  per-type arguments (`DisputeGameFactory` 1.6.1: `setImplementation(type, impl, args)`,
  `args` = prestate, VM, anchor state registry, WETH, L2 chain id), so the installation is one
  owner transaction with the prestate among the arguments, not a new contract; K3 rehearses it.
- What is deployed (read on 2026-11-15 from `manifests/onchain-12112920.json` and the
  superchain registry): the game implementation carries `absolutePrestate`
  `0x038512e0...d54c`, which is op-deployer v0.7.1's default (`standard.DisputeAbsolutePrestate`:
  op-program 1.3.1, a 32-bit Cannon image, registry chains only), while its VM
  `0xacc005dc...` is MIPS 1.10.1 of op-contracts/v7.0.0, a 64-bit VM. Neither the image type
  nor the embedded chains fit Finchain, so no step can be valid on this game type; the
  permissioned flow (resolution by clock) is unaffected. The replacement game type (L3, M5)
  carries the Cannon64 prestate that `make prestate` builds (`drill/README.md`) in its factory
  arguments.

## The route: kona-client, and why op-program was left

The first attempt (2026-11-15) built the Cannon64 prestate of op-program/v1.9.0 with
Finchain's `rollup.json` and `genesis.json` embedded - the pipeline reproduced the published
op-program prestate bit for bit first, then gave `0x03e76631...5af1`
(`manifests/evidence/prestate-85422-20261115T162912Z.json`). The trace self-check with it
stopped before the VM started: the op-program host, fetching the L1 head 12141687 from the
public Sepolia node, reported `failed to verify block hash: computed 0xb88587b6...f6b8 but
RPC said 0xeb3344a2...b605`. The node's header carries `blockAccessListHash` (EIP-7928) and
`slotNumber` (EIP-7843), the Amsterdam fields; the header type of op-program/v1.9.0
(`op-service/sources/types.go` at that tag) has neither, so the hash it recomputes from the
JSON header cannot equal the node's. op-challenger/v1.9.6 has both fields, but the monorepo
no longer contains `op-program/` at that tag: the Go client is end of support and there is no
op-program release that follows the current L1. The raw header, the node's client version and
the two hashes are recorded by `make l1-header` (`manifests/evidence/l1-header-12141687-<date>.json`).

The route is therefore kona-client, the client of the `cannon-kona` game type:

- the release in service, op-challenger v1.9.6, ships kona-host and treats `cannon-kona` as
  its default trace type; the superchain registry publishes a kona prestate for release
  "1.9.0" (`cannon64-kona` `0x03f872c2...6b0b`), built from the monorepo tag
  `kona-client/v1.9.0` with the same Dockerfile op-challenger/v1.9.6 carries;
- kona-client has a documented extension point for chains outside the registry
  (`KONA_CUSTOM_CONFIGS_DIR`, merged by the `kona-registry` build script, conflicts rejected),
  so Finchain is embedded in the client the same way a registry chain is - not handed in
  through the preimage oracle (`--cannon-kona-l2-custom`, which the client itself labels
  insecure outside tests);
- kona-host reads raw RLP from the nodes, so the header-recomputation problem does not
  exist on this path.

Two things the tooling does not do for a chain outside the registry, found while running K2b
and handled in `drill/` (`drill/README.md`, K2b): public L1 endpoints do not serve the raw
methods kona-host reads, and the hosts' op-reth settings do not all allow `eth_getProof` at a
past block (`drill/rpc-shim.py` fills both for the drill; a resident challenger needs real
endpoints); and op-challenger drives kona-host with `--rollup-config-path` for such a chain,
which makes kona-host hand the client chain id 0 and the client fall back to the
oracle-supplied configuration - not the boot path of a dispute, where the game contract gives
the client its chain id and the client reads the embedded registry. The run that counts
therefore uses a kona-host built with the chain in its registry (`make kona-host`) behind a
wrapper that passes `--l2-chain-id`, and `run-trace` rejects a pass whose client fell back.
The same pair is a prerequisite for any `cannon-kona` challenger of this chain (K4), until
op-challenger can pass the chain id for a chain it does not know by name.

The op-program prestate `0x03e76631...5af1` stays in the record as evidence of the build
pipeline and the embedding method; it is superseded and nothing downstream uses it.

## M4 scope: K1 to K4

| Step | What is done | What may be claimed when it passes |
| --- | --- | --- |
| K1 | Finchain's configuration converted to the registry format kona-client embeds; merged by the registry crate's own build script; the rollup configuration the client derives compared with `rollup.json` field by field (`make kona-check`, `drill/README.md`) | the client will see the chain as op-node does. Done 2026-11-15: `manifests/evidence/kona-configs-85422-20261115T185730Z.json`, 28 of 28 fields equal |
| K2 | Reproducible kona-client prestate with Finchain embedded, the published kona prestate reproduced first (`UPSTREAM_CHECK=1 make prestate`); then `run-trace` (`cannon-kona`) with it against a recent block of the public chain (`make run-trace`), the client booting from the embedded configuration the way the game contract boots it (a kona-host that knows the chain, `make kona-host`, behind `drill/kona-host-wrapper.sh`) | the prestate proves a real Finchain block in the VM that the public chain's game type would run. K2a done 2026-11-16: `0x038b60ac...d9fb`, the published `0x03f872c2...6b0b` reproduced first (`prestate-85422-20261116T012620Z.json`). K2b done 2026-11-16: `run-trace-20261116T080811Z.json`, L2 block 200126 verified in 542 s with the embedded kona-host (`kona-host-85422-20261116T055801Z.json`) and `clientBoot.embeddedConfigUsed: true`; a first run the same day (`run-trace-20261116T045749Z.json`, 502 s) had verified the claim with the client on the oracle-supplied configuration (chain id 0) and is kept as what it is |
| K3 | Isolated devnet: a `CANNON_KONA` game on an honest root attacked down to the leaf by a dishonest challenger, the honest challenger's real `step()` on chain, resolution for the honest root (`drill/devnet/`, `make devnet-<step>`) | the proof system executes end to end for Finchain's configuration (environment stated). Tooling delivered 2026-11-16 (alpha.16); not run yet |
| K4 | Minimal integration check against Sepolia: what a Type 8 implementation needs there (prestate URL, challenger configuration, bonds), as a non-default game type if deployed at all. K3 rehearses the installing transaction: `setImplementation(8, FaultDisputeGameImpl, args)` from the owner, the prestate being an argument of the factory in op-contracts/v7.0.0 | readiness of the public chain for a later decision; no change to what the public chain trusts |

Approved: K1 to K4 as above; a Type 8 game on the devnet; a Type 8 implementation on Sepolia
only as a non-default type. Not approved, and not part of M4: changing the respected game
type, the withdrawal path or any permission of the public chain. Public statements about
bridging, withdrawals or security wait for proof acceptance. Mainnet preparation
(`docs/mainnet.md`) proceeds in parallel and does not depend on these steps.

## Levels and claims

| Level | What runs | What may be claimed |
| --- | --- | --- |
| L0 (M1) | op-proposer creates games of the respected type; nobody challenges | output roots are published; no proof system claim |
| L1 (M2/M4a) | resident op-challenger (`permissioned`) on host B resolves games, claims bonds, and counter-moves against a different proposer claim | permissioned challenge and resolution flow is operational |
| L2 (M4b, K3) | isolated devnet: full `CANNON_KONA` game (kona-client, Cannon64) with a Finchain-embedding prestate, an adversarial driver that attacks an honest root and keeps answering until the leaf is reached, a real `step()` transaction by the honest challenger, resolution for the honest root | the proof system executes end to end for Finchain's configuration (environment stated) |
| L3 (M5) | the same on the public chain (a game type whose arguments carry the embedding prestate, then permissionless type) | public fault-proof capability |

A game won by timeout (the bad proposer stops answering) demonstrates L1, never L2.

## K3: isolated environment

Environment: one scratch host (the one that built the prestate), a local L1, the same
`versions.lock`, Finchain's parameters (block time, gas limit, EIP-1559, the same forks at
genesis) and a chain id of its own (854220) so that no artifact of the devnet can be mistaken
for one of the public chain. Funds are free there, so bonds of any size can be posted. Nothing
in it touches the public chain or its hosts. The tooling is `drill/devnet/` (`make
devnet-<step>`, `drill/devnet/README.md`); the pieces, all of which exist upstream:

- L1: a `foundry` anvil (`versions.lock`) presenting Sepolia's chain id, 3-second blocks,
  finality in seconds (`--slots-in-an-epoch 1`); no consensus client - batches are calldata,
  op-node runs with `--l1.beacon.ignore`, and the beacon reads kona-host and op-node make at
  start-up are answered by the drill shim, which also synthesises the raw-RLP methods kona-host
  reads (K2b). The chain id is not a convenience: kona-client and op-node carry an L1
  configuration for 1, 11155111 and 17000 only, and any other id would make the client fall
  back to an oracle-supplied L1 configuration - the path the embedded prestate exists to avoid.
  Sepolia's id is the pair of configurations K2 proved on a real block.
- Contracts: op-deployer v0.7.1 against the anvil (live broadcast after the CREATE2 deployer
  is placed with `anvil_setCode`), a custom intent that deploys the superchain, the
  implementations and the OPCM itself (`superchainRoles`, `l1ContractsLocator = embedded`,
  op-contracts/v7.0.0), with `globalDeployOverrides` shortening the proof-system clocks of the
  shared implementations to minutes and hours (`drill/devnet/devnet.env`; the depths stay 73/30,
  so the game keeps its shape and bond schedule).
- Game type 8: installed after the deployment with the transaction a Type 8 game on any
  op-contracts/v7.0.0 chain takes, `DisputeGameFactory.setImplementation(8,
  FaultDisputeGameImpl, args)` from the owner, `args` = `absolutePrestate . vm .
  anchorStateRegistry . weth . l2ChainId` (`gameargs.PackPermissionless`, 124 bytes) with the
  devnet's kona prestate; in this contracts release the factory holds one shared
  `FaultDisputeGame` implementation and per-type arguments, so the prestate is an argument,
  not a new contract. `setInitBond(8, 0)`, and on the devnet (the only place approved for it)
  `AnchorStateRegistry.setRespectedGameType(8)` from the guardian. The installation has to
  follow the deployment because the prestate embeds the deployed chain (genesis, L1 anchor,
  addresses) - which is also why `dangerousAdditionalDisputeGames` at deploy time cannot carry
  it.
- Prestate and host: K1 and K2a repeated for the devnet's `rollup.json` and `genesis.json`
  (registry entry `finchain-devnet/devnet`, a superchain of the devnet's own), `make kona-host`
  for the host side; the same wrapper.
- Chain: op-reth, op-node (sequencer), op-batcher, op-proposer with `--game-type 8`, and the
  resident op-challenger with `--trace-type cannon-kona`, the devnet prestate and the
  embedded kona-host - in one compose file under `drill/devnet/` (the production compose files
  serve the public hosts; the drill does not bend them).
- Adversary: the simplest dishonest player that forces a real step - a dishonest challenger,
  not a dishonest proposer. The honest op-proposer posts correct roots; `drill/devnet/adversary.sh`
  attacks one root with an arbitrary claim through op-challenger's own `move` subcommand and
  then attacks every reply of the honest challenger, down the tree (the contract verifies
  nothing about intermediate claims; the bonds grow with depth and are paid from a devnet
  account with a million ETH). At the max game depth the attacker's leaf can only be answered
  by `step()`: the honest challenger executes one MIPS instruction of the kona-client trace on
  chain, from the devnet prestate, and proves the leaf wrong. The driver then stops; the clock
  runs out; the challenger resolves the game for the honest root.

Why the root is honest. With the standard odd max depth (73) the claims alternate between the
two sides, and a claim at the max depth is answered by `step()`: the honest side steps only
when the leaf is the attacker's, which needs an honest root. A dishonest root puts the honest
claims at the odd depths, the honest leaf at 73 would have to be stepped against by the
attacker, who cannot, and the game is won on the clock - level L1, never L2 (the earlier draft
of this plan, a dishonest proposer answered by the honest challenger, would have produced no
honest step). The honest-root scenario is also Finchain's: its proposer is honest and its
challenger has to defend against anyone.

Steps (`drill/devnet/README.md` has the commands and the durations):

1. `devnet-keys`, `devnet-l1`, `devnet-intent` (the intent reviewed), `devnet-deploy`; the
   devnet's `rollup.json`, `genesis.json` and L1 addresses exported; `devnet-l2` right away,
   so that the chain sequences and batches while the prestate builds (a chain whose first
   batches land after the sequencing window has its early blocks derived empty).
2. `devnet-build`: the devnet kona prestate and kona-host (the K1 comparison and the embedding
   checks run exactly as for the public chain; `KONA_CHECK=1` adds the K1 probe).
3. `devnet-install-game`: type 8 installed as above; the read-back and the transactions recorded.
4. `devnet-proof`: the proof services up; the proposer's first games created and, in time,
   resolved by the challenger without a dispute (the devnet's L0/L1).
5. `devnet-run-trace` (optional): K2b against the devnet.
6. `devnet-dispute`: the adversary, one game, driven to the honest `step()`; the record.
7. `devnet-resolve`: the clocks run out; resolution for the honest root; the record completed.

Evidence (`manifests/evidence/devnet-dispute-854220-<date>.json`, schema
`finchain.devnet-dispute/1`, `environment: local-devnet`):

- the devnet (anvil parameters and image, shim image, the production images), the deployment
  (chain record and addresses), the type 8 installation (implementation, packed arguments,
  transactions, respected type before and after);
- prestate hash and record, kona-host digest and record, the K1 record of the devnet;
- game address, index, L2 block, root claim, depths; the three parties;
- the sequence of attack transactions and the final depth;
- the `step()` transaction (hash, block, sender, status, gas) and the leaf claim it disproved;
- resolution status, resolving transaction, credit per party, anchor root before and after.

A game won on the clock without a step is reported as `FAIL`; only a step by the honest
challenger followed by `DEFENDER_WINS` is a K3 result. The public-chain repetition (L3) is a
separate acceptance entry that stays `not-run` until done.

## Resident service on the public testnet

`node-b/docker-compose.yml` runs `op-challenger --trace-type=permissioned` with the
challenger key. Its duties at L1: watch the factory, resolve games after the clock, claim
bonds, and respond to claims that contradict B's independently derived state. `op-dispute-mon`
is recommended for monitoring once more than one proposer or external participants exist.

What it did is read back from the chain by `make games` (`scripts/games.sh`): every game of
the respected type with its L2 block, status, the transaction that resolved it and that
transaction's sender (the challenger key, when the resident service resolved it), the moves
and the credit each party holds afterwards; the report is the M4 evidence for this level,
beside an excerpt of the service's own log. On Finchain Sepolia the initial bond of the
respected game type is 0 (set by the owner on 2026-11-11, `docs/funding-model.md`), so the
credit columns stay at zero and the evidence is the resolution itself: the status, the
resolving transaction and its sender. The first report
(`manifests/evidence/games-20261113T181336Z.json`, taken before any clock had expired) shows
48 hourly games, one claim each and no moves, with clocks ending from 2026-11-15T06:44Z; the
report after the first resolutions is the one that closes the item. That report exists:
`manifests/evidence/games-20261115T160409Z.json` (2026-11-15, 62 games) shows the first ten
games resolved DEFENDER_WINS by the challenger 72-168 s after their clocks expired, and the
service's own log (`challenger-log-20261115T162118Z.jsonl`) names the same ten resolving
transactions; `m4-challenger-2026-11-15.json` is the index and the cross-check. Level L1 is
operational on the public chain.

Operational finding (2026-11-13): with 48 games in flight the challenger's reads exceeded the
quota of the free public L1 endpoint on host B - a steady 1,400-1,600 `429 Too Many
Requests` per hour through the whole day, hitting the claim and status reads, the bond
claimer and the L1 head poll alike. Every failure is retried on the next L1 block and the
service kept tracking all 48 games, but the volume grows with the games in flight. The
response is the `steady` profile (one proposal every 6 hours) and an L1 endpoint of the
challenger's own with a known quota (`CHALLENGER_L1_RPC_URL`, node-b/.env), separate from
op-node's endpoint and from `make games`; the game window stays at the upstream default of
28 days, which covers the longest possible dispute plus the bond withdrawal delay.
`docs/funding-model.md` section 5 has the figures. A `cannon-kona` challenger adds a
requirement to that endpoint: the raw-RLP debug methods kona-host reads (above).
