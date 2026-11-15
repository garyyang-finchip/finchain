# drill: the M4 proof-system exercises

Everything under this directory runs on a scratch host, never on host A, host B or any
machine that holds a Finchain key. The exercises use test keys generated on the spot, local
networks and a copy of this repository; `drill/work/` and `drill/out/` are ignored by git.
What they produce for the record is written to `manifests/evidence/` like every other
acceptance item (`docs/acceptance.md` M4, `docs/proof-plan.md`).

## Stages

| Stage | What | Where | Command |
| --- | --- | --- | --- |
| 1 | Reproducible op-program prestate with Finchain's configuration embedded; hash recorded, embedding verified | scratch host | `make prestate` (`UPSTREAM_CHECK=1` reproduces the published prestate first). Done 2026-11-15: `0x03e76631...5af1`, `manifests/evidence/prestate-85422-20261115T162912Z.json` |
| 2 | `op-challenger run-trace` with that prestate against a recent block of the public chain (trace self-check) | host B (its op-node keeps the safe-head database; the L2 debug RPC is host A's op-reth over the private network) | `make run-trace` after `make prestate` on that host |
| 3 | Isolated devnet: a game on an invalid root, an adversary that answers every move, a real `step()`, resolution | scratch host | documented when stage 2 is done |

## Why a prestate of our own

The op-program client that runs inside the fault-proof VM looks the L2 chain up by the
chain id the dispute game contract hands it, in the superchain registry built into the
client or in files embedded under `op-program/chainconfig/configs/`. Finchain is in
neither. The public testnet's game implementation also carries op-deployer's default
prestate (op-program 1.3.1, a 32-bit Cannon image) while its VM is the 64-bit MIPS of
op-contracts/v7.0.0, so no step can be valid on that implementation whatever the chain.
Stage 1 builds the Cannon64 image of a current op-program release with Finchain's
`rollup.json` and `genesis.json` embedded, with the repository's own reproducible Docker
build and no other change.

## Host requirements (stage 1)

Linux, two cores, 8 GB of memory (swap helps), 20 GB of free disk, docker with BuildKit and
the buildx plugin (`docker buildx version` must answer), git, jq, gzip. No key, no chain
access: the build needs only GitHub and the Go module proxy.

If `docker buildx version` fails on Amazon Linux 2023:

```bash
V=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | jq -r .tag_name) \
  && sudo curl -fsSL "https://github.com/docker/buildx/releases/download/$V/buildx-$V.linux-amd64" \
       -o /usr/local/lib/docker/cli-plugins/docker-buildx \
  && sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx && docker buildx version
```

## Stage 1 in detail

```bash
UPSTREAM_CHECK=1 make prestate        # first time: also reproduce the published prestate of the tag
make prestate                         # later runs: Finchain variant only
make prestate TAG=op-program/v1.9.0 ROLLUP=chain/out/rollup.json GENESIS=chain/out/genesis.json
```

`drill/prestate.sh` clones the monorepo at `TAG` (shallow) into `drill/work/`, copies
`rollup.json` as `<chainId>-rollup.json` and `genesis.json` (with `alloc` emptied; the
client reads only `config`) as `<chainId>-genesis-l2.json` into
`op-program/chainconfig/configs/`, and runs `docker build -f Dockerfile.repro` with the
exact arguments of that tag's `make reproducible-prestate` (target `current`). The run
takes 30-60 minutes on two cores, twice that with `UPSTREAM_CHECK=1`; run it under `nohup`
or `screen` so that a dropped session does not kill it.

Outputs:

- `drill/out/prestates/<hash>.bin.gz` and `<hash>.json`: the prestate and its proof, named
  as `op-challenger --prestates-url` expects them;
- `drill/out/logs/prestate-*.log`: the full build log;
- `manifests/evidence/prestate-<chainId>-<date>.json`: the record - tag and commit, the
  digests of the two embedded files, the hash, the embedding check (the decompressed VM
  memory image is searched for the L2 genesis hash, the L1 genesis hash and the chainId
  field), the upstream reproduction when it ran.

The prestate file itself is a build artifact of another project and is not committed
here; the record carries its hash, and the file is served from a prestates URL when stage
2 and the public-chain upgrade (M5) need it.

Result (2026-11-15, on a 2-core x86_64 scratch host, 5 minutes for both builds): the
pipeline reproduced the published op-program/v1.9.0 Cannon64 prestate
`0x033c000916b4a88cfffeceddd6cf0f4be3897a89195941e5a7c3f8209b4dbb6e` bit for bit, and the
same pipeline with `chain/out/rollup.json` and `genesis.json` embedded gave
`0x03e76631d9a697212e78f495d6b610cd926272fa60e09d7c25840ac835d35af1` (19.5 MB gzip,
embedding check PASS). The record is `manifests/evidence/prestate-85422-20261115T162912Z.json`.
A second host that runs `make prestate` must obtain the same hash; a different hash means
the two hosts did not build the same thing, and nothing downstream should use the file.

## Stage 2 in detail

`op-challenger run-trace` takes a recent L2 block of the live chain - the safe head at a
finalized L1 block, and its parent, as the host's op-node reports them - and runs op-program
inside the Cannon VM from the given prestate until it has derived and executed that block.
The run passes when the VM exits with the claim verified. That is one block, the same unit a
real dispute narrows to before any `step()`, and the same program, VM and prestate family the
public chain's `permissioned` games use; a pass with the Finchain prestate shows that prestate
proves a real Finchain block before any game implementation is changed.

Inputs and where they come from:

- the rollup RPC: an op-node with the safe-head database (`--safedb.path`), which `run-trace`
  queries by L1 block; host B's op-node keeps it, host A's does not;
- the L2 RPC with the `debug` namespace (execution-witness path): host A's op-reth serves it
  privately, host B's public op-reth deliberately does not - so on host B the L2 RPC is host
  A's op-reth over the private network, the address host B already uses as `SEQUENCER_HTTP`;
- the L1 execution and beacon endpoints of the host env; the chain's `rollup.json` and
  `genesis.json`; the prestate file under `drill/out/prestates/`.

```bash
make prestate                        # on host B: the same hash as on the scratch host, or stop
make run-trace                       # HOST=b default; PRESTATE=<file> when there are several
ROLLUP_RPC=... L2_RPC_DEBUG=... make run-trace HOST=a    # other topologies
```

The run is one `docker run` of the pinned op-challenger image joined to the host's compose
network; it ends at the first verdict and removes the container. Expect a few GB of memory
for the VM and from minutes to an hour on two cores; `RUN_TIMEOUT` (default 3h) bounds it.
Outputs: `drill/out/logs/run-trace-<date>.log` (the service log) and
`manifests/evidence/run-trace-<date>.json` (prestate, image, the L1 head and L2 block used,
the verdict). A first run with the prestate the public chain carries today
(`--run cannon/onchain` without a file) is expected to fail inside the VM, which records the
baseline the Finchain prestate is measured against.
