# The covenant World on Finchain (M3 design)

This document fixes how the twelve covenant reference implementations are deployed on
Finchain Sepolia as one World, how that World is verified and recorded, and what FOGA needs
before a second, independent cell can join it. It records the decisions of the M3 design
round (D1-D15), the corrections adopted from the review, and the rules the scripts in this
repository and in the FOGA repository implement. `docs/acceptance.md` lists what counts as
done; `docs/foga-confirmation-policy.md` is the confirmation specification handed to FOGA.

## 1. Decisions

| Decision | Ruling |
| --- | --- |
| D1 source of the World | FOGA's locked artifact bundle, deployed by `foga world deploy` from the `vendor/LOCK.json` commits. Two conditions on top (section 2): every covenant stays an independently deployable, readable, callable and derivable module, and the World takes new covenants and other APIs as extensions. |
| D2 ERC-8004 | A real `IdentityRegistryUpgradeable` from the upstream repository, deployed on Finchain as the identity root (section 3). The Reputation registry is deployed beside it; the Validation registry is not a prerequisite. Named "Finchain-deployed ERC-8004 reference instance", never "the official singleton". |
| D3 World deployer | A Finchain-specific application-layer W (its own BIP-39 phrase on the deploying machine), not the Sepolia genesis phrase and not the chain operations deployer. The chain operations deployer only funds W from bridged L2 ETH (section 4). |
| D4 where it runs | The FOGA host (EC2 E06) through the public RPC `https://rpc.finchain.one`: a write enters on host B, is forwarded to host A's sequencer and is read back on B. Serial deployment is not a throughput test and is not called one. |
| D5 chain configuration | FOGA chain name `finchain-sepolia`, default RPC `https://rpc.finchain.one`; `op-stack` is a property of the chain, `demo`/`lowcost` are operating parameters recorded per run, never written as fixed confirmation times. |
| D6 recovery tests | Three environments with results recorded separately: the in-process mock chain (confirmation levels, anomalous views), anvil with a real reorg (application recovery after an EVM-level fork), and public Finchain (real tags, restart, resume, settlement). No induced reorg on public Finchain. |
| D7 fees | Three fee lines on an OP Stack chain: execution, L1 data, operator. Both the pre-send budget and the post-send accounting carry them. |
| D8 the OG | A second FOGA service on E06 with its own configuration, store, listening port, public URL and on-chain registration; the Sepolia OG stays as it is. |
| D9 second cell | First the project owner's Windows machine (integration), then Jason on his own machine, wallet and store with the candidate release package (the cross-operator acceptance, section 8). |
| D10 scenarios | The genesis T0-T9 on Finchain for the protocol scenarios (organisation T4, collective decision T5, dispute T6, safety T7, measurement T8, succession T9); the real OG and the second cell for the business loop. Two separate evidence files. |
| D11 address book | The immutable address book and the CLI checks are the acceptance basis; a read-only web page is recommended and does not block (a same-origin proxy or CORS preflight handling on the public endpoint is needed first; the page must separate "hash mismatch" from "node unreachable"). |
| D12 versions | FOGA 1.1.0, finchain 0.2.0. External acceptance with the release candidate package first, a fresh install from npm after publication. |
| D13 default chain | Bare `foga join` stays on Sepolia; Finchain through `--chain finchain-sepolia`. |
| D14 manifest | `finchain-sepolia/2026.11-rc1` with status `candidate` at the M3 close; M4 items stay `not-run`. |
| D15 pace | 3a and 3b in parallel, 3c when both are usable; one to two weeks as a target, no duration written as an acceptance promise. |

## 2. Composition rules: decoupled modules, open to extension

The World is a set of modules, one per covenant, deployed together for convenience and
recorded so that each remains usable on its own.

- A module is the contracts the covenant's own repository defines, built from the locked
  commit. The manifest records per module: covenant number, repository, commit, the
  contracts, the interface ids, and `dependsOn`: the covenants whose addresses its
  constructors or wiring calls took. A module with an empty `dependsOn` is `standalone`.
- Modules couple through published interfaces and injected addresses only. ERC-8444's
  AgentAdapter takes the ERC-8434 registry address; ERC-8471's bridge takes the ERC-8436
  registry; ERC-8447's eligibility modules take the identity registries. No module imports
  another module's implementation, and no module needs FOGA to be read, called, called
  from, or derived from. A second TaskToken, a second KYA scheme registry or a competing
  swarm registry can be deployed beside the World's by anyone; the World's instance is the
  reference instance of a version, not the only legal one.
- Anything a module needs from outside the twelve covenants is an external root, recorded
  as such: ERC-8004 (section 3) today. External roots are addresses, never vendored code.
