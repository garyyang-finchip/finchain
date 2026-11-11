# Networking and hosts

## Hosts

| | Host A (sequencing) | Host B (verification) |
| --- | --- | --- |
| Machine | always-on operator machine (macOS, Apple Silicon expected) | AWS EC2, own instance for Finchain, 2 vCPU / 8 GiB minimum for M1-M3; scale to 8 vCPU / 32 GiB / 500 GB before dispute drills |
| Runtime | Docker Desktop or OrbStack, Compose v2 | Docker Engine, Compose v2 |
| Public exposure | none | 80/443 (Caddy), 9222 TCP/UDP (p2p), SSH restricted |
| Data | named Docker volumes (`finchain-a_*`); exclude from Time Machine | named volumes (`finchain-b_*`) on a gp3 volume |
| L1 provider | provider 1 | provider 2 (different from A) |

Host A sits behind a home router. No inbound port forwarding is required: B is dialled by A
over the private network, and transactions received on B are forwarded to A's execution
client over the same network.

## L1 providers and `L1_TRUST_RPC`

op-node verifies what the L1 provider returns unless `--l1.trustrpc` is set: header hashes,
transaction and receipt roots, and the SystemConfig storage it reads at start-up through
`eth_getProof`. Public endpoints do not all support that: the Tenderly gateway answers
`eth_getProof` at the head with "distance to target block exceeds maximum proof window",
which stops op-node after five attempts ("failed to fetch unsafe block signing address").
`L1_TRUST_RPC=true` (the default in the env examples, and what the OP Stack tutorial sets)
switches op-node to `eth_getStorageAt` and skips the root checks. The data source is then
trusted; the derivation itself is still re-executed locally. For host B as an independent
verifier, the stronger setting is `L1_TRUST_RPC=false` with a provider account that serves
`eth_getProof` at the head; record the setting in the manifest either way.

## Private network between A and B

Use Tailscale (or WireGuard) on both hosts. In the env files:

- `node-a/.env`: `A_BIND_IP` = A's private IP (private RPC ports bind there),
  `P2P_ADVERTISE_IP` = A's private IP, `P2P_STATIC_PEERS` = B's multiaddr using B's
  private IP.
- `node-b/.env`: `B_BIND_IP` = B's private IP, `P2P_ADVERTISE_IP` = B's public IP,
  `P2P_STATIC_PEERS` = A's multiaddr using A's private IP,
  `SEQUENCER_HTTP = http://<A private IP>:8545`.

Checks: `make peers-a` / `make peers-b` show one connected peer; `make status-b` shows
the unsafe head following A.

## Ports

| Port | Service | A | B |
| --- | --- | --- | --- |
| 8545/8546 | op-reth HTTP/WS | private IP only | private IP only; public access via Caddy |
| 8551 | Engine API | container network only | container network only |
| 8547 | op-node RPC (admin, unauthenticated) | private IP only | private IP only |
| 9222 | op-node p2p TCP/UDP | all interfaces (reachable over the private network) | public |
| 8548 / 8560 | batcher / proposer admin RPC | private IP only | - |
| 80 / 443 | Caddy | - | public |
| 7300 / 9001 | metrics | private IP only | private IP only |

Docker-published ports bypass host firewalls such as ufw; the compose files therefore bind
private services to `${A_BIND_IP}` / `${B_BIND_IP}` instead of relying on a firewall.

## DNS (finchain.one)

| Record | Target | Purpose |
| --- | --- | --- |
| `rpc.finchain.one` A | host B public IP | HTTPS JSON-RPC |
| `ws.finchain.one` A | host B public IP | WSS JSON-RPC |
| `explorer.finchain.one` A | host B public IP (M2, Blockscout) | explorer |
| `finchain.one` | static site (later) | documentation, manifests |

Caddy issues certificates automatically once the records resolve and ports 80/443 are
open. Set `ACME_EMAIL` in `node-b/.env`.

## CPU architecture on host A

The pinned images must provide a build for host A's CPU (`make preflight-a` checks the
manifests). If an image lacks one:

1. preferred: run that component as a native binary from the same release tag on host A,
   with the same flags (document the binary checksum in `versions.lock`);
2. fallback: run the amd64 image under emulation (Docker Desktop with Rosetta); acceptable
   for the idle sequencer stack, not for proof work;
3. the decision is recorded in the manifest's software section.

## macOS specifics

- Disable sleep: `sudo pmset -a sleep 0 disablesleep 1`; keep the machine on mains power
  and wired Ethernet.
- Use named volumes, not bind mounts, for `op-reth` data (bind-mount I/O is slow on macOS).
- Grant Docker enough memory (8 GiB or more) and disk in its settings.
- Time synchronisation is on by default; verify in System Settings if blocks drift.

## Third-party verifiers (after M2)

Publish B's p2p multiaddr and ENR as the bootnode, together with `genesis.json`,
`rollup.json` and the L1 contract addresses. A third party follows `node-b/` with its own
L1 provider and no sequencer forwarding.
