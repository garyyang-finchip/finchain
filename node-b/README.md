# node-b: verification host

Services: `op-reth` (archive execution client), `op-node` (verifier), `op-challenger`
(`permissioned` trace type, resident), `caddy` (TLS termination for `rpc.finchain.one`
and `ws.finchain.one`). Started with `make up-b` (a profile sets batcher and proposer
parameters and does not change this host; `CHAIN=<name>` starts a second chain's stack without
Caddy, `docs/runbook.md` section 9). `CHALLENGER_L1_RPC_URL` in `.env` gives
op-challenger an L1 endpoint of its own; `CHALLENGER_MIN_UPDATE_INTERVAL` (default 60s) and
`CHALLENGER_GAME_WINDOW` (default 336h) set how often it re-reads its games and how far back it
looks (see `.env.example`, `docs/funding-model.md` section 5). `make restart-b SVC=op-challenger`
recreates the challenger alone after a change to these; op-reth and op-node keep running.

Inputs:

- `../chain/out/genesis.json`, `../chain/out/rollup.json`
- `secrets/jwt.txt`, `secrets/p2p-node-key.txt`, `secrets/op-challenger.env`
  (from `make install-bundle-b`)
- `.env`: `B_BIND_IP`, `P2P_ADVERTISE_IP` (public IP), `P2P_STATIC_PEERS` (host A),
  `SEQUENCER_HTTP` (host A's execution RPC over the private network), L1 endpoints
  (a different provider than host A), `DISPUTE_GAME_FACTORY`, hostnames, `ACME_EMAIL`

M4 K4: `docker-compose.kona.yml` adds the `cannon-kona` trace type to the challenger (`make up-b
KONA=1`, `restart-b KONA=1 SVC=op-challenger`, `logs-b KONA=1 SVC=op-challenger`), so that it also plays games of the Type 8
(`CANNON_KONA`) implementation with kona-client in Cannon64. It needs the K2 artifacts on this host
(`make prestate`, `make kona-host`; `make k4-readiness` says what is present and whether the
challenger's L1 endpoint serves the raw-RLP debug methods a dispute would need; `docs/proof-plan.md`,
"K4"). The override does not change what the chain trusts: the respected game type is the anchor
state registry's setting, not the challenger's.

A second chain on this host (`CHAIN=<name>`, `docs/runbook.md` section 9) runs without a Caddy
of its own; its public hostnames are served by this stack's Caddy from a site file in
`caddy-sites/` (`caddy-sites/README.md`; Finchain mainnet's example is there).

Independence: own data volumes, own L1 provider, derivation from L1. The p2p link to A
only delivers unsafe blocks early. `scripts/rebuild-from-l1.sh` is the acceptance test
that this host can rebuild the chain from public inputs and L1 alone.

The execution client on this host serves only `eth`, `net` and `web3`; `admin` and
`debug` are not enabled because Caddy forwards every JSON-RPC request. Rate limiting and
an explorer (Blockscout) are added at M2.
