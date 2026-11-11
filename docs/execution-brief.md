# Finchain execution brief (v0.1, November 2026)

This brief fixes the scope of the first build. It records the decisions taken in the two
design rounds, the corrections adopted from the second review, and the open items that
the execution work must settle and document. It is the reference for `docs/runbook.md`,
`docs/acceptance.md` and the first published manifest.

## 1. Definition

Finchain is an EVM Layer 2 on the upstream OP Stack, settled on Ethereum. It is the
normative reference chain for the ten Finch covenant ERCs (8338, 8414, 8419, 8434, 8436,
8444, 8447, 8454, 8468, 8471) and the native runtime environment of FOGA. Other EVM
ecosystems can deploy, verify and adopt the same versioned rules; Finchain is where the
reference implementation lives and where each reference version is demonstrated.

The first public network is Finchain Sepolia. Mainnet is a separate deployment with its
own genesis; configuration and contract versions validated on Sepolia are reused, state
is not.

## 2. Decisions fixed

| Topic | Decision |
| --- | --- |
| Stack | Upstream OP Stack release artifacts, no code fork. Base's move to its own stack (February 2026) means Base is no longer a template; HashKey Chain remains an op-reth + op-node OP Stack chain. |
| Settlement | Ethereum Sepolia first, mainnet later. No L3-on-Base variant. |
| Deployment configuration | op-deployer `standard-overrides`: shared Sepolia SuperchainConfig, all seven chain roles controlled by Finchain. `standalone` is a mainnet-phase decision. |
| Host A | Sequencing host: op-reth, op-node (sequencer), op-batcher, op-proposer. Always-on machine controlled by the operator. |
| Host B | Verification host (AWS EC2): op-reth, op-node (verifier), op-challenger, public RPC behind Caddy. Own data volumes, own L1 provider. |
| Finality | From Ethereum: unsafe -> safe -> finalized, plus the withdrawal path. A and B are not a BFT committee. |
| Gas asset | ETH bridged from Sepolia. No custom gas token in v1. |
| Data availability | L1 calldata. A later switch to blobs requires a blob archive for long-term rebuildability. |
| Genesis | Official predeploys and system configuration only. No pre-minted native ETH on the public testnet; the deployer, treasury and faucet obtain balances through real L1 -> L2 deposits. Local devnets may pre-fund. |
| Covenant World | Deployed by ordinary transactions after chain start, before public opening. The completing block number and hash, the transaction list, code hashes and permission configuration go into the manifest. |
| Chain id | 85422 for Finchain Sepolia (83380 was the first candidate), parameterised everywhere, registry check before genesis. 8338 is excluded because of prior network use. Mainnet id decided before mainnet. |
| Domain | `finchain.one`: `rpc.`, `ws.`, `explorer.` sub-domains served from host B. |
| Key handling | Hot keys generated on the operator hosts and never leave them except the one-time move of host B's secrets over the private network. Owner roles on an externally controlled address. No `.pem` or key file is ever placed in a shared folder or the repository. |
| Delivery mode | This repository plus the runbook; the operator runs the steps on the hosts. |

## 3. Corrections adopted from the second review

1. **Proof path.** The PermissionedDisputeGame in op-contracts/v7.0.0 inherits
   FaultDisputeGame and keeps the VM step capability. The op-challenger `permissioned`
   trace type, however, is registered on the Cannon + op-program path and skips prestate
   validation; `cannon-kona` is a separate path. Configuring both does not yield
   "permissioned authorisation plus Kona full proof". Consequence: the public testnet runs
   the standard permissioned path; the full VM dispute is demonstrated on an isolated
   environment with a dedicated adversarial driver (`docs/proof-plan.md`). A game won by
   timeout is not a full-proof acceptance. `op-challenger run-trace` is a trace
   self-check, not the resident challenge service.
2. **Bond model.** `initBonds` controls only the bond paid at game creation. Moves inside a
   dispute require `getRequiredBond(position)`; the documented reference for a full-depth
   path at standard parameters is of the order of 315.6 ETH per side. Rolling occupancy of
   initial bonds is proposals per day x recovery period, not "one or two ETH"
   (`docs/funding-model.md`).
3. **Funding.** Four separate needs, each with its own line: L1 deployment; daily
   operations; bonds (initial, in flight, and the full dispute path); L2 deposits.
   Existing balances, developer quotas and faucets first; no purchase decision in v0.1.
4. **Versions.** The version set is a candidate until verified as a whole. op-deployer
   v0.7.x targets op-contracts/v7.0.0; op-reth v2.4.2 and op-challenger v1.9.5 carry fixes
   relevant to host B; op-node, op-batcher and op-proposer are candidates. Digest pinning
   proves identity, not compatibility (`docs/versions.md`).
5. **On-chain truth.** `state.json` is a deployment record. The acceptance reference is
   the configuration read from L1 at a fixed block: respected game type, game
   implementations, VM and prestate, bonds, role addresses (`make verify-onchain`).
6. **FOGA confirmation semantics.** `safe` is a provisional ledger state that can be rolled
   back by an L1 reorg. FOGA needs a rollback-capable event cursor, block-identity checks,
   idempotent business operations and on-chain state checks before resends
   (`docs/foga-confirmation-policy.md`).
7. **Two runtime profiles.** `demo` (batches every few minutes) for integration and FOGA
   demonstrations; `lowcost` (30-60 minutes) for quiet periods, with the wait stated in
   UI and records. `max-channel-duration` is counted in L1 blocks (about 300 per hour).
8. **Proposal interval** governs when output roots for withdrawal proofs appear; it is
   configured and accepted separately from batch frequency and from finalized progress.
9. **Governance record.** Shared-layer guardian, pause and upgrade authority are not
   Finchain roles under `standard-overrides`; the manifest records the actual addresses
   and scope.

## 4. Work packages

1. Version and configuration preflight on both hosts (`make preflight-a`, `make preflight-b`),
   including image architecture for host A's CPU and flag presence in the pinned images.
2. Keys, intent, funding table, L1 deployment, artifact export, on-chain snapshot.
3. Host A up, first blocks, first batches, first output proposal of the respected game type.
4. Host B up: independent derivation, p2p link, public RPC, deposit, rebuild from L1 only.
5. Covenant World deployment and FOGA integration (chain config, address book, two-cell loop,
   reorg and resend checks).
6. Proof work: resident challenger on the public testnet; isolated full-dispute drill with
   recorded evidence; withdrawal end to end.
7. First published manifest.

## 5. Out of scope for v0.1

Mainnet deployment, permissionless fault proofs on the public chain, op-conductor
sequencer HA, custom gas token, blobs, Superchain Registry membership, interop.

## 6. Status statements

Nothing in this repository has been executed against Sepolia at v0.1. Every statement
about versions, flags and costs is a candidate until the corresponding acceptance item is
recorded with its environment.