- Extension is additive. A new covenant arrives as a new module with its own `addedAtBlock`
  and `extension: true`; existing modules, their addresses and the cells already born stay
  untouched (ERC-8489 and ERC-8490 entered FOGA this way in 0.8.0 and 0.9.0, and a cell
  enrols with `foga cell extend --covenants <n>`). Other kinds of APIs (an inference
  metering standard, a payment protocol binding) enter through an adapter module that
  speaks the covenant's interface on one side and the foreign protocol on the other, so the
  covenant contracts never change for them.
- Removal is never silent: a superseded module keeps its record with the block it was
  superseded at, and the manifest history says what replaced it.

## 3. Identity root: ERC-8004 on Finchain

Why a real registry: FOGA's ERC-8004 adapter uses registration, ownership, metadata,
agent-wallet and transfer calls of the Identity Registry; the World passes the identity
address to the ERC-8447 eligibility module, the kya-standard validation companion and the
ERC-8489 identity verifier; an ERC-8004 identity is defined by chain, registry address and
agentId. Swapping the registry later would change the identity namespace of every cell and
every binding, so the stand-in is not used on a public chain.

Upstream constraint: the upstream deployment flow (`erc-8004/erc-8004-contracts`) deploys
proxies against a `MinimalUUPS` placeholder whose `initialize()` hard-codes the upstream
owner, then upgrades them with pre-signed transactions; the real
`IdentityRegistryUpgradeable.initialize()` is a `reinitializer(2)` guarded by `onlyOwner`.
Sending the same transactions from a Finchain key does not make Finchain the owner.

What Finchain does (`scripts/deploy-8004.sh`, build in `chain/contracts/erc8004/`):

1. Build the upstream contracts at the pinned commit with the upstream compiler settings
   (solc 0.8.24, shanghai, optimizer 200, via-IR, OpenZeppelin 5.4.0) into one standard JSON
   input that carries every source; `scripts/build-8004.sh` reproduces it and compares the
   bytecode hashes.
2. Deploy the upstream test placeholder `HardhatMinimalUUPS` (source unchanged; its
   `initialize()` makes `msg.sender` the owner) and one `ERC1967Proxy` per registry whose
   constructor calls that initializer, so the chain operations deployer is the owner.
3. Deploy `IdentityRegistryUpgradeable` and `ReputationRegistryUpgradeable`, and upgrade
   each proxy with `upgradeToAndCall(impl, initialize(...))`, the reinitializer the upstream
   flow uses. The Reputation registry is initialised with the Identity proxy.
4. Verify before anything else: the ERC-1967 implementation slot, `getVersion`, name and
   symbol, the EIP-712 domain (`ERC8004IdentityRegistry`, version `1`, chain id 85422, the
   proxy address), the runtime code of every contract against the build with the
   `UUPSUpgradeable` immutable masked, `getIdentityRegistry()` of the Reputation registry,
   and a simulated `register()` from an unrelated address (returns agent id 0, changes
   nothing).
5. Transfer ownership of both proxies to the Finchain owner address. From then on that
   address is the upgrade authority; the deployer holds no role in the registries.
6. Record `chain/out/erc8004.json`: addresses, transactions, blocks, gas, raw and masked code
   hashes, the checks, the completing block.

The Validation registry is not deployed: nothing in the World calls it (the World's
ERC-8004 validation companion comes from kya-standard), and the upstream text says that part
is still changing. It can be added later as a further external root.

Deployed on 2026-11-12 (Finchain blocks 26019-26046, eight transactions from the chain
operations deployer, every check passed, record `chain/out/erc8004.json`): IdentityRegistry
proxy `0x363E71C6c33d4B5980B31B558D1E16B52EB3C8E9` (implementation
`0x5acfaf6c0fdabf9f83a8a0d0a8f25bf6e98ffa8e`, version 2.0.0), ReputationRegistry proxy
`0xF0A3ba008486cCc0bf994d5c06cE095E0b1D08e2` (implementation
`0x6964d60ccc11f9800e5bee77d9f3f51f8cfd9250`), both owned by
`0xF8D8846e505E5478C60B57182D39f61b066cA8E2`; completing block 26046. FOGA's
`worlds/finchain-sepolia.json` names the Identity proxy as its identity root.

Before the World binds to the registry, the first FOGA cell born on Finchain is the live
registration test: `ownerOf(agentId)` must be the cell's account contract. The genesis T1
checks exactly that; the evidence names the agent id. Whether an external indexer lists the
Finchain instance as "the" ERC-8004 registry of chain 85422 is a separate, later task.

## 4. W and the roles

