# Proof plan

Finchain Sepolia launches with the standard permissioned path. The ability to run a real
fault proof is demonstrated separately, on an isolated environment, with a dedicated
adversarial driver and transaction-level evidence. Nothing in between is claimed.

## What the contracts and clients provide

- Contracts (op-contracts/v7.0.0): `PermissionedDisputeGame` inherits `FaultDisputeGame`;
  `move()` and `step()` add an authorisation check and then call the parent
  implementation. The VM single-step proof is available to the authorised proposer and
  challenger.
- Client (op-challenger v1.9.x): trace type `permissioned` is registered on the Cannon +
  op-program path and skips prestate validation; trace type `cannon-kona` is a separate
  Cannon + Kona path. Running `permissioned` with a Kona prestate does not produce
  "authorised participants with Kona proofs"; `run-trace` is a trace self-check and is not
  the resident service.
- The public testnet's game implementation is deployed with the absolute prestate
  configured at deployment. Unless that prestate embeds Finchain's rollup and genesis
  configuration, a real dispute on that implementation cannot reach a valid step. A new
  implementation with a Finchain-embedding prestate must be installed before full-VM
  capability is claimed on the public chain.

## Levels and claims

| Level | What runs | What may be claimed |
| --- | --- | --- |
| L0 (M1) | op-proposer creates games of the respected type; nobody challenges | output roots are published; no proof system claim |
| L1 (M2/M4a) | resident op-challenger (`permissioned`) on host B resolves games, claims bonds, and counter-moves against a different proposer claim | permissioned challenge and resolution flow is operational |
| L2 (M4b) | isolated devnet: full Cannon-Kona game with a Finchain-embedding prestate, an adversarial driver that keeps answering until the execution-trace divergence is reached, a real `step()` transaction, resolution against the bad root | the proof system executes end to end for Finchain's configuration (environment stated) |
| L3 (M5) | the same on the public chain (new game implementation with the embedding prestate, then permissionless type) | public fault-proof capability |

A game won by timeout (the bad proposer stops answering) demonstrates L1, never L2.

## M4b drill: isolated environment

Environment: a local L1 devnet (for example the OP Stack Kurtosis devnet or the automated
deployment example with a local L1), the same `versions.lock`, Finchain's chain id and
parameters. Funds are free there, so bonds of any size can be posted.

Steps:

1. Build the prestate from `KONA_NODE_TAG` with Finchain's `rollup.json` and `genesis.json`
   merged (`just reproducible-prestate-kona` in the monorepo checkout). Confirm the chain
   configuration is embedded (the decompressed prestate must contain the chain name / id).
   Record the prestate hash and the build procedure.
2. Deploy the chain on the devnet with the game implementation pointing at that prestate
   (permissionless CANNON type for the drill; the permissioned variant may be added as a
   second run if the driver is adapted to the authorised roles).
3. Run the resident op-challenger (`cannon-kona`) on the B-equivalent node.
4. Adversarial driver: a second proposer posts an invalid output root and keeps responding
   to every counter-move (attack/defend at each depth) until the dispute reaches the
   execution-trace split and the first `step()`.
5. Record the evidence listed below; stop the driver; let the game resolve; confirm the
   invalid root is not accepted as a withdrawal basis (anchor state unchanged).

Evidence (committed under `manifests/evidence/`):

- game address, game type, implementation address;
- VM address, prestate hash, Finchain configuration it embeds;
- the sequence of attack/defend transactions and the final dispute depth;
- the `step()` transaction receipt executed by the contract;
- resolution result, bond settlement, anchor state before and after;
- `versions.lock` digests used.

The drill is recorded with `environment: local-devnet`. The public-chain repetition (L3) is
a separate acceptance entry that stays `not-run` until done.

## Resident service on the public testnet

`node-b/docker-compose.yml` runs `op-challenger --trace-type=permissioned` with the
challenger key. Its duties at L1: watch the factory, resolve games after the clock, claim
bonds, and respond to claims that contradict B's independently derived state. `op-dispute-mon`
is recommended for monitoring once more than one proposer or external participants exist.

What it did is read back from the chain by `make games` (`scripts/games.sh`): every game of
the respected type with its L2 block, status, the transaction that resolved it and that
transaction's sender (the challenger key, when the resident service resolved it), the moves
and the credit each party holds afterwards; the report is the M4 evidence for this level,
beside an excerpt of the service's own log. On Finchain Sepolia the initial bond of the
respected game type is 0 (set by the owner on 2026-11-11, `docs/funding-model.md`), so the
credit columns stay at zero and the evidence is the resolution itself: the status, the
resolving transaction and its sender. The first report
(`manifests/evidence/games-20261113T181336Z.json`, taken before any clock had expired) shows
48 hourly games, one claim each and no moves, with clocks ending from 2026-11-15T06:44Z; the
report after the first resolutions is the one that closes the item.

Operational finding (2026-11-13): with 48 games in flight the challenger's reads exceeded the
quota of the free public L1 endpoint on host B - a steady 1,400-1,600 `429 Too Many
Requests` per hour through the whole day, hitting the claim and status reads, the bond
claimer and the L1 head poll alike. Every failure is retried on the next L1 block and the
service kept tracking all 48 games, but the volume grows with the games in flight. The
response is the `steady` profile (one proposal every 6 hours) and an L1 endpoint of the
challenger's own with a known quota (`CHALLENGER_L1_RPC_URL`, node-b/.env), separate from
op-node's endpoint and from `make games`; the game window stays at the upstream default of
28 days, which covers the longest possible dispute plus the bond withdrawal delay.
`docs/funding-model.md` section 5 has the figures.
