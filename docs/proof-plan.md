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
- The public testnet's game implementation is deployed with the absolute prestate
  configured at deployment. Unless that prestate embeds Finchain's rollup and genesis
  configuration, a real dispute on that implementation cannot reach a valid step. A new
  implementation with a Finchain-embedding prestate must be installed before full-VM
  capability is claimed on the public chain.
- What is deployed (read on 2026-11-15 from `manifests/onchain-12112920.json` and the
  superchain registry): the game implementation carries `absolutePrestate`
  `0x038512e0...d54c`, which is op-deployer v0.7.1's default (`standard.DisputeAbsolutePrestate`:
  op-program 1.3.1, a 32-bit Cannon image, registry chains only), while its VM
  `0xacc005dc...` is MIPS 1.10.1 of op-contracts/v7.0.0, a 64-bit VM. Neither the image type
  nor the embedded chains fit Finchain, so no step can be valid on this implementation; the
  permissioned flow (resolution by clock) is unaffected. The replacement implementation (L3,
  M5) carries the Cannon64 prestate that `make prestate` builds (`drill/README.md`).

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
| K3 | Isolated devnet: a `CANNON_KONA` game on an invalid root, an adversary that answers every move, a real `step()` on chain, correct resolution, anchor state unchanged | the proof system executes end to end for Finchain's configuration (environment stated) |
| K4 | Minimal integration check against Sepolia: what a Type 8 implementation needs there (prestate URL, challenger configuration, bonds), as a non-default game type if deployed at all | readiness of the public chain for a later decision; no change to what the public chain trusts |

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
| L2 (M4b, K3) | isolated devnet: full `CANNON_KONA` game (kona-client, Cannon64) with a Finchain-embedding prestate, an adversarial driver that keeps answering until the execution-trace divergence is reached, a real `step()` transaction, resolution against the bad root | the proof system executes end to end for Finchain's configuration (environment stated) |
| L3 (M5) | the same on the public chain (new game implementation with the embedding prestate, then permissionless type) | public fault-proof capability |

A game won by timeout (the bad proposer stops answering) demonstrates L1, never L2.

## K3: isolated environment

Environment: one scratch host (the one that built the prestate), a local L1, the same
`versions.lock`, Finchain's parameters (block time, gas limit, EIP-1559, the same forks at
genesis) and a chain id of its own so that no artifact of the devnet can be mistaken for one of
the public chain. Funds are free there, so bonds of any size can be posted. Nothing in it
touches the public chain or its hosts. The pieces, all of which exist upstream:

- L1: a `foundry` anvil (`versions.lock`), a pre-Amsterdam fork, 2-second blocks; no
  consensus client - batches are calldata, op-node runs with `--l1.beacon.ignore`, and the
  beacon endpoints kona-host asks at start-up are answered by the drill shim.
- Contracts: op-deployer v0.7.1 against the anvil (live broadcast works on a pre-Amsterdam
  L1), deploying the superchain and the implementations itself (`superchainRoles` instead of
  an OPCM address, `l1ContractsLocator = embedded`, op-contracts/v7.0.0), with
  `dangerousAdditionalDisputeGames` adding a `FaultDisputeGame` of game type 8, VM type
  `CANNON` (the current Cannon state version, `multithreaded64-5`, the one the kona prestate
  is generated for), `faultGameAbsolutePrestate` = the devnet's kona prestate, `MakeRespected`
  = true, and dispute clocks measured in minutes (`dangerouslyAllowCustomDisputeParameters`).
  The result is the configuration a public chain with a Type 8 game would have: the factory's
  respected type is 8, its implementation carries a Finchain-embedding prestate.
- Prestate and host: K1 and K2a repeated for the devnet's `rollup.json` and `genesis.json`
  (the registry entry pins the L1 genesis and the contract addresses), `make kona-host` for
  the host side; the same wrapper.
- Chain: op-reth, op-node (sequencer), op-batcher, op-proposer with `--game-type 8`, and the
  resident op-challenger with `--trace-type cannon-kona`, the devnet prestate and the
  embedded kona-host - in one compose file under `drill/devnet/` (the production compose files
  serve the public hosts; the drill does not bend them).
- Adversary: the simplest dishonest proposer that forces a real step. op-challenger's own
  subcommands do it: `create-game` posts a game on a wrong output root for a real devnet block;
  a loop then answers every counter-claim of the resident challenger with `move`, posting
  arbitrary claims down the tree (the contract verifies nothing about intermediate claims; the
  bonds grow with depth and are paid from a devnet account with unlimited funds). When the
  dishonest leaf is reached, the honest challenger has to prove it wrong: that is the
  `step()` transaction, executed by the MIPS contract against the kona-client trace from the
  Finchain-embedding prestate. The driver then stops; the clock runs out; the challenger
  resolves the game; the anchor state must not have moved.

Steps:

1. `drill/devnet/`: anvil up; intent rendered from a template; `op-deployer apply`; the
   devnet's `rollup.json` and `genesis.json` exported; the devnet kona prestate and kona-host
   built (`make prestate`, `make kona-host` with the devnet's files - the K1 comparison and the
   embedding checks run exactly as for the public chain).
2. The chain up with the respected game type 8; the proposer's first games created and
   resolved by the challenger without a dispute (the devnet's L0/L1, minutes instead of days).
3. `make run-trace` against the devnet (K2b for the devnet).
4. The adversary: one game on an invalid root, driven to the first `step()`; the record below.
5. Stop the driver; resolution; the invalid root rejected; anchor state unchanged.

Evidence (committed under `manifests/evidence/`, `environment: local-devnet`):

- game address, game type, implementation address, the factory's respected type;
- VM address and state version, prestate hash, the Finchain configuration it embeds (the K1
  record of the devnet);
- the sequence of attack/defend transactions and the final dispute depth;
- the `step()` transaction receipt executed by the contract, with the claim it disproved;
- resolution result, bond settlement, anchor state before and after;
- `versions.lock` digests used.

The public-chain repetition (L3) is a separate acceptance entry that stays `not-run` until
done.

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
