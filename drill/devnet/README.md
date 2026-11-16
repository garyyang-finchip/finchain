# drill/devnet: the K3 isolated environment

M4 K3 (`docs/proof-plan.md`, "K3: isolated environment"): a `CANNON_KONA` (type 8) dispute game
on a chain with Finchain's configuration, played to a real `step()` on chain, inside an
environment that shares nothing with the public chain. Everything runs on one scratch host - the
one that built the K2 prestate, since the devnet needs the same caches - from one compose file
and one driver script. No Finchain key, no public endpoint, no host of the public chain is
involved; the only accounts are anvil's published test accounts, funded on a chain that exists
only in that anvil's memory.

What it shows when it passes: the proof system of the OP Stack release in `versions.lock`
executes end to end for Finchain's configuration - a kona-client prestate with the chain
embedded (K1, K2a), the kona-host that knows the chain (K2b), the Cannon64 MIPS contract of
op-contracts/v7.0.0, op-challenger's bisection down to the leaf and its one-instruction proof
on chain, and the resolution that follows. What it does not show: anything about the public
chain's contracts, bonds in real ETH, blobs (the devnet's batches are calldata, as Finchain's
are), or an L1 with a consensus layer. The environment is stated in every record
(`environment: local-devnet`).

## The pieces

| Piece | What | Why this way |
| --- | --- | --- |
| L1 | anvil from the pinned foundry image, `--chain-id 11155111`, 3-second blocks, `--slots-in-an-epoch 1` (finalized = head - 2), hardfork `prague`, in memory | kona-client and op-node carry an L1 configuration for three chain ids only (1, 11155111, 17000; `kona-registry` `l1/mod.rs`, `op-service/eth/config.go`); any other id makes the client fall back to an oracle-supplied L1 configuration, the path the embedded prestate exists to avoid. Sepolia's id is the pair of configurations K2 already proved on a real block. Finality in seconds lets the proposer propose finalized blocks |
| Shim | `drill/rpc-shim.py --synth --beacon-stub 3` in a `python:3.12-alpine` container, between the proof services and the anvil | kona-host reads L1 as raw RLP (`debug_getRawHeader`, `debug_getRawReceipts`), which anvil does not serve; the shim synthesises both and verifies them against the header (K2b). Its beacon stub answers the three Beacon API reads kona-host and op-node make at start-up (genesis, spec, node version); no blob is ever asked for |
| Contracts | op-deployer v0.7.1 (`versions.lock`), custom intent on the fresh L1: superchain, implementations and OPCM deployed by the same run (`superchainRoles`, `l1ContractsLocator = embedded`), Finchain's chain parameters, `globalDeployOverrides` with the devnet clocks (`devnet.env`) | the release and artifacts the public chain was deployed with; the clocks are the only parameters that differ, and they are deployment-time immutables of the shared implementations |
| L2 chain id | 854220 | not Finchain Sepolia's (85422), not the planned mainnet's (8454); nothing of the devnet can be mistaken for either |
| Registry entry | superchain `finchain-devnet`, identifier `finchain-devnet/devnet` (`drill/kona-configs.sh` with `KONA_SUPERCHAIN`) | the devnet has its own SuperchainConfig; a superchain of its own is how the registry itself holds `sepolia-devnet-2` and `-3` beside `sepolia`, and the merge inserts it whole |
| Prestate and host | `make prestate` and `make kona-host` through `devnet.sh build`, with the devnet's `rollup.json` and `genesis.json` | K1 and K2a repeated for the devnet chain: the same scripts, this chain's files; the embedding checks run exactly as for the public chain. The caches of the K2 build make it a rebuild of the registry crate and what depends on it |
| Game type 8 | `DisputeGameFactory.setImplementation(8, FaultDisputeGameImpl, args)` by the owner, `args` = `absolutePrestate(32) vm(20) anchorStateRegistry(20) weth(20) l2ChainId(32)` with the devnet prestate; `setInitBond(8, 0)`; `DEVNET_GAME_RESPECTED=1` adds `AnchorStateRegistry.setRespectedGameType(8)` by the guardian | in op-contracts/v7.0.0 the factory holds one shared `FaultDisputeGame` implementation and per-type arguments (`DisputeGameFactory` 1.6.1, `gameArgs`); the prestate is an argument, not a new contract. This is exactly the transaction a Type 8 game on the public chain would take (K4), from the owner key |
| Chain | op-reth, op-node (sequencer, no p2p), op-batcher (calldata), op-proposer (`--game-type 8`), the honest op-challenger (`--trace-type cannon-kona`, the devnet prestate, the devnet kona-host behind `drill/kona-host-wrapper.sh`) | the production images; flags follow `node-a/` and `node-b/` where the devnet does the same thing |
| Adversary | `drill/devnet/adversary.sh`: op-challenger's own `move` subcommand with the attacker account | the simplest dishonest player; the contract verifies nothing about intermediate claims, so arbitrary values suffice and only the bond schedule is paid |

