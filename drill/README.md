# drill: the M4 proof-system exercises

Everything under this directory runs on a scratch host, never on host A, host B or any
machine that holds a Finchain key. The exercises use test keys generated on the spot, local
networks and a copy of this repository; `drill/work/` and `drill/out/` are ignored by git.
What they produce for the record is written to `manifests/evidence/` like every other
acceptance item (`docs/acceptance.md` M4, `docs/proof-plan.md`).

## Route

The client that runs inside the fault-proof VM is **kona-client**, and the game type that
runs it is `cannon-kona` (8, `CANNON_KONA`). The first attempt used the Go client, op-program,
on the `cannon` / `permissioned` path; it ended on 2026-11-15 when `run-trace` stopped at the
L1 head with "failed to verify block hash": the op-program release recomputes L1 block hashes
from JSON headers and does not model two fields the Sepolia nodes serve since the Amsterdam
upgrade, and the monorepo no longer ships op-program at the op-challenger release in service.
`docs/proof-plan.md` has the whole account; the raw header is recorded by `make l1-header`
(below). The op-program prestate `0x03e76631...5af1` stays in the record as evidence of the
build pipeline and is marked superseded. Nothing downstream uses it.

| Step | What | Where | Command |
| --- | --- | --- | --- |
| K1 | Finchain's configuration in the registry format kona-client embeds; merged by the registry crate's own build script; the derived rollup configuration equal to `rollup.json` | scratch host (or any machine with cargo) | `make kona-check` (`make kona-configs` writes the files only) |
| K2a | Reproducible kona-client prestate with Finchain embedded; the official kona prestate reproduced first; embedding verified | scratch host | `UPSTREAM_CHECK=1 make prestate` |
| K2b | `op-challenger run-trace` (`cannon-kona`) with that prestate and a kona-host that knows the chain, against a recent block of the public chain; the client must boot from the embedded configuration | scratch host over the private network, or host B | `make kona-host`, then `make run-trace` |
| K3 | Isolated devnet: an honest type-8 game attacked down to the leaf by a dishonest challenger, the honest challenger's real `step()` on chain, resolution for the honest root | scratch host | `make devnet-<step>` (`drill/devnet/README.md`). Done 2026-11-16: `manifests/evidence/devnet-dispute-854220-20261116T161502Z.json`, `PASS` (the step at trace index 0); second game 2026-11-17 with `ATTACK_STRATEGY=inside`: `devnet-dispute-854220-20261117T070418Z.json`, `PASS` (the step at trace index 178,268,704; `docs/proof-plan.md`, "Result") |
| K4 | Minimal integration check against Sepolia: what a Type 8 implementation would need there, without changing the respected game type | - | to be defined now that K3 is done (`docs/acceptance.md` M4, K4): K3 rehearsed the installing transaction (`setImplementation(8, impl, args)`), showed the anchor precondition and measured the bond schedule |

A Type 8 implementation may be deployed on Sepolia only as a non-default game type, and only
after K3; changing the respected game type, the withdrawal path or any permission of the
public chain is not part of M4 and needs a decision of its own.

## Why a prestate of our own

kona-client looks the L2 chain up by the chain id the dispute game contract hands it, in the
superchain registry compiled into it (`kona-registry`). A chain the registry does not know
falls back to a rollup configuration handed in through the preimage oracle, which the host
controls - fine for a test, worthless as a proof. The public testnet's game implementation
also carries op-deployer's default prestate (op-program 1.3.1, a 32-bit Cannon image) while
its VM is the 64-bit MIPS of op-contracts/v7.0.0, so no step can be valid on that
implementation whatever the chain. K2a builds the kona-client Cannon64 image of a release with
Finchain's chain in its registry, with the monorepo's own reproducible recipe and no other
change (`KONA_CUSTOM_CONFIGS_DIR`, a documented extension point of the crate).

## Host requirements

Linux, two cores, 8 GB of memory with 16 GB of swap (the Rust build is compiled one crate at a
time, `KONA_BUILD_JOBS=1`, and still links with LTO), 40 GB of free disk for the caches and
images, docker with BuildKit and the buildx plugin (`docker buildx version` must answer),
git, jq, gzip, `just` (K2a; a static binary from its GitHub release), and for K1 either a cargo
at the workspace's Rust version or docker (the `rust:<version>` image is used). No key. K1 and
K2a need only GitHub, crates.io and the Docker registries; K2b needs the two RPCs below.