| Key | Lives | Does |
| --- | --- | --- |
| Chain operations deployer (`keys/deployer.json`, host A) | host A | deployed the L1 contracts and the identity root; funds W on L2 with `make l2-send` |
| W, the World deployer and genesis treasury | a new phrase on the FOGA host: `foga keys new --out ~/.foga/finchain.mnemonic` | deploys the World (the genesis requires `ADRFServiceEscrow.admin() == W`), bootstraps the ERC-8489 flows, funds the drill roles |
| Drill roles (G, owners, operators, E, J1-J3) | the same phrase | the genesis T0-T9 only; T7 stops a drill cell, T9 moves a drill identity; neither touches the OG or the second cell |
| The OG's wallet | E06 (`/opt/foga/wallet`) | the same address on Sepolia and Finchain; on Finchain it registers a new cell account and a new ERC-8004 agent id - continuity is the address, not the ids |
| Jason's wallet | Jason's machine | the second cell; never W, never a drill role, never the OG key |

Separating "the same OG wallet on every chain" from "the same deployment phrase on every
chain" is deliberate: W is a treasury and a deployer, the OG wallet is an identity.

Funding is reported in four lines, each with its own transactions: the identity root (chain
operations deployer), the World deployment (W), the genesis T0-T9 (W and the drill roles),
the two-cell business loop (the OG and the second cell). An initial reserve of 0.2-0.3 ETH
on L2 for W is a provisional figure, not an approved total: `foga genesis preflight` prints
the software budget, the receipts of the run give the cost, and the two are compared in the
evidence. FOGA's budget model prices gas at a floor of 0.1 gwei by default; Finchain's base
fee is near zero and the L1 data fee is small at the current scalars, so the floor, not the
chain, sets the reserve.

## 5. Deployment, resume and verification rules

Fixed at the first run and checked on every resume, each a stop on mismatch: chain id,
genesis block hash, W, the identity root address, the bundle hash. A resumed run that finds
a different bundle hash is a different build and does not continue a world file written by
another.

