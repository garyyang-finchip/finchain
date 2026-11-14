# node-b: verification host

Services: `op-reth` (archive execution client), `op-node` (verifier), `op-challenger`
(`permissioned` trace type, resident), `caddy` (TLS termination for `rpc.finchain.one`
and `ws.finchain.one`). Started with `make up-b` (a profile sets batcher and proposer
parameters and does not change this host). `CHALLENGER_L1_RPC_URL` in `.env` gives
op-challenger an L1 endpoint of its own (see `.env.example`).

Inputs:

- `../chain/out/genesis.json`, `../chain/out/rollup.json`
- `secrets/jwt.txt`, `secrets/p2p-node-key.txt`, `secrets/op-challenger.env`
  (from `make install-bundle-b`)
- `.env`: `B_BIND_IP`, `P2P_ADVERTISE_IP` (public IP), `P2P_STATIC_PEERS` (host A),
  `SEQUENCER_HTTP` (host A's execution RPC over the private network), L1 endpoints
  (a different provider than host A), `DISPUTE_GAME_FACTORY`, hostnames, `ACME_EMAIL`

Independence: own data volumes, own L1 provider, derivation from L1. The p2p link to A
only delivers unsafe blocks early. `scripts/rebuild-from-l1.sh` is the acceptance test
that this host can rebuild the chain from public inputs and L1 alone.

The execution client on this host serves only `eth`, `net` and `web3`; `admin` and
`debug` are not enabled because Caddy forwards every JSON-RPC request. Rate limiting and
an explorer (Blockscout) are added at M2.