```bash
# just, on Amazon Linux 2023
V=$(curl -s https://api.github.com/repos/casey/just/releases/latest | jq -r .tag_name) \
  && curl -fsSL "https://github.com/casey/just/releases/download/$V/just-$V-x86_64-unknown-linux-musl.tar.gz" \
     | sudo tar -xz -C /usr/local/bin just && just --version
# buildx, if `docker buildx version` fails
V=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | jq -r .tag_name) \
  && sudo curl -fsSL "https://github.com/docker/buildx/releases/download/$V/buildx-$V.linux-amd64" \
       -o /usr/local/lib/docker/cli-plugins/docker-buildx \
  && sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx && docker buildx version
```

## K1 in detail

```bash
make kona-configs          # drill/work/kona-configs-<chainId>/{chainList,configs,depsets}.json
make kona-check            # the same, then the merge and the comparison; the record under manifests/evidence/
```

`drill/kona-configs.sh` turns `rollup.json` and `genesis.json` into the three files of the
registry format (`kona-registry/etc/`): one `Chain` entry (`sepolia/finchain`, parent L1
Sepolia), one `ChainConfig` under the `sepolia` superchain (the registry keeps its own
superchain config - L1 chain id, the shared SuperchainConfig address, which is also the one
op-deployer gave Finchain - and appends the chain), and the self-only dependency set the
registry gives every non-interop chain. The op-node genesis block and the EIP-1559 parameters
are copied verbatim; the hardfork times are the ones `rollup.json` schedules, and a fork the
pinned client does not model stops the conversion instead of being dropped. The two addresses
the client derives from - `OptimismPortalProxy` and `SystemConfigProxy` - come from
`rollup.json`; the rest of the address list is informational and comes from
`chain/out/l1-addresses.json`. A chain that does not belong to a registry superchain (the K3
devnet, whose L1 is an anvil) gets a superchain of its own with `KONA_SUPERCHAIN=<name>` and
`L1_PUBLIC_RPC=<its L1>`: the merge inserts that superchain whole, with the chain's own
SuperchainConfig address, the way the registry holds `sepolia-devnet-2` beside `sepolia`. The
L1 chain id must still be one the client carries an L1 configuration for (1, 11155111, 17000).

`drill/kona-check.sh` then builds `drill/kona-check/` (a twenty-line probe that prints what
`kona_registry::ROLLUP_CONFIGS` holds for a chain id) against the `kona-registry` crate of the
monorepo checkout at the pinned tag, twice: with the stock registry (the chain must be absent)
and with `KONA_CUSTOM_CONFIGS=true` and `KONA_CUSTOM_CONFIGS_DIR` pointing at the generated
files. The crate's build script merges the files and validates them exactly as the prestate
build does, so a wrong field fails here, in minutes, instead of at the end of a long build.
The derived rollup configuration is compared with `rollup.json` field by field (genesis,
timing, addresses, EIP-1559 parameters, every fork time) and the record
`manifests/evidence/kona-configs-<chainId>-<date>.json` carries the three files, both probe
results and the comparison. Result (2026-11-15): stock registry 55 chains, merged 56, all 28
fields equal - `kona-configs-85422-20261115T185730Z.json`.

## K2a in detail

```bash
UPSTREAM_CHECK=1 make prestate        # first time: reproduce the published kona prestate of the tag, then build Finchain's
make prestate                         # later runs: Finchain variant only (the caches make it incremental)
make prestate TAG=kona-client/v1.9.0 ROLLUP=chain/out/rollup.json GENESIS=chain/out/genesis.json KONA_BUILD_JOBS=1
```

