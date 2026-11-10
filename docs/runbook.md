# Runbook: Finchain Sepolia, milestones M1 and M2

Commands run from the repository root. `make help` lists every target. Scripts are invoked through `bash`, so they work even when the execute bit was lost (for example after an upload through the GitHub web UI). Host A is the
sequencing host (macOS or Linux, Docker with Compose v2); host B is the AWS EC2
verification host (Linux, Docker with Compose v2). Steps marked **A** or **B** run on that
host; unmarked steps run on host A.

## 0. Prerequisites

- Docker with Compose v2 on both hosts. On macOS use Docker Desktop or OrbStack; keep the
  machine awake (`sudo pmset -a sleep 0 disablesleep 1`) and on a wired connection.
- Private network between A and B (Tailscale or WireGuard). Note A's and B's private IPs.
- Two L1 providers (one per host) with Sepolia execution RPC; one beacon API.
- DNS for `rpc.finchain.one` and `ws.finchain.one` pointing at host B's public IP; ports
  80/443 open on B; 9222 TCP/UDP open on B.
- Sepolia ETH plan from `docs/funding-model.md`.

## 1. Environment and preflight

```bash
git clone <repository> finchain && cd finchain
make init-env
# edit .env (CHAIN_ID, OWNER_ADDRESS, TREASURY_ADDRESS, L1 endpoints),
# node-a/.env (A_BIND_IP, P2P_ADVERTISE_IP = A's private IP, L1 endpoints),
# node-b/.env (B_BIND_IP, P2P_ADVERTISE_IP = B's public IP, SEQUENCER_HTTP = http://<A private IP>:8545, hostnames)
make preflight-a          # A
make preflight-b          # B (after copying the repository and node-b/.env there)
make chain-id-check
```

Preflight must pass on both hosts before anything is deployed. A failing image
architecture check on host A means the pinned image has no build for that CPU; see
`docs/networking.md` for the fallback (native binary or emulation) and record the choice.

## 2. Keys and secrets (A)

```bash
make op-deployer
make keys                 # keys/*.json, keys/addresses.env (addresses printed)
make secrets-a            # node-a/secrets/
make bundle-b             # keys/node-b-bundle.tar
scp keys/node-b-bundle.tar <host-b>:finchain/keys/   # over the private network
rm keys/node-b-bundle.tar
```

On **B**: `make install-bundle-b && rm keys/node-b-bundle.tar`.

Fund the hot roles on Sepolia per the funding table: deployer (deployment), batcher and
proposer (daily operations and initial bonds), challenger (resolution transactions).

## 3. Intent and funding table

```bash
make intent               # op-deployer init + overrides; review the printed roles
make funding-table PROFILE=demo
make funding-table PROFILE=lowcost
```

Check in `chain/deployer/intent.toml`: `fundDevAccounts = false`, the seven roles, the four
vault recipients, `opcmAddress`, and that the contracts locator matches `versions.lock`.
Optional testnet overrides (shorter dispute clock, shorter WETH delay) go through
`DEPLOY_OVERRIDES_JSON` only after the key names have been confirmed for the op-deployer
release (`docs/versions.md`).

## 4. L1 deployment and artifacts

```bash
make deploy-l1            # confirms, then op-deployer apply; writes chain/out/deployment.json
make export               # genesis.json, rollup.json, l1-addresses.json, chain-record.json
make verify-onchain       # manifests/onchain-<block>.json at the latest finalized L1 block
```

From the snapshot: set `PROPOSER_GAME_TYPE` in `node-a/.env` to the respected game type;
confirm `DISPUTE_GAME_FACTORY` was filled into both host env files (copy `chain/out/` and
`node-b/.env` to host B). Record `deployerSpentEth` from `chain/out/deployment.json` as the
measured deployment cost and replace `EST_DEPLOY_GAS` accordingly.

If the initial bond is to be lowered for the testnet:
`make set-init-bond TYPE=<respected type> BOND=0` (sent by the owner address).

Commit `chain/deployer/intent.toml`, `chain/deployer/state.json`, `chain/out/*` and the
snapshot. Never commit anything from `keys/` or `node-*/secrets/`.

## 5. Host A up (M1)

```bash
make up-a PROFILE=demo
make logs-a SVC=op-node
make status-a
```

Expected within minutes: op-reth initialises from `genesis.json`; op-node reports the L1
anchor and starts sequencing (unsafe head advancing every 2 s); op-batcher submits the
first calldata transaction after the channel duration; op-proposer creates the first game
once the first L2 output is finalized relative to L1 (allow the L1 finality delay, around
15-20 minutes, plus the proposal interval).

M1 evidence (record paths in the manifest): `chain/out/chain-record.json`, first batcher
transaction hash, first game address and type (`make verify-onchain` shows `gameCount`),
`versions.lock` as used.

## 6. Host B up and p2p link (M2)

On **B**:

```bash
make up-b PROFILE=demo
make logs-b SVC=op-node
make peers-b              # prints B's peer id and multiaddr
```

On **A**: put B's multiaddr (with B's private IP) into `P2P_STATIC_PEERS` in `node-a/.env`,
then `make restart-a` and `make peers-a`. On **B**: put A's multiaddr into `node-b/.env`,
`make restart-b`. `make status-b` should show one connected peer and the unsafe head
following A within a block or two. Without the p2p link B still derives the chain from L1
(unsafe head lags by the batch interval); the link only shortens latency.

Checks:

```bash
make compare RPC_A=http://<A private IP>:8545 RPC_B=http://<B private IP>:8545 AT=finalized \
             NODE_A=http://<A private IP>:8547 NODE_B=http://<B private IP>:8547
make deposit AMOUNT=0.2 ROLE=deployer L2_RPC=http://<B private IP>:8545
```

Public RPC: `curl -X POST https://rpc.finchain.one -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'` returns the chain id.

Rebuild from L1 only (acceptance, run on **B** once a few hundred blocks are finalized):

```bash
make rebuild-b TARGET=<finalized height> REF=http://<A private IP>:8545
```

The record lands in `manifests/evidence/`. The reference endpoint is used for the final
comparison only.

## 7. Switching profiles

`make up-a PROFILE=lowcost` / `make up-b PROFILE=lowcost` recreates the containers with the
new batcher and proposer parameters; data is kept. State the active profile and its
expected `safe` delay in the public documentation and in acceptance records.

## 8. Operations notes

- Logs: `make logs-a SVC=op-batcher` etc. Containers restart automatically; data lives in
  named volumes `finchain-a_*` / `finchain-b_*`.
- Upgrades: change `versions.lock`, run `make preflight-*` and `scripts/check-flags.sh`,
  then `make restart-*`. Record the new digests with `make lock`.
- Stopping the sequencer stops block production; B keeps serving the last derived state.
  op-conductor HA is out of scope for v0.1.
- Balances: `make status-a` prints the hot-role balances; top up before they reach the
  daily consumption shown by the funding table.
