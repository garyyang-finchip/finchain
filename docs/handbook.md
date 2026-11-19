# Finchain handbook

How Finchain Sepolia was built, what it is for, and how to use it: as a wallet user, as a
contract developer, as a FOGA cell, or as the operator of a verifier node. The operator
procedure with expected outputs is in `docs/runbook.md`; this document is the reader's
entry point and links there where a step is operational. Every value below is read from the
chain or from the committed records in `chain/out/` and `manifests/`, not from intentions.

## 1. What Finchain is

Finchain is an EVM Layer 2 on the upstream OP Stack, settled on Ethereum. It exists for one
purpose: to be the reference chain for the twelve Finch covenant ERCs, and the preferred
reference deployment for FOGA (Finch OG Agent), which otherwise runs on any compatible EVM
chain. The reference implementation of each covenant lives here as a versioned, verifiable
deployment; other EVM chains can deploy, verify and adopt the same rules, and Finchain is
where each reference version is demonstrated first. Finchain is an ordinary chain first: a
wallet, a contract developer or a node operator uses it with no knowledge of FOGA or of the
covenants.

The twelve covenants:

| ERC | Title | Area |
| --- | --- | --- |
| 8338 | Token-Bound Executable Skills | assets (supply side) |
| 8414 | Token-Bound Task Tenders | assets (demand side) |
| 8419 | Know-Your-Agent (KYA) Framework | identity and credit |
| 8434 | Agent Identity (AID) | identity and credit |
| 8436 | Agent Collective Decision Framework | organisation and decision |
| 8444 | Agentic Resource Discovery (ARD) Onchain | discovery |
| 8447 | Swarm AI Framework | organisation and decision |
| 8454 | AIFi Unit Framework | value |
| 8468 | Agent Safety Framework | safety |
| 8471 | AI Dispute Resolution Framework | dispute |
| 8489 | Agent Information Flow Paradigm | information flow |
| 8490 | Agent Meditation Mechanism | self-maintenance |

The first public network is **Finchain Sepolia** (chain id 85422), settled on Ethereum
Sepolia, live since 2026-11-11. **Finchain mainnet** (chain id 8454, `docs/chain-id.md`) is a
separate deployment with its own genesis on Ethereum mainnet, running since 2026-11-18
(section 2b): configuration and contract versions validated on Sepolia are reused, state is
not. The mainnet is not yet announced as live: its second node, public RPC and the gates of
`docs/mainnet.md` section 4 come first; do not bridge value to it until then.

## 2. Chain facts

| Parameter | Value |
| --- | --- |
| Network name | Finchain Sepolia |
| Chain id | 85422 |
| Settlement layer | Ethereum Sepolia (chain id 11155111) |
| Public RPC | `https://rpc.finchain.one` (HTTPS), `wss://ws.finchain.one` (WebSocket) |
| Explorer | none yet (`explorer.finchain.one` reserved) |
| Native currency | ETH, bridged from Sepolia; nothing minted at genesis |
| Block time | 2 s |
| Block gas limit | 60,000,000 |
| Fee market | EIP-1559, elasticity 6, denominator 50, minimum base fee 0 |
| Data availability | L1 calldata (batch inbox `0x000b11cb4ba3722dd93aa484f2219d4a1aac3b00`) |
| Hardforks | Isthmus and Jovian active from genesis (Prague-level EVM) |
| L2 genesis hash | `0xcd6c17a0678d331d06ac2b8c8e820450bd5f2e3b91a1606289eca7b0fee631c5` |
| L1 anchor | Sepolia block 12112920, `0x10fc1193802668896d6aadc3db867c47ec3f3660ba53d940a649fb6a8aa0594b` (2026-11-11 16:31:12 UTC) |
| Rollup config sha256 | `530063a1f949afead2d96efb63cc99817656fe9c9f18d54c854699f1f59dccd9` |
| Sequencer window | 3600 L1 blocks (about 12 hours); channel timeout 300 L1 blocks |
| Active profile | `steady`: a batch about every 3 minutes, an output proposal every 6 hours (`demo`, with hourly proposals, ran from genesis until the first withdrawal proof; `docs/funding-model.md` section 5 says why) |
| Contracts release | op-contracts/v7.0.0, deployed with op-deployer v0.7.1 (`standard-overrides`) |
| Software | op-reth v2.4.2, op-node v1.19.11, op-batcher v1.17.2, op-proposer v1.16.7, op-challenger v1.9.6 (digests in `versions.lock`) |
| ERC-8004 identity root (on Finchain) | IdentityRegistry `0x363E71C6c33d4B5980B31B558D1E16B52EB3C8E9`, ReputationRegistry `0xF0A3ba008486cCc0bf994d5c06cE095E0b1D08e2`; upstream reference contracts, owned by the owner address (`chain/out/erc8004.json`, `docs/world.md`) |