## The scenario, and why the root is honest

The honest op-proposer posts correct output roots as type-8 games every two minutes. The
attacker picks one, attacks its root claim with an arbitrary value, and then attacks every
claim the honest challenger posts in reply, down the whole tree: output-root bisection above
the split depth (the honest side answers from op-node's `optimism_outputAtBlock`), execution
trace bisection below it (the honest side answers with Cannon states of the kona-client run,
one `cannon run` per move from the nearest snapshot). At the max game depth the attacker's leaf
can only be answered by `step()`: the honest challenger loads the preimages the step needs into
the PreimageOracle, then calls `step(claimIndex, isAttack, stateData, proof)`, and the MIPS
contract executes one instruction of the kona-client trace from the devnet prestate and finds
the leaf wrong. `list-claims` shows that leaf countered the moment the step lands. The driver
then stops; the attacker's clock runs out; the honest challenger resolves the claims and the
game (`DEFENDER_WINS`), and the record is completed. One claim is not arbitrary: the first
execution-trace claim (depth split + 1) is the root of that sub-game, and the contract checks
its status byte (`_verifyExecBisectionRoot`) - an attacker has to claim the VM found the
disputed output INVALID (`0x01`) or PANIC (`0x02`), so the driver sets that byte and fills the
rest at random (found on the first run, 2026-11-16: `UnexpectedRootClaim`).

The root has to be the honest side's. With the standard max depth of 73 (odd) the claims
alternate: root 0, attacker 1, honest 2, ..., attacker 73. A claim at the max depth is answered
by `step()`, so the honest side steps only when the leaf is the attacker's, which needs an
honest root. A dishonest root (a bad proposer) puts the honest claims at the odd depths; the
honest leaf at 73 would have to be stepped against by the attacker, who cannot, and the game is
won on the clock - level L1 in `docs/proof-plan.md`'s terms, never L2. The honest-root scenario
is also the realistic one for Finchain, whose proposer is honest and whose challenger has to
defend against anyone. `devnet.sh intent` refuses an even max depth for this reason.

The clocks (`devnet.env`): depths 73/30 as on the public chain, so that the game has its real
shape (73 moves, the standard bond schedule, 60 ETH per move near the leaf, paid from accounts
with a million ETH); clock extension 600 s and max clock duration 9000 s instead of 3 h and
3.5 days, because the honest challenger's chess clock has to cover its own cannon runs (the
first one, at the split depth, is a full trace of the disputed block - about ten minutes on two
cores by K2b's measure - and every later one runs from the nearest snapshot,
`DEVNET_SNAPSHOT_FREQ`); PreimageOracle challenge period, DelayedWETH delay, proof maturity and
game finality delay 600 s each. The constructor requires `max(2e, e + p) <= d`; `devnet.sh
intent` checks it before anything is deployed.

## Running it

Host: the scratch host of K2 (two cores, 8 GB of memory with 16 GB of swap, 100 GB of disk, docker with
compose v2.24+, buildx, `just`, git, jq, curl, openssl). The devnet is one session: the anvil
keeps the L1 in memory, so stopping the host or the anvil is the end of that devnet (`devnet.sh
down` and start over; `FRESH=1` deletes `drill/devnet/out/`). Plan eight to ten hours on the
small host: builds under half an hour from K2's caches (measured 2026-11-16: prestate 9 min,
kona-host 12 min), the anchor bootstrap 2.5 h plus the finality delay, the dispute one to two
hours, the resolution 2.5 h (the clocks).

```bash
make devnet-keys           # the accounts (anvil's test mnemonic) -> out/keys/addresses.env, out/secrets/
make devnet-l1             # anvil + shim; the CREATE2 deployer placed; the shim checked on a real anvil block
make devnet-intent         # the intent rendered for review (drill/devnet/intent.toml.in)
make devnet-deploy         # op-deployer apply against the anvil (a few minutes); out/chain/{genesis,rollup,l1-addresses,chain-record}.json
make devnet-l2             # op-reth, op-node, op-batcher; waits for the first safe block - right after deploy, see below
make devnet-build          # K1 + K2 for chain 854220: kona-configs (KONA_CHECK=1 adds kona-check), prestate, kona-host (about an hour)
make devnet-install-game   # setImplementation(8, impl, args) + setInitBond; setRespectedGameType(8) when DEVNET_GAME_RESPECTED=1
make devnet-proof          # op-proposer (type 8) and the honest op-challenger; waits for the first game
make devnet-anchor         # the anchor root off op-deployer's placeholder: first game resolved and closed after its clock (2.5 h + 10 min)
make devnet-run-trace      # optional: K2b against the devnet's own endpoints (run-trace record, environment local-devnet)
make devnet-dispute        # the attacker; ends when the honest step lands (DISPUTE_TIMEOUT=4h); the record
make devnet-resolve        # after the clocks: resolution, credits, anchor root; the record completed
make devnet-status         # containers, heads, games
make devnet-down           # stop and delete the devnet's volumes (FRESH=1: out/ too; drill/out/prestates/ is kept)
```

