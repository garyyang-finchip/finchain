# The covenant World on Finchain (M3 design, revision 2)

This document fixes what M3 proves and in which order. Revision 2 replaces the first
design round's coupling of Finchain's milestone to a FOGA release with three separate
acceptances: Finchain usable on its own, FOGA usable without Finchain, and FOGA on Finchain
as an optional, explicit integration. `docs/acceptance.md` lists the items;
`docs/foga-confirmation-policy.md` is the confirmation specification handed to FOGA.

## 1. Product boundaries

| Subject | Hard condition for independent operation |
| --- | --- |
| Finchain | With no FOGA installed on either operator host, an ordinary wallet transfers ETH through the public RPC, a developer deploys, writes and reads an ordinary EVM contract, and the nodes produce, derive and finalize blocks as before. |
| FOGA | With `finchain.one` entirely offline and no Finchain repository, address book or account at hand, the local quickstart, the existing Sepolia World and the Sepolia OG work as they did, and the program makes no attempt to reach Finchain. |
| FOGA on Finchain | A deployment the user chooses. Only when Finchain is chosen are its RPC, its ERC-8004 registry and its World read. Finchain may be the preferred reference deployment of the twelve covenants; other compatible chains need no registration with it and no permission from it. |

"FOGA on its own" does not mean FOGA needs no chain: it needs a World compatible with it on
the chain the user picked, local, Sepolia or, from now on, Finchain. "Native reference
chain" describes what Finchain does for the ecosystem; it is never a dependency of FOGA on a
chain id. Consequently:

- Finchain's milestone never requires a FOGA release. What M3 needs from FOGA it takes from
  the released package (`@finchip.ai/foga` 1.0.7 and its `--world` / `--rpc` interfaces).
- The Finchain world configuration, the address book and the deployment evidence live in
  this repository (`chain/world/`), not in FOGA's package.
- Improvements to FOGA that the Finchain work suggests (a deployment that records every
  transaction before broadcasting it, an address-book check against the chain, the OP Stack
  confirmation and recovery semantics, three fee lines) are proposals to FOGA, reviewed on
  FOGA's own terms and cross-chain regression standard, each gated by the isolation check of
  section 3. None of them is an M3 condition.

## 2. Finchain on its own (M3-A)

Evidence that the chain is complete and usable with no application in the picture, on top
of M1 and M2:

1. `make evm-acceptance` (host A, or any machine with the deployer key): through the public
   RPC, a plain transfer from the deployer key to the owner's wallet address; the deployment
   of `FinchainProbe` (`chain/contracts/probe/`, a one-word contract unrelated to any
   covenant), a write (`set(<deployment block>)`) with its event, and the read-back by call
   and by storage slot. The record is `chain/out/evm-acceptance.json`.
2. `make verify-evm` (host B, once the completing block is `finalized`): receipts by hash
   (status, block, block hash), code hash and storage at the fixed block, a call at the
   block, the recipient's balance, the completing block canonical and finalized, read from
   host B's own node. The report lands in `manifests/evidence/`.
3. A wallet user repeats the transfer by hand: the owner's wallet, funded by step 1, sends
   ETH back through `rpc.finchain.one` from MetaMask; the transaction hash is recorded.

The ERC-8004 reference registries deployed on 2026-11-12 (`chain/out/erc8004.json`; section
4) belong to this acceptance too: an application-level registry anyone on the chain may
use, deployed and owned by the chain's operators, needed by no node and by no wallet.

## 3. FOGA on its own (M3-B)

A reverse acceptance for any FOGA package, released or candidate, run from this repository:
`make foga-isolation VERSION=<version>` (`scripts/foga-isolation-check.sh`). The package is
installed from the npm registry into a clean directory with a clean home; every Node process
it starts is preloaded with `scripts/foga-isolation-preload.mjs`, which records each host
name the process resolves or connects to and refuses every name under `finchain.one` at the
resolver and at the socket. Two controls run first (a real name is logged; `rpc.finchain.one`
is refused). The legs are the release check's own: `--help`; the chain table and its default
(`sepolia` with a packaged world); the local quickstart (anvil); the local genesis T0-T9;
and, with `SEPOLIA_RPC_URL` set, a read of the packaged Sepolia World by the doctor. The
result is a record under `manifests/evidence/`: every leg passing, zero names under
`finchain.one`, the host names actually used listed.