L1 contracts on Sepolia (`chain/out/l1-addresses.json`):

| Contract | Address |
| --- | --- |
| OptimismPortal (deposits, withdrawals) | `0xeb8fbc0732fc7719838cf73d5377320a6c086b14` |
| L1StandardBridge | `0x4273ec08f893d66b1fbc525de946ca5666c27dc4` |
| L1CrossDomainMessenger | `0x178cc59729c1be9346f00a47b6f53fd7ff944e9c` |
| SystemConfig | `0xe99755f8447984d1cbc6a86e8ae0771c6ee15402` |
| DisputeGameFactory | `0xc752f10ab0696860b11b789a2ab9f4f93331329c` |
| AnchorStateRegistry | `0x31ffb1c4a5d40c7c39a122320db733389eb9c1fb` |
| PermissionedDisputeGame implementation | `0xe1dffcbe4e22b813f26d2106d943c102e7cab87e` |
| DelayedWETH (permissioned game) | `0x3c40a4e728246f4c0456760f435be6f9788604b6` |
| SuperchainConfig (shared, Sepolia) | `0xc2be75506d5724086deb7245bd260cc9753911be` |

Proof configuration as read from L1 (`manifests/onchain-12112920.json`, later snapshots in
`manifests/`): respected game type 1 (permissioned), max game depth 73, split depth 30,
clock extension 3 h, max clock duration 3.5 days, DelayedWETH delay 3.5 days, proof maturity
delay 7 days, dispute game finality delay 3.5 days. The initial bond was lowered from
0.08 ETH to 0 by the owner on 2026-11-11 (testnet cost control, `docs/funding-model.md`).

### 2b. Finchain mainnet (chain id 8454)