Every transaction is tracked before it is broadcast: the world file gets a `pending` record
with the nonce, the signed transaction hash and, for a deployment, the predicted address.
On resume a pending record is settled by the chain, not by assumption: a receipt for the
hash completes it; code at the predicted address with no receipt yet is awaited; a free
nonce means the transaction never reached the chain and it is sent again; a nonce consumed by
something else stops the run (`OperationAmbiguous` in FOGA's terms) for a person to decide.
A step recorded as deployed is accepted on resume only if its code identity matches the
bundle; wiring recorded as done is accepted only if the getter says so (`kindAdapter` for the
ERC-8444 kinds, `participationRegistry()` for ERC-8489).

Two blocks are recorded and never confused:

- `completionBlock`: the block of the last transaction the World needed - deployment,
  wiring, or the default flow bootstrap. From this height the World answers "what can be
  done here" completely. Policies, bindings and drill contracts created by the genesis after
  T0 are listed separately.
- `verifiedAt`: a later block, at or below `finalized` when checked, at which every address
  of the World was read and matched. Checking is repeatable; the manifest names the report.

Verification is three reports, made at one fixed block and kept apart:

1. Raw code hashes: `eth_getCode` of every address at the block, keccak256, compared with the
   address book. Host B reads it through the public endpoint (`make verify-world`); this
   needs no FOGA checkout and no bundle.
2. Build identity: FOGA's `world check` compares the runtime code with metadata stripped
   and link/immutable slots masked against the locked bundle, per contract, and reports
   the contracts it cannot compare (an attached or external contract) as such rather than as
   passed.
3. Links, permissions and wiring: libraries linked, immutable arguments, the proxy's
   implementation, owners and admins (`ADRFServiceEscrow.admin() == W`, the ERC-8444
   registry owner, the allow-list and subject-set owners, the identity root's owner), the
   kinds registered, the participation registry set, the flows recorded.

Required items (identity root, permissions, bundle identity of every World contract, the
two blocks) block `rc1` when they are unknown; optional items (an interface id upstream
publishes none for) are explained one by one. "The doctor ran" and "a Sourcify dry-run was
archived" are not verification results.

## 6. Fees on an OP Stack chain

A Finchain transaction pays the L2 execution fee, the L1 data fee (`GasPriceOracle` at
`0x420000000000000000000000000000000000000F`: `getL1Fee(bytes)` over the full unsigned
serialised transaction, not the calldata alone) and the operator fee (scalar and constant
read from the same oracle; configured as zero in this chain's intent, read every time, never
assumed). `eth_estimateGas` covers execution only. FOGA's budget checks add the two other
lines before sending; its receipts record all three from the receipt fields the node
returns; a value that cannot be read is recorded as unknown, not as zero. Where ERC-8454
measures value, gross reward, net withdrawal and the fees each signer paid are kept apart.

## 7. Confirmation and recovery (the 3b work)

Three judgements, made separately: the receipt exists; the block that holds it is still on
the canonical chain; that block has reached the required level (`safe`, `finalized`).
FOGA's transaction manager today answers the first, and its pinned reads answer "is my write
visible yet"; the second and third are new, and so is what the cell does when they change.

| Test | Must be observed |
| --- | --- |
| Same height, new block hash; the transaction is included again later | provisional records of the old branch are withdrawn, processing replays from the common ancestor, one settlement per task |
| Block hash unchanged, `safe` moved backwards | the record falls back to provisional and the next step that depends on `safe` pauses; comparing heights or hashes alone misses this |
| Logs missing, connection lost, or a switch to a lagging node | a rescan from the known cursor with identity checks; one empty answer is not a reorg; a missing `finalized` never degrades to `latest` |
| External payment delivered, crash before the local record | the receiver is queried or deduplicated by the stable business id; a counterparty that is neither idempotent nor queryable leaves the operation "outcome unknown, to be reconciled", never paid twice |

Business idempotency keys bind chain id + World + task or fulfilment + action, so a
transaction that moves to another block is the same business fact; on-chain event identity
is block hash + transaction hash + log index. A local effect log alone cannot make an
arbitrary external API both not skipped and not repeated; the design states which
downstream calls return idempotent receipts and where automatic recovery stops at "to be
reconciled".

Timing conflict to resolve in 3b: FOGA's public timing profile uses a 180 s council window,
a 60 s appeal window and a 180 s evidence window, while a `demo` batch reaches `safe` about
every three minutes. A cell that waits for the proposal to be `safe` may find the window
closed and prove only a timeout. The confirmation standard stays; Finchain gets its own drill
windows with room for batch delay, execution and retry, steps a single party prepares are
not each held at `finalized`, "expected to pass" and "deliberately undecided" runs are
distinguished, and the active profile is recorded in the evidence of each run.

Environments: the mock chain for levels and anomalous views, anvil for a real EVM fork (the
test asserts the common ancestor is unchanged, the replaced block's hash changed, and the old
receipt or logs behave as expected), public Finchain for the normal path. A real L1 reorg
with re-derivation stays an M4 item.

## 8. The second cell: cross-operator acceptance sheet

Preconditions: the World verified (section 5) and published in the FOGA release candidate
(`deployments/finchain-sepolia.json`, `foga join --chain finchain-sepolia` from the real
tarball of both package names); the OG's Finchain service up; a documented way for a new
wallet to obtain L2 gas (bridge Sepolia ETH to the portal, or a small transfer from the
project).

Steps, performed by the second operator on their own machine, with their own wallet and
store, through the public RPC, touching neither W nor the OG key:

1. install the candidate package in a clean directory; `foga join --chain finchain-sepolia`;
2. the cell is born (account, ERC-8004 agent id, binding, publication, market admission);
3. the OG mints a tender with a reward; the second cell discovers it, qualifies, commits,
   runs the skill, submits;
4. the OG accepts; the reward is credited; the second cell withdraws it (an application
   payment on L2, not an L2 to L1 bridge withdrawal);
5. both cells report the task id, both cell accounts, every transaction, the reward credited
   and the amount withdrawn; the confirmation level at which each step proceeded and the
   active batcher profile are part of the record.

The first run on the project owner's own machine is integration; only the run by the second
operator supports the statement "another independent operator has joined".

## 9. Deliverables and order

| Step | Host | Repository | Output |
| --- | --- | --- | --- |
| 3a-1 identity root | A (chain operations deployer) | finchain | `chain/out/erc8004.json` |
| 3a-2 W and funding | E06 (`foga keys new`), A (`make l2-send`) | - | W address, funding transaction |
| 3a-3 World | E06, public RPC | foga | `deployments/finchain-sepolia.json` with `completionBlock` |
| 3a-4 verification | E06 (`foga world check`), B or A (`make verify-world`) | foga, finchain | check report, `verifiedAt`, `manifests/evidence/world-verify-<block>.json`, the manifest `covenantWorld` section |
| 3b confirmation and recovery | development, mock chain and anvil | foga | kernel changes, tests, drill windows |
| 3c cells and scenarios | E06, the second operator's machine | foga, finchain | genesis T0-T9 evidence, two-cell evidence |
| 3d close | - | foga 1.1.0, finchain 0.2.0 | manifest `finchain-sepolia/2026.11-rc1` (candidate) |