The baseline is the released 1.0.7, which has no Finchain code at all. The rule that follows
is Finchain's, not FOGA's: FOGA decides when it releases and runs its own release check;
Finchain runs this check on every FOGA version it adopts for a run on the chain, before
that run, and files the record beside the baseline. So far: 1.0.7 (2026-11-12, the World
deployment and the genesis), 1.0.8 (2026-11-13, `foga-isolation-1.0.8-20261113T073041Z.json`:
five legs, 50 host-name entries, zero under `finchain.one`, the Sepolia World read through a
public endpoint), the version the OG on Finchain was born with, and 1.0.9 (2026-11-13,
`foga-isolation-1.0.9-20261113T141222Z.json`: the same five legs, 50 entries, zero under
`finchain.one`), the version both OG services run since the same day and the version of the
business loop's two cells (section 5.5). The store-resume leg (an old cell store continued by
a new version) is run from a FOGA checkout by its own test suite; it is not part of this
script.

## 4. Identity root: ERC-8004 on Finchain

Why a real registry: FOGA's ERC-8004 adapter uses registration, ownership, metadata,
agent-wallet and transfer calls of the Identity Registry; a World passes the identity
address to the ERC-8447 eligibility module, the kya-standard validation companion and the
ERC-8489 identity verifier; an ERC-8004 identity is defined by chain, registry address and
agentId. Swapping the registry later would change the identity namespace of every cell and
every binding, so the stand-in is not used on a public chain.

Upstream constraint: the upstream deployment flow (`erc-8004/erc-8004-contracts`) deploys
proxies against a `MinimalUUPS` placeholder whose `initialize()` hard-codes the upstream
owner, then upgrades them with pre-signed transactions; the real
`IdentityRegistryUpgradeable.initialize()` is a `reinitializer(2)` guarded by `onlyOwner`.
Sending the same transactions from a Finchain key does not make Finchain the owner.

What Finchain did (`scripts/deploy-8004.sh`, build in `chain/contracts/erc8004/`):

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

Deployed on 2026-11-12 (Finchain blocks 26019-26046, eight transactions from the chain
operations deployer, every check passed): IdentityRegistry proxy
`0x363E71C6c33d4B5980B31B558D1E16B52EB3C8E9` (implementation
`0x5acfaf6c0fdabf9f83a8a0d0a8f25bf6e98ffa8e`, version 2.0.0), ReputationRegistry proxy
`0xF0A3ba008486cCc0bf994d5c06cE095E0b1D08e2` (implementation
`0x6964d60ccc11f9800e5bee77d9f3f51f8cfd9250`), both owned by
`0xF8D8846e505E5478C60B57182D39f61b066cA8E2`; completing block 26046.

The Validation registry is not deployed: nothing a World calls needs it (FOGA's ERC-8004
validation companion comes from kya-standard), and the upstream text says that part is
still changing. It can be added later as a further external root. Whether an external
indexer lists the Finchain instance as "the" ERC-8004 registry of chain 85422 is a separate,
later task. The registry is named "Finchain-deployed ERC-8004 reference instance", never
"the official singleton".

## 5. FOGA on Finchain (M3-C): an optional, explicit integration

Everything in this section uses the released FOGA package as it is, through the interfaces
it already has: `foga world deploy --world <config> --rpc <url>`, `foga genesis run --world
<address book> --rpc <url>`, `foga join --world <address book> --rpc <url>`. Nothing changes
in FOGA's default chain (bare `foga join` stays on Sepolia), nothing is published, and the
Sepolia OG is not touched.

### 5.1 Composition rules: decoupled modules, open to extension

The World is a set of modules, one per covenant, deployed together for convenience and
recorded so that each remains usable on its own.