Deployed on 2026-11-18 (`docs/mainnet.md`); both nodes and the public RPC up since 2026-11-19
(`manifests/evidence/mainnet-start-2026-11-19.json`); not yet called live (a mainnet withdrawal
cycle and the Finchain prestate as game type 8 come first; the Safe follows at a later milestone
by the owner's ruling). Facts from `chain/mainnet/out/`:

| Parameter | Value |
| --- | --- |
| Network name | Finchain |
| Chain id | 8454 |
| Settlement layer | Ethereum mainnet (chain id 1) |
| Public RPC | `https://rpc.mainnet.finchain.one` (HTTPS) and `wss://ws.mainnet.finchain.one` (WebSocket), served by host B since 2026-11-19 |
| Native currency | ETH, bridged from Ethereum; nothing minted at genesis |
| Block time, gas limit, fee market, hardforks | as Sepolia: 2 s, 60,000,000, EIP-1559 (elasticity 6, denominator 50, minimum base fee 0), Isthmus and Jovian from genesis |
| Data availability | L1 calldata (batch inbox `0x00b9e9fa990d849b5cc7296e5728a78b7c0c71a2`) |
| L2 genesis hash | `0xd678465005d9ba96c23dd4ff112630e5fdfac42d540d4967b77d581bc708497d` |
| L1 anchor | mainnet block 26443400, `0x0580a495ceb198f880da6baed65ad87ae98eb88faf70b94e8332b00393c32ec5` (2026-11-18 17:19:35 UTC) |
| Rollup config sha256 | `f0021191defc7d7a28a26e653a816b3d6f32d3443f7f4f4912d5a91b4097de0d` |
| Sequencer window, channel timeout | 3600 L1 blocks, 300 L1 blocks |
| Active profile | `mainnet`: a batch about every 3 minutes, an output proposal every 24 hours |
| Contracts release, software | op-contracts/v7.0.0 with op-deployer v0.7.1 (`standard-overrides`, OPCM `0x9ce712ff84e02659846dc6450bb9b7642fe8be5d`); the same `versions.lock` as Sepolia |
| Deployment | one transaction `0x7d8fa9b46355958ce4d663f7eef6c7f6cb4457db14acc590b8e0b64bb3a611c5`, 0.012082 ETH (`chain/mainnet/out/deployment.json`) |

L1 contracts on Ethereum mainnet (`chain/mainnet/out/l1-addresses.json`):

| Contract | Address |
| --- | --- |
| OptimismPortal (deposits, withdrawals) | `0x54ee6b884b1f7b0ef2ae3bb4805ab3dc6667aabb` |
| L1StandardBridge | `0x1d51684ff5840b1613bd6ac5a6bd5839654071b7` |
| L1CrossDomainMessenger | `0xa29d68e7a5073e7fa9bd7c7882158f686ffce645` |
| SystemConfig | `0xf0961551c451a6c9b7037223f50b213e012d195f` |
| DisputeGameFactory | `0x4aa400aa71f9658dc010dcc9cd7229bd4467536e` |
| AnchorStateRegistry | `0x97e63e52da892c8ae335c2af75ce56a3c03ebf01` |
| PermissionedDisputeGame implementation | `0xe1dffcbe4e22b813f26d2106d943c102e7cab87e` |
| DelayedWETH (permissioned game) | `0x2922fc246c5d5a69576ffdfe5688937b655b8019` |
| SuperchainConfig (shared, mainnet) | `0x95703e0982140d16f8eba6d158fccede42f04a4c` |

Proof configuration as read from L1 (`manifests/onchain-mainnet-26443627.json`): respected
game type 1 (permissioned), initial bond 0.08 ETH, proof maturity delay 7 days, dispute game
finality delay 3.5 days, prestate op-deployer's default (`0x038512e0...d54c`) until the
Finchain-embedding prestate is installed (`docs/mainnet.md` decision 6). Roles: owner
`0xF8D8846e505E5478C60B57182D39f61b066cA8E2` (the same account as on Sepolia), unsafe block
signer `0x4Ba4...E38D`, batcher `0xaEBc...7968`, proposer `0x7c2b...5bbB`, challenger
`0xc666...2Dc7`.

## 3. Using the chain

### 3.1 Add the network to a wallet

| Field | Value |
| --- | --- |
| Network name | Finchain Sepolia |
| RPC URL | `https://rpc.finchain.one` |
| Chain ID | 85422 |
| Currency symbol | ETH |
| Block explorer | leave empty |

The chain is not yet listed in `ethereum-lists/chains` (the draft entry is
`registry/eip155-85422.json`), so wallets show their usual warning for a network they do not
recognise. That is expected until the entry is submitted after public opening.

### 3.2 Get ETH on Finchain

Nothing was minted at genesis; every balance enters through a deposit from Sepolia.

1. Hold Sepolia ETH in an externally owned account (any Sepolia faucet; the Superchain
   faucet gives 0.05 ETH per claim).
2. Send it to the OptimismPortal `0xeb8fbc0732fc7719838cf73d5377320a6c086b14` on Sepolia.
   A plain transfer is enough: the portal's `receive()` records a deposit to the sender's
   own address.
3. The same address holds the ETH on Finchain once the deposit is derived, normally within a
   few minutes (the sequencer waits for a few L1 confirmations).

Send from an externally owned account only: a deposit sent from a contract wallet is
credited to an aliased address, not to the sender. Operators use `make deposit AMOUNT=...`
with a repository key; the two first deposits (2026-11-12) are recorded in
`manifests/evidence/m2-2026-11-12.json`.

### 3.3 Read the chain: confirmation levels

Finchain blocks pass through three levels, exposed as the `latest`, `safe` and `finalized`
block tags of the JSON-RPC:

| Level | Meaning | Typical delay (steady and demo profiles) | Use it for |
| --- | --- | --- | --- |
| `latest` (unsafe) | executed by the sequencer; data not yet on Sepolia | 2 s | progress display, preparation of retryable work |
| `safe` | batch data included on Sepolia; a verifier rebuilds the block from L1 alone | a few minutes | messages between parties, provisional ledger entries |
| `finalized` | the Sepolia blocks carrying the data are finalized | about 20 minutes | irreversible actions outside the chain |

A block that is `safe` can still disappear if Sepolia reorganises below the batch; a block
that is `finalized` cannot. `docs/foga-confirmation-policy.md` turns this into rules for
FOGA cells; `make status-a` / `make status-b` print the three heads of a host.

### 3.4 Deploy and call contracts

Finchain is a standard EVM. Any Ethereum toolchain works with the RPC URL and chain id:

```bash
# Foundry
forge create src/Counter.sol:Counter --rpc-url https://rpc.finchain.one --private-key $PK
cast call <address> "number()(uint256)" --rpc-url https://rpc.finchain.one
```

```js
// Hardhat / viem / ethers network entry
{ chainId: 85422, url: "https://rpc.finchain.one" }
```

Fees: a transaction pays the L2 execution fee (base fee plus the priority fee you set; the
base fee is near zero on a quiet chain) and a small L1 data fee for posting its calldata to
Sepolia. `eth_estimateGas` covers execution only, so keep a small ETH margin beyond
gas x price. Solidity targets up to `prague` execute. Contract size is bounded by EIP-170
(24,576 bytes) as on Ethereum. Transactions submitted to `rpc.finchain.one` are forwarded
to the sequencer; the public endpoint is served by the verification host and is read-only
in the sense that it never produces blocks itself.

### 3.5 Withdraw to Sepolia

Withdrawals follow the standard OP Stack fault-proof path: initiate on Finchain, prove the
withdrawal against an output proposal (a dispute game of the respected type; proposals are
created every 6 hours under the `steady` profile, hourly under `demo`), wait for the proof
maturity delay (7 days) and for
the game to resolve and pass its finality delay (3.5 days each), then finalize on Sepolia.
The full deposit -> proof -> withdrawal cycle, with the actual waiting times, is an M4
acceptance item (`docs/acceptance.md`) and is recorded there when done. Treat Finchain
Sepolia ETH as test ETH that takes about a week to leave.

The repository drives the whole path from a key it holds (`scripts/withdraw.sh`, `make
withdraw`): `initiate` sends `L2ToL1MessagePasser.initiateWithdrawal` and records the
withdrawal and its hash (recomputed from the event's fields); `status` finds the earliest
game of the respected type whose L2 block covers it and reports both clocks; `prove` builds
the output root proof from the public L2 RPC alone (the block's state root and hash, the
message passer's storage root and the `eth_getProof` of `sentMessages[hash]` at the game's
block), checks that it hashes to the game's root claim, and sends
`OptimismPortal2.proveWithdrawalTransaction`; `finalize` asks the portal's `checkWithdrawal`
and then sends `finalizeWithdrawalTransaction`. Every step appends to one record under
`manifests/evidence/withdrawal-<date>.json`, which ends with the timeline (initiated, game
created, proven, game resolved, finalized) in hours. A wallet user without the repository
follows the same four steps with any OP Stack bridge tool that takes a custom chain; the
node serving `eth_getProof` for a past block must allow it (`--rpc.eth-proof-window` on
op-reth, set on host B).

### 3.6 FOGA on Finchain

FOGA (`https://github.com/garyyang-finchip/foga`, npm `@finchip.ai/foga`) deploys the
twelve covenant reference implementations as a "world" on a chain of the user's choice and
runs agent cells against it. FOGA is a separate product with its own release line: it runs
with no Finchain in the picture (its default chain is Ethereum Sepolia, and its local
quickstart needs no public chain at all), and nothing in it reaches for Finchain unless a
world file names a Finchain address. Finchain, in turn, is complete without FOGA.

"FOGA on Finchain" is therefore a deployment the user chooses explicitly, with the released
FOGA package as it is: `foga world deploy --world chain/world/finchain-sepolia.world.json
--rpc https://rpc.finchain.one` deploys the World (that configuration file lives in this
repository, not in FOGA's package), the address book FOGA writes is copied to
`chain/world/finchain-sepolia.json`, and a cell joins with `foga join --world <that address
book> --rpc https://rpc.finchain.one`. The World binds to the ERC-8004 identity root
deployed on Finchain (section 2, `chain/out/erc8004.json`). The confirmation policy above is
a specification handed to FOGA; until FOGA implements it, an operator who needs `safe` or
`finalized` before an irreversible step waits by procedure. Design, roles and verification
rules are in `docs/world.md`; the three M3 acceptances (Finchain on its own, FOGA on its own,
FOGA on Finchain) are in `docs/acceptance.md`.

## 4. Running a verifier node

Anyone can run a verifier: a node that derives Finchain from Sepolia data on its own
database, follows the sequencer's blocks over p2p, and lets its operator check the chain
without trusting either operator host. Host B of the project is exactly such a node plus
the resident challenger and the public RPC. Verifier nodes 3, 4, 5 follow the same files.

### 4.1 Requirements

- Linux host with Docker Engine and Compose v2; 2 vCPU and 4 GiB RAM run the pair today
  (host B is a 2 vCPU / 4 GiB instance), 8 GiB is comfortable; 150 GB of SSD (the archive
  database grows with chain usage).
- A Sepolia execution RPC and a Sepolia beacon API of your own. Public gateways rate-limit
  (429s were seen on host B during its first sync); a provider account is the reliable
  choice. With `L1_TRUST_RPC=true` (the default) the provider does not need `eth_getProof`
  at the head; `false` is the stronger setting when the provider supports it
  (`docs/networking.md`).
- Inbound 9222 TCP/UDP open if other nodes should be able to dial you; outbound only is
  enough to follow the chain.

### 4.2 Procedure

```bash
git clone https://github.com/garyyang-finchip/finchain.git && cd finchain
make init-env
# .env: keep CHAIN_ID=85422; set L1_RPC_URL / L1_BEACON_URL to your provider;
#       set OWNER_ADDRESS to any address (the chain's owner address, say) so that
#       `make keys` generates no owner key for you
# node-b/.env: your L1 endpoints; B_BIND_IP = the IP your tools reach the node on
#              (127.0.0.1 for a single machine); P2P_ADVERTISE_IP = your public IP;
#              SEQUENCER_HTTP=https://rpc.finchain.one ; P2P_STATIC_PEERS = the bootnode below
make preflight-b
make keys && make secrets-b          # local JWT and p2p key for your own node; the role keys
                                     # it also writes hold no funds and no role on Finchain
docker compose -f node-b/docker-compose.yml --env-file versions.lock \
  --env-file profiles/steady.env --env-file node-b/.env up -d op-reth op-node
make status-b
```

Bootnode (host B, public): `/ip4/3.147.206.136/tcp/9222/p2p/16Uiu2HAm1kYdkTTeVHighSCUcwu8NAkkLeibTymZRvYenG4Pxn4G`.
Host A is reachable only over the operators' private network and is not a public peer.

Starting only `op-reth` and `op-node` leaves out the challenger (its key is held by the
project; a third-party challenger has no role in the permissioned game) and Caddy (needed
only to serve a public endpoint of your own). `make up-b` starts all four services and is
what host B runs. A dedicated verifier target is part of the node-onboarding work after M2.

### 4.3 What to expect and how to check

- First sync derives every block from Sepolia data: host B rebuilt about 7,200 blocks in
  8 minutes and caught up with the head in about 25 minutes at a chain length of 20,000
  blocks; the time grows with chain history. During the catch-up `safe` equals `unsafe`.
- Once caught up, the unsafe head follows the sequencer's p2p gossip (blocks signed by the
  unsafe block signer registered in SystemConfig); `safe` and `finalized` advance with
  Sepolia.
- Compare your node with the public endpoint at a finalized height:
  `make compare RPC_A=https://rpc.finchain.one RPC_B=http://127.0.0.1:8545 AT=finalized`
  (the `NODE_*` arguments are optional and print sync status when the op-node RPCs are
  reachable). A `MATCH` of block hash and state root is the result that matters.
- The strongest check is `make rebuild-b TARGET=<finalized height> REF=https://rpc.finchain.one`:
  empty volumes, no peers, derivation from the public genesis, rollup configuration and
  Sepolia data only, compared with the reference at the end. Host B's record of this run is
  `manifests/evidence/rebuild-from-l1-20261112T044816Z.json` (MATCH at height 19836).

## 5. How Finchain was built

### 5.1 Architecture

| Component | Where | Role |
| --- | --- | --- |
| op-reth (archive) + op-node (sequencer) | host A, an always-on Apple Silicon machine (OrbStack) | produces blocks every 2 s, signs unsafe block gossip |
| op-batcher | host A | writes batch data to Sepolia as calldata (`demo`: about every 3 minutes) |
| op-proposer | host A | creates a PermissionedDisputeGame (output proposal) every hour |
| op-reth + op-node (verifier) | host B, AWS EC2 in Ohio | derives the chain from Sepolia on its own database and provider; follows A over p2p |
| op-challenger (`--trace-type=permissioned`) | host B | resolves games and would counter an invalid proposal |
| Caddy | host B | TLS termination for `rpc.finchain.one` and `ws.finchain.one`; forwards transactions to the sequencer |
| Ethereum Sepolia | external | settlement, data availability, finality; each host reads L1 through its own provider |

A and B are not a two-node committee. A produces and submits; B re-derives Finchain from L1
data and challenges invalid proposals. Finality comes from Ethereum. The hosts talk over a
private network (Tailscale); no inbound port is opened on host A.

### 5.2 Decisions

The decisions fixed in the two design rounds are in `docs/execution-brief.md`. In short:
upstream OP Stack release artifacts with no code fork; Sepolia first, mainnet later;
`standard-overrides` deployment (shared Sepolia SuperchainConfig, all seven chain roles held
by Finchain); ETH as gas asset; calldata DA; nothing minted at genesis; the covenant World
deployed by transactions after chain start; chain id 85422 for the testnet and 8454 for
mainnet; hot keys generated on the host that uses them and never committed; owner roles on an
externally held address.

### 5.3 The deployment under Glamsterdam rules

Sepolia activated Glamsterdam on 2026-10-06. EIP-8037 reprices every state-creating
operation (a `CREATE2` costs 183,600 gas instead of 32,000; code deposit 1,530 gas per
byte), so deploying one OP Stack chain through the OP Contracts Manager needs about 56M gas
instead of 9M, and op-deployer v0.7.1's own broadcaster, which simulates with Cancun-era
rules, refused to send. The deployment therefore ran in a calldata mode kept in this
repository (`scripts/deploy-l1-calldata.sh`): op-deployer produced the calldata and the
predicted addresses, the gas limit came from the live node's estimate, a dry run at that
limit had to succeed, and `cast` sent the transaction.

Result: one transaction, `0xed7911150ab7e85087f7cb1d0892dba1b8b7e0fa542dfa0ff1a7ebd14261fb1b`,
Sepolia block 12112920, 55,227,867 gas used, 0.110456 ETH. The same fork changed the L1
block header and the calldata floor cost, which moved op-node, op-batcher, op-proposer and
op-challenger to the patch levels in `versions.lock`. The whole account is in
`docs/versions.md`.

### 5.4 Milestones

| Milestone | Status | Evidence |
| --- | --- | --- |
| M1 chain is up: genesis published, 2 s blocks, batches on L1, first output proposal of the respected type | done 2026-11-12 | `manifests/evidence/m1-2026-11-12.json` |
| M2 independently verifiable: host B matches host A at `finalized` (height 19836), deposits credited, rebuild from L1 only (MATCH), public RPC over TLS, versions frozen | done 2026-11-12 | `manifests/evidence/m2-2026-11-12.json`, `manifests/evidence/rebuild-from-l1-20261112T044816Z.json` |
| M3-A Finchain on its own: plain transfer, ordinary contract deployed, written and read through the public RPC (blocks 37178-37183), verified by host B at `finalized` (MATCH at 37854), a MetaMask transfer by hand (block 39776); ERC-8004 identity root deployed and owned | done 2026-11-12 | `manifests/evidence/m3a-2026-11-12.json`, `chain/out/evm-acceptance.json`, `manifests/evidence/evm-acceptance-verify-37854.json`, `chain/out/erc8004.json` |
| M3-B FOGA on its own: the released package run from the registry with `finchain.one` refused: help, chain table (default Sepolia), local quickstart, local genesis T0-T9, Sepolia World read; every leg passing, zero under `finchain.one` - 1.0.7 (63 connections) as the baseline, 1.0.8 (50 connections) as the version the OG on Finchain was born with, 1.0.9 (50 connections) as the version both OG services and the business loop's cells run | done 2026-11-12 (1.0.7), 2026-11-13 (1.0.8, 1.0.9) | `manifests/evidence/m3b-2026-11-12.json`, `manifests/evidence/foga-isolation-1.0.7-20261112T151124Z.json`, `manifests/evidence/foga-isolation-1.0.8-20261113T073041Z.json`, `manifests/evidence/foga-isolation-1.0.9-20261113T141222Z.json` |
| M3-C FOGA on Finchain (optional, explicit): twelve reference implementations deployed by the released FOGA 1.0.7 from this repository's world configuration (reference World `finchain-sepolia-85422-20261113T023727Z`, completion block 61548), address book verified by host B at `finalized` (59 contracts MATCH at 61794), genesis T0-T9 on Finchain with both ZK paths (197 of 197 checks, cells as agents 3, 4 and 5), doctor all twelve covenants Pass, the OG living on Finchain as its own cell (born on 1.0.8, serving on 1.0.9 since the same day, account `0x9F76...7aD1`, agent 6, `https://og.finchain.one`) beside the unchanged Sepolia OG; the two-cell business loop at its integration stage (the OG minting tender 5, `cell-b` - joined from the registry's 1.0.9 by this repository's address book at its URL, account `0x2Dd0...15BB`, agent 7 - finding it, running the skill, submitting, accepted by the hashlock verifier, settled and paid; six transactions); the four funding lines read from 292 receipts with three fee components each and the loop's receipts FINAL at 83370 (`make fee-lines`); the run by another operator open | C-1 to C-5 done 2026-11-13 (C-4c at the integration stage); the other operator open | `manifests/evidence/m3c-2026-11-13.json`, `chain/world/finchain-sepolia.json`, `manifests/covenant-world-finchain-sepolia.json`, `manifests/evidence/world-verify-61794.json`, `manifests/evidence/foga-genesis-finchain-sepolia.json`, `manifests/evidence/foga-doctor-finchain-sepolia.json`, `manifests/evidence/og-finchain-2026-11-13.json`, `manifests/evidence/business-loop-2026-11-13.json`, `manifests/evidence/fee-lines-20261113T151307Z.json` |
| M3 close: the reference-version manifest `finchain-sepolia/2026.11-rc1` (status `candidate`: chain, software digests, roles and shared authority, the covenant World with its 55 contracts and both blocks, the FOGA versions, the acceptance list) and finchain 0.2.0 | done 2026-11-13 | `manifests/finchain-sepolia/2026.11-rc1.json` |
| M4 proofs and assets: resident challenger exercised (2026-11-15), the kona-client prestate with Finchain embedded (K2, 2026-11-16), full VM dispute drill on an isolated devnet (K3, 2026-11-16 and -17), a Type 8 game type installed on Sepolia and one game tracked by host B's `cannon-kona` challenger (K4, 2026-11-19), deposit -> proof -> withdrawal end to end (finalize due 2026-11-21) | K1-K4 done; the withdrawal's finalize on 2026-11-21 closes M4 | `docs/proof-plan.md`, `docs/acceptance.md` |
| M5 mainnet: L1 contracts deployed 2026-11-18, host A sequencing since, host B verifying and the public RPC up since 2026-11-19; the Safe, a mainnet withdrawal cycle, the providers and the Finchain prestate follow (`docs/mainnet.md`) | running on both nodes, not announced | `docs/mainnet.md`, `chain/mainnet/`, `manifests/onchain-mainnet-26443627.json`, `manifests/evidence/mainnet-start-2026-11-19.json` |

### 5.5 Funding

Four separate needs are budgeted and reported separately: the L1 deployment (one-off,
0.11 ETH as measured), daily operations (batcher about 480 transactions per day under
`steady` and `demo`, proposer 4 games per day under `steady` and 24 under `demo`, challenger a
few transactions per game), bonds (initial
bond set to 0 on the testnet; the full dispute path is not budgeted on public Sepolia), and
ETH deposited into L2. `make funding-table PROFILE=steady` prints the live table;
`docs/funding-model.md` explains the lines.

## 6. Governance, keys and trust

| Role | Holder | Scope |
| --- | --- | --- |
| l1ProxyAdminOwner, l2ProxyAdminOwner, systemConfigOwner | owner address `0xF8D8846e505E5478C60B57182D39f61b066cA8E2` (external wallet, no key on any host) | upgrades, SystemConfig parameters, DisputeGameFactory owner (`setInitBond`, `setImplementation`) |
| unsafeBlockSigner, batcher, proposer | host A hot keys | block gossip signature, batch submission, output proposals |
| challenger | host B hot key | permissioned game challenger, game resolution |
| Fee vault recipient | owner address | base fee, L1 fee, sequencer fee and operator fee vaults |
| Guardian, shared proxy admin | Sepolia SuperchainConfig (`0xc2be...11be`), guardian `0x7a50f00e8D05b95F98fE38d8BeE366a7324dCf7E` | pause of bridges and portals of attached chains, shared implementations; not Finchain roles |

What this means for a user today: Finchain Sepolia runs with a single sequencer and
permissioned fault proofs. The sequencer can stop producing blocks (host B then keeps serving
the last derived state); only the authorised proposer and challenger take part in disputes;
and the shared Sepolia guardian can pause the bridge. The chain's history is nevertheless
independently verifiable from Sepolia data alone, which is what M2 demonstrated. Mainnet
readiness (M5) replaces the single owner address with a Safe, adds sequencer HA and moves to
permissionless proofs. `docs/governance.md` has the full record.

## 7. Operations quick reference

Commands run from the repository root; `make help` lists every target. Host-specific
targets end in `-a` or `-b`.

| Purpose | Command |
| --- | --- |
| Preflight (host, Docker, image architecture, flags, L1) | `make preflight-a` / `make preflight-b` |
| Start, recreate, stop a host | `make up-a` (profile `steady`; `PROFILE=demo` or `lowcost` to switch), `make restart-a`, `make down-a` (same with `-b`) |
| One-screen status: containers, three heads, L1 heads, balances | `make status-a` / `make status-b` |
| Logs of one service | `make logs-a SVC=op-batcher` |
| Peers | `make peers-a` / `make peers-b` |
| Compare two nodes at a height | `make compare RPC_A=... RPC_B=... AT=finalized` |
| Rebuild host B from L1 only | `make rebuild-b TARGET=<height> REF=<reference RPC>` |
| Deposit from a repository key | `make deposit AMOUNT=0.5 ROLE=deployer L2_RPC=...` |
| On-chain configuration snapshot | `make verify-onchain` |
| Fund hot roles from the deployer key | `make fund-roles ROLES="batcher=0.3 proposer=0.2"` |
| Lower or raise the initial bond (owner) | `make set-init-bond TYPE=1 BOND=0` (or the owner console page) |
| K4 readiness, the Type 8 installation, one Type 8 game | `make k4-readiness`; the owner console ("Install a game type"); `make k4-create-game` on host A; `make games EXTRA_TYPES=8` (`docs/proof-plan.md`, "K4") |
| Freeze image digests | `make lock` |
| Funding table for a profile | `make funding-table PROFILE=steady` |
| A second chain on the same hosts | `CHAIN=<name>` on every target: own artifacts, env files, keys, projects, ports (`docs/runbook.md` section 9) |

The owner console (`owner-console.html`, served from the repository's GitHub Pages) lets
the owner wallet read the DisputeGameFactory and send `setInitBond` and `setImplementation` (a
game type's implementation and packed arguments, M4 K4) without a command line.

## 8. Links

| | |
| --- | --- |
| Repository | `https://github.com/garyyang-finchip/finchain` |
| Public RPC | `https://rpc.finchain.one`, `wss://ws.finchain.one` |
| Chain records | `chain/out/chain-record.json`, `chain/out/genesis.json`, `chain/out/rollup.json`, `chain/out/l1-addresses.json` |
| Acceptance and evidence | `docs/acceptance.md`, `manifests/evidence/` |
| FOGA | `https://github.com/garyyang-finchip/foga`, `https://foga.finchip.ai` |
| Covenant repositories | `skill-token-standard`, `task-token-standard`, `kya-standard`, `aid-standard`, `acd-framework`, `ard-onchain-framework`, `swarm-ai-framework`, `aifi-unit-framework`, `agent-safety-framework`, `ai-dispute-resolution`, `aif-paradigm`, `agent-meditation-mechanism` under `https://github.com/garyyang-finchip` |
| OP Stack documentation | `https://docs.optimism.io` |
