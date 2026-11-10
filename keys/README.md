# keys/

Key material for the Finchain roles. Everything in this directory except this file and
`.gitkeep` is git-ignored. `make keys` writes:

| File | Content | Lives on |
| --- | --- | --- |
| `deployer.json` | pays `op-deployer apply`; drained afterwards | host A |
| `unsafe_block_signer.json` | sequencer p2p block signing key | host A (`node-a/secrets/op-node.env`) |
| `batcher.json` | batch submissions | host A (`node-a/secrets/op-batcher.env`) |
| `proposer.json` | output proposals / game creation | host A (`node-a/secrets/op-proposer.env`) |
| `challenger.json` | game resolution and challenges | host B (`node-b/secrets/op-challenger.env`) |
| `owner.json` | only if `OWNER_ADDRESS` was empty: cold owner key, keep offline | offline |
| `node-{a,b}-jwt.txt` | Engine API secrets | respective host |
| `node-{a,b}-p2p-node-key.txt` | op-node peer identities | respective host |
| `addresses.env` | addresses only; safe to share | - |

Host B's secrets are moved once as `node-b-bundle.tar` over the private network
(`make bundle-b` on A, `make install-bundle-b` on B) and the bundle is deleted on both
sides afterwards. No key file is ever put in a shared folder, a chat, or the repository.
