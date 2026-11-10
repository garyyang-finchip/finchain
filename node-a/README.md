# node-a: sequencing host

Services: `op-reth` (archive execution client), `op-node` (sequencer), `op-batcher`,
`op-proposer`. Started with `make up-a PROFILE=demo|lowcost` from the repository root,
which passes `versions.lock`, the profile and `node-a/.env` as environment files.

Inputs:

- `../chain/out/genesis.json`, `../chain/out/rollup.json` (from `make export`)
- `secrets/jwt.txt`, `secrets/p2p-node-key.txt`, `secrets/op-node.env`,
  `secrets/op-batcher.env`, `secrets/op-proposer.env` (from `make secrets-a`)
- `.env`: `A_BIND_IP`, `P2P_ADVERTISE_IP`, `P2P_STATIC_PEERS`, L1 endpoints,
  `DISPUTE_GAME_FACTORY`, `PROPOSER_GAME_TYPE`

Exposure: nothing public. Private RPC ports bind to `A_BIND_IP` (the private-network
address); p2p 9222 is reachable by host B over the private network.

`PROPOSER_GAME_TYPE` must equal the respected game type read from L1 by
`make verify-onchain`. `DISPUTE_GAME_FACTORY` is filled by `make export`.