- A module is the contracts the covenant's own repository defines, built from the locked
  commit (FOGA's `vendor/LOCK.json`). The manifest records per module: covenant number,
  repository, commit, the contracts, and `dependsOn`: the covenants whose addresses its
  constructors or wiring calls took. A module with an empty `dependsOn` is `standalone`.
- Modules couple through published interfaces and injected addresses only. ERC-8444's
  AgentAdapter takes the ERC-8434 registry address; ERC-8471's bridge takes the ERC-8436
  registry; ERC-8447's eligibility modules take the identity registries. No module imports
  another module's implementation, and no module needs FOGA to be read, called, called
  from, or derived from. A second TaskToken, a second KYA scheme registry or a competing
  swarm registry can be deployed beside the World's by anyone; the World's instance is the
  reference instance of a version, not the only legal one.
- Anything a module needs from outside the twelve covenants is an external root, recorded
  as such: ERC-8004 (section 4) today. External roots are addresses, never vendored code.
- Extension is additive. A new covenant arrives as a new module with its own `addedAtBlock`
  and `extension: true`; existing modules, their addresses and the cells already born stay
  untouched. Other kinds of APIs (an inference metering standard, a payment protocol
  binding) enter through an adapter module that speaks the covenant's interface on one side
  and the foreign protocol on the other, so the covenant contracts never change for them.
- Removal is never silent: a superseded module keeps its record with the block it was
  superseded at, and the manifest history says what replaced it.

### 5.2 W and the roles

| Key | Lives | Does |
| --- | --- | --- |
| Chain operations deployer (`keys/deployer.json`, host A) | host A | deployed the L1 contracts and the identity root; funds W on L2 with `make l2-send` |
| W, the World deployer and genesis treasury | a new phrase on the FOGA host: `foga keys new --out ~/.foga/finchain.mnemonic` | deploys the World (the genesis requires `ADRFServiceEscrow.admin() == W`), bootstraps the ERC-8489 flows, funds the drill roles |
| Drill roles (G, owners, operators, E, J1-J3) | the same phrase | the genesis T0-T9 only; T7 stops a drill cell, T9 moves a drill identity; neither touches the OG or the second cell |
| The OG's wallet | E06 (the Sepolia OG's wallet directory) | the same address on Sepolia and Finchain (`0x5Fee42D697975f6154164b29371c1c447F56fb4E`); on Finchain it registered a new cell account (`0x9F7647013499C44B7E0432F5E9e22E4Afd447aD1`) and a new ERC-8004 agent id (6) on 2026-11-13 - continuity is the address, not the ids |
| The second operator's wallet | that operator's machine | the second cell; never W, never a drill role, never the OG key |

Separating "the same OG wallet on every chain" from "the same deployment phrase on every
chain" is deliberate: W is a treasury and a deployer, the OG wallet is an identity.

### 5.3 Configuration, address book, deployment and verification

- `chain/world/finchain-sepolia.world.json` is the FOGA world configuration for Finchain
  (schema `foga.world-config/1`, deploy mode, the identity root of section 4, the RPC from
  `FINCHAIN_SEPOLIA_RPC_URL`). It is passed to the released FOGA with `--world`; FOGA's
  package does not carry it.