Run it under `nohup` or `tmux`: the first build compiles the whole Rust dependency graph for
the MIPS64 target and takes hours on two cores. `drill/prestate.sh` clones the monorepo at
`TAG` (shallow) into `drill/work/`, writes `jobs = 1` under `[build]` in
`rust/.cargo/config.toml` of the checkout (the Dockerfile copies that file into the build
stage; parallelism does not change the output, and the upstream check is the proof of that),
and runs `just reproducible-prestate-kona` - the recipe the release prestates are built with
(`rust/kona/docker/fpvm-prestates/cannon-repro.dockerfile`: cannon built from the same
checkout, the client built with the pinned toolchains, Cannon state `multithreaded64-5`) -
first without, then with `KONA_CUSTOM_CONFIGS_DIR` set to the K1 files. The build caches
(cargo registry and target directory) are BuildKit cache mounts, so the second build
recompiles the registry crate and what depends on it, nothing else. The recipe also builds the
interop variant (`kona-client-int`); its hash is recorded and not used.

Outputs:

- `drill/out/prestates/<hash>.bin.gz` and `<hash>.json`: the prestate and its proof, named as
  `op-challenger --prestates-url` expects them;
- `drill/out/logs/prestate-kona-*.log`: the full build logs;
- `manifests/evidence/prestate-<chainId>-<date>.json` (schema `finchain.prestate/2`): tag and
  commit, the recipe, the digests of the three embedded files, the hash, the embedding check
  (the decompressed VM memory image is searched for the chain's genesis hashes, the chain id
  field and the identifier, which the registry embeds as text), the upstream reproduction
  when it ran.

Published hashes for the upstream check (superchain-registry `standard-prestates.toml`,
release "1.9.0"): `cannon64-kona` `0x03f872c2161174453f8841a1ebd1d22bca443a5045d53e662dd835f24e1b6b0b`,
`cannon64-kona-interop` `0x03e5a54835d39c1d83b198314473e1f111c3539c04f65c3e8a9b8ccebe3737c9`.
A second host that runs `make prestate` must obtain the same Finchain hash; a different hash
means the two hosts did not build the same thing, and nothing downstream should use the file.

The prestate file itself is a build artifact of another project and is not committed here;
the record carries its hash, and the file is served from a prestates URL when K3 and a later
public-chain implementation need it.

## K2b in detail

`op-challenger run-trace` takes a recent L2 block of the live chain - the safe head at a
finalized L1 block, and its parent, as the host's op-node reports them - and runs kona-client
inside the Cannon VM from the given prestate until it has derived and executed that block. The
run passes when the VM exits with the claim verified. That is one block, the same unit a real
dispute narrows to before any `step()`, and the same client, VM and prestate the
`cannon-kona` game type runs; a pass with the Finchain prestate shows that prestate proves a
real Finchain block before any game implementation is changed - provided the client booted the
way the game contract would boot it (next paragraph).

