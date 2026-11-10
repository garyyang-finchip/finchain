# Version set

`versions.lock` holds a **candidate** set. It becomes the frozen set only after
`make preflight-a`, `make preflight-b` (architecture and flag checks) and the M1 run have
passed with exactly these artifacts, and `make lock` has replaced tags with digests.
Digest pinning fixes identity; compatibility is shown by the run, not by the pin.

## Candidates and why

| Component | Candidate | Reason |
| --- | --- | --- |
| op-contracts | v7.0.0 (Upgrade 19) | current governance-approved L1 contracts release |
| op-deployer | v0.7.1 | the v0.7 minor targets op-contracts/v7.0.0 (each op-deployer minor supports one contracts release) |
| op-reth | v2.4.2 | the tutorial pins v2.4.0; v2.4.2 adds fixes for history proof data gaps after restart, relevant to host B rebuilds and proof work |
| op-node | v1.19.3 | tutorial pin; check for a newer patch in the same minor before freezing |
| op-batcher | v1.16.11 | tutorial pin |
| op-proposer | v1.16.3 | tutorial pin |
| op-challenger | v1.9.5 | v1.9.4 is the tutorial pin; v1.9.5 fixes VM selection during Cannon-Kona prestate conversion; the permissioned path registration must be re-checked on this version |
| kona-node (prestate source) | v1.6.1 | tutorial reference for building the prestate; the built kona-client, host, Cannon VM, procedure and prestate hash are recorded separately |

op-geth reached end of support on 2026-05-31 and does not follow the Karst hardfork;
op-program has also reached end of support. Neither is used.

## Release landscape observed on 2026-11-08

The superchain-registry standard-versions file for Sepolia lists, besides v7.0.0, final
releases v8.0.0 (Upgrade 20) and v9.0.0 (Upgrade 21, OPCM deployed 2026-10-30). OPCM
addresses on Sepolia as read by `scripts/lookup-opcm.sh`:

| Release | OPCM (Sepolia) |
| --- | --- |
| op-contracts/v7.0.0 | 0x44e197058fb98fb3618453b3d90cdef6f5db8297 |
| op-contracts/v8.0.0 | 0x6abfabbc793883add5fa308a97163e8225a9f4ca |
| op-contracts/v9.0.0 | 0x160f0fe4dc1b3f4026687e8dd4b7f800879939cc |

The OPCM address shown in the OP Stack tutorial (0x3bb6...2d78) belongs to the v3.0.x
series; it is not used. Before freezing, the release choice is made explicitly: the newest
governance-approved release for which an op-deployer minor exists and for which the
op-node / op-challenger / kona candidates are documented as compatible. v7.0.0 stays the
candidate until that check is recorded here.

## Verification order

1. `make preflight-a` / `make preflight-b`: manifests exist, architecture available, every
   flag in the compose files present in the image's `--help`.
2. `make intent`: the contracts locator written by `op-deployer init` matches
   `OP_CONTRACTS_TAG`; otherwise the op-deployer release and the contracts tag disagree.
3. M1 run: genesis accepted by op-reth, derivation by op-node against the Sepolia fork
   schedule, batches accepted, proposal created with the respected game type.
4. `make lock`; commit `versions.lock` and the on-chain snapshot together.

## Deploy-config overrides

`standard-overrides` allows deploy-config overrides. Key names are release-specific; before
using `DEPLOY_OVERRIDES_JSON`, confirm the names in the op-deployer release used. Candidate
testnet overrides: dispute clock duration, clock extension, DelayedWETH delay, proof
maturity delay, dispute game finality delay. Every override used is listed in the manifest.

## Changing a version later

Change the entry, re-run the preflight on the affected host, `make restart-<host>`, observe
one full batch and proposal cycle, then `make lock`. A changed game implementation or
prestate is a governance change recorded with the L1 block.
