# Version set

`versions.lock` holds a **candidate** set. It becomes the frozen set only after
`make preflight-a`, `make preflight-b` (architecture and flag checks) and the M1 run have
passed with exactly these artifacts, and `make lock` has replaced tags with digests.
Digest pinning fixes identity; compatibility is shown by the run, not by the pin.

## Candidates and why

| Component | Candidate | Reason |
| --- | --- | --- |
| op-contracts | v7.0.0 (Upgrade 19) | current governance-approved L1 contracts release |
| op-deployer | v0.7.1 | the v0.7 minor targets op-contracts/v7.0.0 (each op-deployer minor supports one contracts release). Verified 2026-11-11: release assets are `op-deployer-0.7.1-<os>-<arch>.tar.gz`; `init` writes `l1ContractsLocator = "embedded"` (artifacts ship inside the binary) and fills `opcmAddress` with the registry's v7.0.0 OPCM on Sepolia (0x44e1...8297), which `make intent` cross-checks. Its live broadcaster cannot size transactions on an EIP-8037 L1; see "L1 rules" below |
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

## L1 rules: Glamsterdam on Sepolia (recorded 2026-11-11)

Sepolia activated Glamsterdam (execution fork Amsterdam) on 2026-10-06; block headers carry
`blockAccessListHash`. Two of its EIPs change the cost of a chain deployment:

| EIP | Effect | Numbers |
| --- | --- | --- |
| EIP-8037 state creation gas cost increase | new state is metered in a second gas dimension ("state gas") at 1,530 gas per state byte | `CREATE`/`CREATE2` base 32,000 -> 183,600; code deposit 200 -> 1,530 gas per byte; new storage slot 20,000 -> 97,920; new account 25,000 -> 183,600 |
| EIP-7825 (Fusaka) | per-transaction gas cap 16,777,216 | under EIP-8037 the cap applies to execution gas only; `tx.gas` as a whole is bounded by the block gas limit |

Consequences observed with op-deployer v0.7.1 and the v7.0.0 OPCM on Sepolia:

- `OPContractsManager.deploy()` for one chain creates about fifteen contracts (proxies, the
  per-chain PermissionedDisputeGame implementation, DelayedWETH) and hundreds of storage
  slots. Pre-Glamsterdam rules: 8.9M gas (anvil, cast with `--evm-version osaka`). Live
  Sepolia `eth_estimateGas`: 55,667,351 gas (Tenderly gateway; providers that cap estimates
  at 50M return an error instead). The difference is state gas.
- op-deployer's live mode runs the deployment in its built-in EVM, whose chain config is
  hard-coded to Cancun-era forks, pads the result by 1.2x (10.66M) and has txmgr check that
  limit with `eth_call` before sending. On Sepolia that call reverts with
  `DeploymentFailed()` (selector `0x30116425`: a CREATE2 inside the OPCM ran out of gas and
  returned the zero address). Nothing is sent, nothing is spent, and no chain id or RPC
  choice changes this.
- op-deployer v0.8.0 and later take the gas limit from the target node's `eth_estimateGas`
  (develop branch: "A zero gas limit makes txmgr estimate against the target chain"), but
  those releases target op-contracts v8.0.0 / v9.0.0 and their OPCMs, not v7.0.0.
- Resolution kept here: `make deploy-l1` detects Amsterdam rules and uses
  `scripts/deploy-l1-calldata.sh`: op-deployer produces the calldata and the predicted
  CREATE2 addresses (`--deployment-target calldata`), the gas limit comes from the live
  node's estimate plus 5% (capped at the block gas limit), an `eth_call` dry run at that
  limit must succeed, and cast sends the transaction from the deployer key. The L1 start
  block recorded in `state.json` is the block that included the deployment.
- The same repricing raises every state-creating transaction of the chain: proposer game
  creation (clone proxy plus new slots), bridge deposits to fresh accounts, the Covenant
  World deployment. `docs/funding-model.md` carries the updated inputs. EIP-7976 (also
  Glamsterdam) raises the calldata floor cost, which the batcher pays.

References: EIP-8037 (eips.ethereum.org/EIPS/eip-8037), optimism issue #23609 (anvil
Amsterdam estimates), op-deployer broadcaster history.

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
