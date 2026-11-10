# Governance and roles

## Chain roles (controlled by Finchain)

| Role | Holder (v0.1) | Hot/cold | Scope |
| --- | --- | --- | --- |
| l1ProxyAdminOwner | owner address | cold (external wallet) | upgrades of the chain's L1 proxies; owner of the DisputeGameFactory (`setInitBond`, `setImplementation`) |
| l2ProxyAdminOwner | owner address | cold | upgrades of L2 predeploy proxies |
| systemConfigOwner | owner address | cold | SystemConfig parameters: batcher hash, unsafe block signer, gas config, fee scalars |
| unsafeBlockSigner | host A key | hot | signs p2p unsafe block gossip |
| batcher | host A key | hot | submits batch data to L1 |
| proposer | host A key | hot | creates dispute games (output proposals); permissioned game proposer |
| challenger | host B key | hot | permissioned game challenger; resolves games |

On the testnet the owner may be a single externally held address. For mainnet the owner
roles move to a Safe with a stated signer set; this is an M5 item.

## Shared authority (not Finchain's)

Under `standard-overrides` the chain is attached to the Sepolia SuperchainConfig used by
OP Stack chains on Sepolia. The guardian of that configuration can pause bridges and
portals of attached chains, and the shared proxy admin owner controls the OPCM and shared
implementations. These are not Finchain roles. The manifest records the SuperchainConfig
address, its guardian and the scope at the time of the snapshot
(`manifests/onchain-<block>.json`).

A `standalone` deployment (own SuperchainConfig, own guardian) removes that dependency at
the cost of a custom intent and a release constraint on the OPCM version. It is a mainnet
decision.

## Key handling

- Hot keys are generated on the host that uses them (host A) or moved once over the
  private network (host B bundle), stored with mode 0600 in `node-*/secrets/`, never
  committed, never placed in shared folders.
- The deployer key may be drained after deployment; it holds no role.
- Rotation: `unsafeBlockSigner` and `batcher` are changed through SystemConfig by the
  owner; the proposer and challenger of the permissioned game are immutable per game
  implementation and require a new implementation to rotate.

## Change control

Parameter changes (profile switches, init bond, game implementation, versions) are
recorded in the manifest history with the L1 block of the change. A new reference version
is published when the covenant World, the chain software set or the governance addresses
change.