Every step prints what it did and refuses to run out of order (no keys, no anvil, no
deployment, no prestate). `devnet.sh deploy` re-renders the intent so that what was reviewed
is what is applied. Plan the anchor step: op-deployer deploys every chain with a placeholder
anchor root (`0xdead...`, L2 block 0), because the L2 genesis is generated after the L1
contracts. A game starts its output bisection at the anchor, so a game created before the
anchor has moved carries the placeholder as its starting root, and the honest challenger -
which validates permissionless games, unlike permissioned ones - compares it with the real
output root at that block and refuses the game ("output root absolute prestate does not match").
The anchor moves when a respected game resolves for its root, waits out the finality delay and
is closed (`closeGame()` calls `setAnchorState()`); nobody tracks the placeholder games, so
`devnet-anchor` resolves and closes the first type-8 game by hand once its clock has run out.
Games created before that stay untracked (the challenger keeps logging them); the dispute uses
the proposer's next game, the first with a real starting root. The same holds for the public
chain: a Type 8 game there is playable only once the anchor has left the placeholder, which
the first `closeGame()` of the permissioned type does (K4 waits for it). The L2 starts right after the deployment, before the hour-long build: the
L2 genesis time is the deployment's L1 block, and a chain whose first batches land more than
a sequencing window (3600 L1 blocks, three hours at the devnet's block time) after their L1
origin would have its early blocks replaced by empty ones on derivation. Sequencing during the
build also gives the first game something to cover. The build step runs the K1 and K2 scripts unchanged with the devnet's
files: the prestate lands in the shared store `drill/out/prestates/<hash>.bin.gz` beside the
public chain's, the host as `drill/out/bin/kona-host-devnet-<tag>` (the slug keeps the two
hosts apart), and the records as `manifests/evidence/{kona-configs,prestate,kona-host}-854220-<date>.json`.
`drill/devnet/out/` (ignored by git) holds the keys, the op-deployer workdir, the chain
artifacts, the logs, the claim snapshots and the honest challenger's log lines of each dispute.

Logs: `docker compose -p finchain-devnet logs -f op-challenger` (the honest side; cannon runs
show as `cannon` processes), `logs op-proposer`, `logs op-node`; the shim writes
`drill/devnet/out/logs/rpc-shim.log`. The attacker prints every move and, while it waits,
how long the honest side has been computing.

## The record

`manifests/evidence/devnet-dispute-854220-<date>.json` (schema `finchain.devnet-dispute/1`,
`environment: local-devnet`), written by `devnet-dispute` and completed by `devnet-resolve`:

- the devnet (anvil image and parameters, shim image, the production images), the deployment
  (chain record: genesis hash, L1 anchor, the contract addresses), the type 8 installation
  (implementation, packed arguments, transactions, respected type before and after), the anchor
  bootstrap (the game that moved the anchor, its transactions, the root before and after), the
  prestate hash and record, the kona-host digest and record, the K1 record;
- the game (address, index, L2 block, root claim, max and split depth) and the three parties;
- the dispute: every attacker move with its transaction, the counts of attacker and honest
  claims, the final claim list, the snapshots directory;
- the step: the transaction (hash, block, sender, status, gas), the leaf claim it countered,
  `counteredBy` = the honest challenger;
- the resolution: status (`DEFENDER_WINS`), the resolving transaction, the credit of each party,
  the anchor root before and after (it moves to the defended root once the game is finalized if
  type 8 is respected; the record states both values and the respected type).

`result` is `PASS` only with a step by the honest challenger and `DEFENDER_WINS`. A game won on
the clock without a step is not a K3 result; the attacker reports it as `FAIL` with the depth it
reached.

## Limits, stated

- The L1 is an anvil presenting Sepolia's chain id; its blocks are not Sepolia's. The L1
  configuration both clients use for it is Sepolia's fork schedule, which at the devnet's
  timestamps means every fork active - the same conclusion anvil's `prague` hardfork reaches
  for the fields that matter (no blobs, blob base fee 1).
- One host runs sequencer, verifier and challenger; independence between hosts is not what K3
  tests (M2 did).
- The clocks are shortened; the depths and bonds are not. A dispute on the public chain takes
  days by design.
- The shim stands in for L1 endpoints that serve the raw methods; a resident challenger needs
  the real thing (`docs/mainnet.md`, decision 3).
- `DEVNET_PYTHON_IMAGE` is a mutable tag outside the frozen `versions.lock`; the record carries
  the digest that was pulled.