The chain id and the host (`make kona-host`). The client inside the VM does not read a
configuration file: it asks the preimage oracle for the L2 chain id (local key 5) and looks
that id up in the registry compiled into it. On chain that key is answered by the game
contract from its own `L2_CHAIN_ID`, so the client reads the configuration embedded in the
prestate; a key the contract does not serve (the oracle-supplied rollup configuration, local
key 6) cannot be part of a valid step. Off chain, kona-host answers the key, and kona-host
takes either `--l2-chain-id` or `--rollup-config-path`, never both. op-challenger gives it
`--rollup-config-path` for any chain outside its own list, which is every chain outside the
superchain registry - Finchain included - and kona-host then reports chain id 0, so the client,
finding no chain 0, falls back to the configuration the host feeds it through the oracle and
says so on its stdout ("No rollup config found for chain ID 0, falling back to preimage
oracle. This is insecure in production without additional validation!"). The first K2b run
(2026-11-16, `run-trace-20261116T045749Z.json`) passed that way: the claim was verified, the
boot path was not the one a dispute uses, and the record is kept as what it is. The run that
counts uses the same pair a `cannon-kona` challenger for this chain needs:

- a kona-host built from the same checkout with the same K1 files in its registry
  (`drill/kona-host-build.sh`, `make kona-host`; the image's own recipe with the release
  profile; checked by running it inside the op-challenger image and by finding the registry
  text in the binary; record `manifests/evidence/kona-host-<chainId>-<date>.json`);
- `drill/kona-host-wrapper.sh` as `--cannon-kona-server`: it drops `--rollup-config-path` from
  what op-challenger passes and appends `--l2-chain-id <chain id>`, then runs that kona-host.

`drill/run-trace.sh` mounts both when `drill/out/bin/kona-host-<slug>-<tag>` exists (the slug
is `KONA_CHAIN_SLUG`, `finchain` for the public chain, `devnet` for K3's), reads the guest's
stdout afterwards, and reports a run whose client fell back to the oracle (rollup or L1
configuration) as `PASS-WITH-ORACLE-CONFIG` (exit 3) with the chain id the client saw; the record carries
`konaHost` (embedded or not, binary digest) and `clientBoot` (which configuration the client
used). Only `PASS` closes K2b. Result (2026-11-16, scratch host, 2 cores): `make kona-host`
took 39 minutes (`kona-host-85422-20261116T055801Z.json`); the run with it,
`run-trace-20261116T080811Z.json`, verified L2 block 200126 at L1 head 12145948 in 542 s
(`PASS`, `embeddedConfigUsed: true`, no fallback line in 213 lines of log), the L1 shim having
synthesised 133 headers and 66 receipt sets without a failure and the L2 shim having routed 9
`eth_getProof` calls to host B. K2 is closed. A resident Type 8 challenger on Sepolia (K4) needs the same
wrapper and host, or an upstream op-challenger that can pass `--l2-chain-id` for a chain it
does not know by name.

Inputs and where they come from:

- the rollup RPC: an op-node with the safe-head database (`--safedb.path`), which `run-trace`
  queries by L1 block; host B's op-node keeps it, host A's does not;
- the L2 RPC with the `debug` namespace: kona-host reads raw headers and trie preimages
  (`debug_getRawHeader`, `debug_dbGet`); host A's op-reth serves it privately, host B's public
  op-reth deliberately does not - so on host B the L2 RPC is host A's op-reth over the private
  network, the address host B already uses as `SEQUENCER_HTTP`. kona-host also asks that node
  for `eth_getProof` at the agreed L2 block (the output root's message-passer storage root), a
  block some minutes old, and reth answers `eth_getProof` only at its head unless
  `--rpc.eth-proof-window` is set: host B's op-reth has the window (the withdrawal proof needs
  it), host A's does not. `drill/run-trace.sh` probes this too and, when host A refuses, puts
  `drill/rpc-shim.py` in front of host A with `eth_getProof` routed to host B's private RPC
  (`L2_PROOF_RPC`, default `http://<B_BIND_IP>:<B_RPC_PORT>` of the host env). The lasting fix is
  the same flag on host A's op-reth (`node-a/docker-compose.yml`), a change to the sequencer's
  execution client that is applied in a maintenance window, not during a drill;
- the L1 execution endpoint, which for kona-host must serve `debug_getRawHeader` and
  `debug_getRawReceipts` (it takes the RLP from the node rather than re-encoding JSON, which is
  also why the header problem of the op-program route cannot happen to it), and the L1 beacon
  endpoint for blobs. No public Sepolia endpoint checked on 2026-11-16 serves the two methods
  (publicnode, OnFinality: not available; dRPC: paid plan; Blast: closed; Tenderly's public
  gateway: rate limited; BlockPI: key required), so `drill/run-trace.sh` probes them and, when
  they are missing, starts `drill/rpc-shim.py --synth` in front of the endpoint: the shim
  forwards every method and synthesises the two raw ones from `eth_getBlockByHash` and
  `eth_getBlockReceipts`, serving nothing whose keccak (header) or Merkle-Patricia root
  (receipts) the node's own header does not confirm. Its encoders are checked by
  `drill/rpc-shim.py --self-test` against the saved header of block 12141687 (the Amsterdam
  header op-program could not reproduce) and the `ethereum/tests` trie vectors, and its live
  probe on 2026-11-16 reproduced a finalized Sepolia block's hash and receipts root before the
  run. `L1_RAW_SHIM=0` refuses the shim; the record names every shim instance, what it
  synthesised or routed, its counters and its log. The choice of L1 provider for the proof
  work and for mainnet (`docs/mainnet.md` decision 3) has to take the two methods into account:
  the shim is for the drill, a resident challenger needs the real thing;
- the chain's `rollup.json` and `genesis.json` (given to kona-host, the host side; the client
  inside the VM uses the configuration embedded in the prestate) and the prestate file under
  `drill/out/prestates/`.

```bash
# on the scratch host that built the prestate, once it is on the private network:
make init-env                        # .env from the example: the L1 endpoints are enough for one run
make kona-host                       # once: the host side with the chain in its registry (20-40 minutes)
ROLLUP_RPC=http://<host B private IP>:8547 L2_RPC_DEBUG=http://<host A private IP>:8545 \
  L2_PROOF_RPC=http://<host B private IP>:8545 L1_RPC_URL=<L1 endpoint> DRILL_NETWORK=host make run-trace
# on host B (its own op-node, host A's op-reth over the private network):
make prestate                        # the same hash as on the scratch host, or stop
make run-trace                       # HOST=b default; PRESTATE=<file> when there are several
```

The run is one `docker run` of the pinned op-challenger image (`--trace-type cannon-kona`,
`--cannon-kona-server /usr/local/bin/kona-host`, which the image ships - 1.0.2 in
op-challenger v1.9.6 - and `--run cannon-kona/finchain/file:<prestate>`), joined to the host's
compose network or to the host network on a scratch machine; it ends at the first verdict and
removes the container. With several prestates under `drill/out/prestates/` the newest is
taken; `PRESTATE=<file>` chooses. `L1_RPC_URL` and `L1_BEACON_URL` given on the command line
win over the env files (a scratch host's `node-b/.env`, copied from the example, names a
rate-limited public gateway); `CHAIN_OUT=<dir>` with both URLs runs it for another chain's
artifacts without the public chain's env files at all (`make devnet-run-trace` does), and
`ENVIRONMENT` names the environment in the record. Expect a
few GB of memory for the VM and from minutes to an hour on two cores; `RUN_TIMEOUT` (default
3h) bounds it. Outputs: `drill/out/logs/run-trace-<date>.log` (the service log) and
`manifests/evidence/run-trace-<date>.json` (schema `finchain.run-trace/2`: prestate, image,
trace type, preimage server, the L1 head and L2 block used, the verdict). `TRACE=cannon` runs
the op-program path instead, for the record; it needs the op-program checkout and builds that
host from source.

## The L1 header record

The two raw answers behind the end of the op-program route are kept verbatim and turned into
`manifests/evidence/l1-header-<number>-<date>.json`:

```bash
H=0xeb3344a2c9b178d735b8f102adeac23fb865351eff0a0d1776d7dbddac4bb605   # the L1 head of the failed run
curl -s -X POST "$L1_RPC_URL" -H 'content-type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByHash\",\"params\":[\"$H\",false]}" > drill/out/logs/l1-header-12141687.json
curl -s -X POST "$L1_RPC_URL" -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"web3_clientVersion","params":[]}' > drill/out/logs/l1-client-version.json
make l1-header                       # drill/l1-header-evidence.sh: the record, with the failed run's log digest when it is still there
```

The record names the header fields the op-program release does not model
(`blockAccessListHash`, `slotNumber`), the hash it computed, the hash the node reported, the
node's client version, and embeds the whole `eth_getBlockByHash` response.

## Archived: the op-program build (stage 1 of the first route)

Result (2026-11-15, on a 2-core x86_64 scratch host, 5 minutes for both builds): the pipeline
reproduced the published op-program/v1.9.0 Cannon64 prestate
`0x033c000916b4a88cfffeceddd6cf0f4be3897a89195941e5a7c3f8209b4dbb6e` bit for bit, and the
same pipeline with `chain/out/rollup.json` and `genesis.json` embedded gave
`0x03e76631d9a697212e78f495d6b610cd926272fa60e09d7c25840ac835d35af1` (19.5 MB gzip,
embedding check PASS; `manifests/evidence/prestate-85422-20261115T162912Z.json`). It is
evidence that the build pipeline and the embedding method work; it is superseded by the
kona-client prestate and is not used by any later step. `PROVER=op-program make prestate`
still builds it.