- The address book FOGA writes (`deployments/<name>.json` in FOGA's working directory) is
  copied into this repository as `chain/world/finchain-sepolia.json`, with the FOGA version
  and bundle hash that produced it. `make world-manifest` (`scripts/world-manifest.sh`)
  derives the manifest's `covenantWorld` section from it: the completing block from the
  deployment, wiring and flows receipts, the raw code hash of every contract at that block,
  the modules with their constructor-injected dependencies, the build identity and the
  repository and commit of each covenant from the same package's bundle, the identity root
  from `chain/out/erc8004.json`. The procedure is in `chain/world/README.md`.
- Two blocks are recorded and never confused: `completionBlock`, the block of the last
  transaction the World needed (deployment, wiring, or the default flow bootstrap) - from
  this height the World answers "what can be done here" completely; and `verifiedAt`, a
  later block at or below `finalized` at which every address was read and matched.
- Verification is three reports made at one fixed block and kept apart: raw code hashes
  (`eth_getCode` at the block, keccak256; host B through the public endpoint,
  `make verify-world`, which needs no FOGA checkout); build identity (the runtime code with
  metadata stripped and link/immutable slots masked against FOGA's bundle, read from the
  released package's `artifacts/bundle.json`); links, permissions and wiring (owners and
  admins, the ERC-8444 kinds, the ERC-8489 participation registry, the recorded flows, the
  identity root's implementation slot and owner). Required items (identity root,
  permissions, build identity of every World contract, the two blocks) block the manifest
  candidate when unknown; optional items are explained one by one. "The doctor ran" and
  "a Sourcify dry-run was archived" are not verification results.
- Funding is reported in four lines, each with its own transactions: the identity root
  (chain operations deployer), the World deployment (W), the genesis T0-T9 (W and the drill
  roles), the two-cell business loop (the OG and the second cell). An initial reserve of
  0.2-0.3 ETH on L2 for W is a provisional figure: `foga genesis preflight` prints the
  software budget, the receipts give the cost, and the two are compared in the evidence.
  FOGA 1.0.7 budgets execution gas only; the L1 data fee and the operator fee of an OP
  Stack transaction are read from the receipts and reported beside it.

### 5.4 The deployments so far

Two Worlds were deployed by the released FOGA 1.0.7 from `chain/world/finchain-sepolia.world.json`.
The first (`finchain-sepolia-85422-20261112T154525Z`, 2026-11-12) is superseded: its genesis
stopped at T4 because cell A held ERC-8004 agent id 0, the value the ERC-8447 eligibility
module treats as "no agent" (the account of the record is in `chain/world/README.md`). The
second (`finchain-sepolia-85422-20261113T023727Z`, 2026-11-13) is the reference World: the
genesis T0-T9 ran on it from a fresh store with both ZK paths on (197 of 197 checks, 213
operations, cells registered as agents 3, 4 and 5), and the doctor judged all twelve
covenants Pass on layer 5 (278 Pass, 0 Fail, 2 Unknown, 25 NotApplicable). The finding
about agent id 0 is an upstream item for the ERC-8447 reference module; neither the chain
nor FOGA was changed for it.

The three files the released package wrote for the reference World are kept as it wrote
them: the address book is `chain/world/finchain-sepolia.json`; the genesis evidence
(`foga.genesis-evidence/1`: 197 checks over T0-T9, 213 operations confirmed in blocks
61597-63560 between 02:44 and 03:49 UTC on 2026-11-13, journal, facts and per-step
evidence) is `manifests/evidence/foga-genesis-finchain-sepolia.json`; the doctor report
(`foga.doctor-report/1`, read live through the public RPC at block 64557) is
`manifests/evidence/foga-doctor-finchain-sepolia.json`. The doctor's two Unknown items are
the `supportsInterface` answers of `ADRFServiceEscrow` for `IADRFExecutor` and
`ISettlementLedger`: the contract is built from those interfaces but does not declare
their ids, and upstream publishes none, so the report calls it a design choice rather than
a defect; the answer is a property of the locked bundle, so every World deployed from it
gives the same two, Sepolia included. The execution fees of the
213 genesis operations sum to 128,323,691 gas at an effective price of 1,000,251 wei
(about 0.001 gwei: FOGA's priority fee over the 251 wei base fee), 0.000128 ETH in all; the
L1 data fees and the operator fee come from the receipts: `make fee-lines`
(`scripts/fee-lines.sh`) reads every transaction of the four funding lines (identity root,
World deployment, genesis, business loop) through the public RPC and writes the three fee
components of each line to `manifests/evidence/fee-lines-<date>.json`, the M3-C evidence
file's funding section. Run on 2026-11-13 (`fee-lines-20261113T151307Z.json`): the identity
root's 9 transactions cost 1.69 nano-ETH (the deployer's 252 wei a gas), the World's 63
cost 0.0000849 ETH, the genesis's 213 cost 0.000128 ETH, the business loop's 7 cost
0.00000497 ETH; the L1 data fees are tens to hundreds of thousands of wei per line, the
operator fee is zero (the chain sets none), and the whole of M3-C cost about 0.000218 ETH
in fees at the demo profile - two orders of magnitude below the provisional reserve.

The manifest section of the reference World, `manifests/covenant-world-finchain-sepolia.json`,
records the completing block 61548 (the last of the eight wiring and flows transactions)
and the raw code hash of every contract at that block; host B verified it at its finalized
block 61794 (`manifests/evidence/world-verify-61794.json`: the identity root's four and the
World's 55 contracts MATCH, completion block canonical), and the check repeated after
`verifiedAt` was filled. The first attempt that day ran while host B's L1 provider had cut
the host off (monthly quota; `docs/runbook.md`, section 8, and `docs/networking.md`): B's
finalized head stood at 58794, below the completing block, so every World address showed
no code yet. That report was discarded, B was moved to another provider, and the check was
run again once its finalized head had passed the deployment. `make verify-world` now stops
with `NOT YET` in that situation instead of writing a report.

The OG lives on Finchain since 2026-11-13 (`manifests/evidence/og-finchain-2026-11-13.json`,
`chain/world/README.md`). It was born by the public path, `foga join --world
chain/world/finchain-sepolia.json --rpc https://rpc.finchain.one`, from the FOGA host's
checkout at v1.0.8 (the version whose isolation record is in section 3), with the identity
wallet the Sepolia OG already has: one agent, one identity (`0x5Fee42D697975f6154164b29371c1c447F56fb4E`),
a cell account on each chain. On Finchain it is cell `OG`, account
`0x9F7647013499C44B7E0432F5E9e22E4Afd447aD1`, ERC-8004 agent 6 of the identity root, under
FOGA-Cell-v2 with all thirteen covenants; it holds and offers `foga-probe` (skill token 3)
and `finch-extract-verify` (token 4), its four documents are committed on chain, its channel
`0x5a8118c2…` is anchored and disclosed, it is admitted to the World's market as submitter
and responder, and it is enrolled in the ERC-8490 registry with one cycle run. The birth,
the skills and the documents cost 0.005 ETH of the 0.05 ETH the chain operations deployer
sent it. It is served by a second systemd unit on the FOGA host (`foga-og-finchain`, host
mode, `127.0.0.1:8788`) behind the same Caddy as the Sepolia OG, at `https://og.finchain.one`
(`/healthz`, `/.well-known/foga-cell.json`, `/.well-known/agent-card.json`, `/mcp`, `/a2a`,
`/documents/*`), with its own configuration, store, API key and logs; the Sepolia OG is
untouched (account `0xD7155E48f83e1fEa9eAFED0200671638f290ED49`, agent 11261,
`foga.finchip.ai`). The manifest and the agent card were read from outside the project's
hosts. On Finchain the OG is a resident: W deployed the World and bootstrapped the flows, so
W is the controller of the family `foga` and the authority of the market the OG joined. The
two-cell business loop (D9, D10) ran on 2026-11-13 at its integration stage, the OG as the
demander (section 5.5). The readiness check of the served cell (`foga node preflight`) under
1.0.8 passed 35 items, warned on one (no KYA standing yet) and failed one, and that failure
was a finding for FOGA, not for the chain: a cell without `identity.standing` got a probe
input with no `kya` block, the probe's ERC-8419 section dereferenced it, and the resulting
TypeError was retried as a transport failure until the check failed ("the RPC failed 7
times (Cannot read properties of undefined (reading 'issuers'))"); the skill itself ran on
this World in the genesis. FOGA took the fix on its own terms in 1.0.9 (an optional `kya`
block, a probe defect raised at once instead of retried); both OG services were restarted on
1.0.9 the day it was released (`/healthz` version 1.0.9 on both names), and the same
readiness check of the Finchain OG then passed 36 items with the one warning and no failure
("probed 0x9F76…7aD1 at block 82141 in 1012 ms"). The two other FOGA-side items M3-C
produced went the same way: `--world https://…` for `join`, `genesis` and `doctor` is in
1.0.9 (this repository's address book is joined by its URL, section 5.5), and the ERC-8447
eligibility sentinel for agent id 0 is an upstream item (section 5.4 and
`chain/world/README.md`).

### 5.5 Scenarios and the second cell

The genesis T0-T9 run with `--world chain/world/finchain-sepolia.json` gives the four
scenario classes (organisation T4, collective decision T5, dispute T6, safety T7) plus
measurement T8 and succession T9; the real OG and the second cell give the business loop.
Two evidence files. The second cell is run by another operator on their own machine, with
their own wallet and store, through the public RPC, with the released package and the
address book from this repository (`foga join --world chain/world/finchain-sepolia.json
--rpc https://rpc.finchain.one`): the cell is born; the OG mints a tender; the second cell
discovers, qualifies, commits, runs the skill, submits; the OG accepts; the reward is
credited and withdrawn (an application payment on L2, not an L2 to L1 bridge withdrawal);
both report the task id, both cell accounts, every transaction, the reward credited and the
amount withdrawn, the confirmation level each step proceeded at and the active batcher
profile. The first run on the project owner's own machine is integration; only the run by
the second operator supports "another independent operator has joined".

The integration stage ran on 2026-11-13 (`manifests/evidence/business-loop-2026-11-13.json`).
The second cell, `cell-b`, was made on host B's machine as an ordinary user of the public
RPC (nothing of node-b is involved) from the npm registry's 1.0.9 package, with a wallet
made for it, by one command - the address book named by its URL in this repository:

```
npx -y @finchip.ai/foga join --world https://raw.githubusercontent.com/garyyang-finchip/finchain/main/chain/world/finchain-sepolia.json --rpc https://rpc.finchain.one --run stub
```

The package fetched the book (sha256 `fc26a8f23848…`, kept under `~/.foga/worlds/` by chain
id, worldId and content hash), the chain operations deployer funded the identity with 0.05 ETH
(block 82422), and the join did the rest: account `0x2Dd0c30383EcD6414e0b9DD6F10bf27BFe8715BB`,
ERC-8004 agent 7, skill tokens 5 and 6 offered, documents committed, channel opened and
anchored, market joined (submit, respond), maintenance enrolled, the node served with the
stub model so that it takes the tenders it is eligible for with no person at the entrance.
The OG then acted as the demander through its own node: `skill_run` (it ran `foga-probe`
itself for the task's input - cell-b's account at block 82807 - and obtained the answer
hash) and `tender_mint` (tender 5 on the World's TaskToken, 0.0005 ETH in escrow, the
answer hash committed in the hashlock verifier, an ERC-8444 task record; blocks 82883-82891).
cell-b's watcher found the tender at block 82887; its first pre-check was refused at the
verifier gate because the commit had not landed yet (82889) - a tender that cannot be
machine-accepted is not taken; at block 82918 it pre-checked again, ran the probe in its
worker, reproduced the answer and submitted (block 82920); the verifier accepted
(submission 1, status 1, `machineSettled`); the watcher settled (block 82929) and the
reward arrived in cell-b's account (0.005 to 0.0055 ETH; the OG's account 0.005 to 0.0045),
with nothing left to withdraw. Six transactions, every receipt status 1; both sides on
1.0.9 (the OG from the tagged checkout built on its host, cell-b from the registry); the
fees of each in the evidence file, and the finalized re-read of the six by `make fee-lines`
(`manifests/evidence/fee-lines-20261113T151307Z.json`: all seven receipts, the funding
transfer included, canonical at or below the finalized head 83370). What the integration
stage does not show is the other operator: both cells are the project owner's (two keys, two
accounts, two hosts), and the acceptance stage of D9 stays open. The M3-C summary, one index
over every evidence file of this section with the four funding lines, is
`manifests/evidence/m3c-2026-11-13.json`.

## 6. Confirmation and recovery on an OP Stack chain: a FOGA proposal, not an M3 condition

FOGA's transaction manager answers "does the receipt exist" and its pinned reads answer
"is my write visible yet". Two more judgements are needed on a rollup - "is the block that
holds it still canonical" and "has it reached `safe` or `finalized`" - and so is what the
cell does when they change. The specification is `docs/foga-confirmation-policy.md` with its
four observable test cases, the timing conflict (FOGA's 180 s council and evidence windows
against a `demo` batch interval of about three minutes) and the three environments (mock
chain, anvil with a real reorg, public Finchain normal path). It is work on FOGA, reviewed
and released on FOGA's own terms, gated by the isolation check of section 3; Finchain's M3
records what the released package does and does not do about confirmation levels, and a
cell on Finchain that waits for `safe` or `finalized` before an irreversible step does so by
its operator's procedure until FOGA provides it.

## 7. Decisions, revision 2

| Decision | Ruling |
| --- | --- |
| D1 source of the World | FOGA's locked bundle, deployed by the released `foga world deploy` from a configuration kept in this repository; every covenant stays an independently deployable, readable, callable and derivable module (5.1) and the World takes new covenants and other APIs as extensions. |
| D2 ERC-8004 | A real registry deployed on Finchain (section 4): done, verified, owned by the owner address; Reputation beside it, Validation not a prerequisite. |
| D3 World deployer | A Finchain-specific W with its own phrase; the chain operations deployer funds it. |
| D4 where it runs | The FOGA host (E06), with the released package, through the public RPC. |
| D5 chain configuration | Kept in this repository (`chain/world/`); FOGA's chain table is not changed for M3. |
| D6 recovery tests | A FOGA proposal (section 6), separate from M3. |
| D7 fees | Three fee lines read from receipts and reported in the evidence; the budget model is FOGA's. |
| D8 the OG | A second FOGA service on E06 with its own configuration, store, port, public URL and registration, started with `--world` and `--rpc`; the Sepolia OG stays as it is. |
| D9 second cell | The project owner's machine first (integration), then another operator (acceptance). |
| D10 scenarios | The genesis T0-T9 on Finchain for the protocol scenarios; the real cells for the business loop; two evidence files. |
| D11 address book | The address book in this repository plus `make verify-world` are the acceptance basis; a read-only web page is recommended and does not block (the public endpoint answers no CORS preflight today). |
| D12 versions | No FOGA release is an M3 condition; finchain 0.2.0 at the M3 close. FOGA proposals ship as FOGA decides. |
| D13 default chain | FOGA's bare `foga join` stays on Sepolia; Finchain through `--world` (and through a chain-table entry only if FOGA adopts one later). |
| D14 manifest | `finchain-sepolia/2026.11-rc1` with status `candidate` at the M3 close; M4 items stay `not-run`. |
| D15 pace | M3-A and M3-B first, each on its own; M3-C after both hold. No duration is an acceptance promise. |

## 8. Order of work

| Step | Host | Output |
| --- | --- | --- |
| A-1 EVM acceptance | A (public RPC, deployer key) | `chain/out/evm-acceptance.json` |
| A-2 verification at finalized | B | `manifests/evidence/evm-acceptance-verify-<block>.json` |
| A-3 wallet transfer by hand | the owner's wallet | transaction hash in the evidence |
| B-1 isolation check, released 1.0.7 | E06 (anvil present) | `manifests/evidence/foga-isolation-1.0.7-<date>.json` |
| C-1 W and funding | E06 (`foga keys new --out`), A (`make l2-send`) | W address, funding transaction |
| C-2 World | E06, released FOGA, `--world chain/world/finchain-sepolia.world.json` | `chain/world/finchain-sepolia.json` with `completionBlock` |
| C-3 verification | E06 (`make world-manifest` with the package's bundle), B (`make verify-world` at `finalized`), E06 again (`make world-manifest` with B's report) | `manifests/covenant-world-finchain-sepolia.json` with `completionBlock` and `verifiedAt`, `manifests/evidence/world-verify-<block>.json` |
| C-4a genesis T0-T9 | E06, released 1.0.7, `--world chain/world/finchain-sepolia.json` | `manifests/evidence/foga-genesis-finchain-sepolia.json`, `manifests/evidence/foga-doctor-finchain-sepolia.json` (done 2026-11-13) |
| C-4b the OG on Finchain (D8) | E06, the checkout at v1.0.8, `foga join --world … --rpc …`, a second service at `og.finchain.one` | `manifests/evidence/og-finchain-2026-11-13.json` (done 2026-11-13) |
| C-4c the second cell and the business loop (D9, D10) | integration stage: host B's machine as an RPC user (`cell-b`, the registry's 1.0.9, the address book by URL), the OG as the demander (E06) | `manifests/evidence/business-loop-2026-11-13.json` (done 2026-11-13, integration stage; the acceptance stage - another operator - open) |
| C-5 funding lines and the loop at finalized | B (`make fee-lines`) | `manifests/evidence/fee-lines-20261113T151307Z.json` (done 2026-11-13: 292 receipts, the four lines with three fee components each, the seven loop receipts FINAL at 83370); the M3-C summary `manifests/evidence/m3c-2026-11-13.json` |
| Close | - | finchain 0.2.0, manifest `manifests/finchain-sepolia/2026.11-rc1.json` (status `candidate`, validated against `manifests/manifest.schema.json`; done 2026-11-13) |
