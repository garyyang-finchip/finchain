# Funding model (Sepolia ETH)

Four separate needs. They are budgeted, funded and reported separately; "2-3 ETH for a
testnet" (the figure in the OP Stack tutorial) covers at most the first two and must not be
read as covering bonds. `make funding-table PROFILE=<steady|demo|lowcost>` prints the live
table from the parameters below and the current gas price. Section 5 is the one running cost
that is not paid in ETH: L1 RPC capacity for the resident challenger.

## 1. L1 contract deployment (one-off)

With a standard intent the deployment is one transaction to the OP Contracts Manager
(`deploy()`), which creates the chain's proxies, the per-chain dispute game implementation
and their storage. Cost = gas used x gas price at the time. On Sepolia under EIP-8037
(Glamsterdam, `docs/versions.md`) the live estimate is about 56M gas in total, of which
about 9M is execution gas and the rest state gas for the new contracts and slots; at 1 gwei
that is 0.056 ETH, at 20 gwei 1.1 ETH. `EST_DEPLOY_GAS` in `.env` holds the planning figure;
`chain/out/deployment.json` records the actual gas and `deployerSpentEth` after the run.
The deployer must hold gas limit x fee cap when the transaction is sent (the node refuses it
otherwise); the unused part of the gas limit is refunded. If a live-mode `apply` runs dry
midway, top the deployer up and re-run it: the tool resumes from `state.json`.

## 2. Daily operations

| Role | Transactions | Notes |
| --- | --- | --- |
| batcher | one per channel on a quiet chain: 86400 / (12 s x `BATCHER_MAX_CHANNEL_DURATION`) per day | steady and demo (15 blocks): ~480/day; lowcost (300 blocks): ~24/day. Busy periods add transactions. |
| proposer | 24 h / `PROPOSER_INTERVAL` game creations per day | steady and lowcost (6 h): 4/day; demo (1 h): 24/day |
| challenger | resolve + claim per game, plus any counter-moves | permissioned games with no adversary: a few transactions per game |

Gas per transaction is measured after M1 (`EST_*_GAS` placeholders in `.env`). Under
EIP-8037 every transaction that creates state pays the higher state-gas prices: a game
creation deploys a clone proxy (new account 183,600 plus code and slots) and is expected
around 1M gas rather than the pre-Glamsterdam 600K; batcher calldata pays the EIP-7976
floor cost (about 1.5x the previous floor). The placeholders are set on the high side until
measured.

## 3. Bonds

### 3a. Initial bonds in flight

Each game creation pays `initBonds[gameType]` (standard configuration: 0.08 ETH). The bond
returns to the proposer only after the game resolves (max clock duration, 3.5 days at
standard parameters) and the DelayedWETH withdrawal delay (7 days at standard parameters).

Rolling occupancy = proposals per day x recovery days x initial bond. Examples at 0.08 ETH
and 10.5 days recovery: hourly proposals -> 252 games x 0.08 = 20.2 ETH; 6-hourly -> 42
games x 0.08 = 3.36 ETH. With a 7-day recovery and hourly proposals the figure is 13.44 ETH.
These are liquidity requirements, not consumption, but they must exist.

Testnet options, each recorded in the manifest when used: lower `PROPOSER_INTERVAL`
frequency (lowcost profile), set the initial bond lower or to zero through the DGF owner
(`make set-init-bond`), shorten the game clock or WETH delay via deploy overrides at
deployment. Setting the initial bond to zero changes only game creation; the per-move
bonds below are unaffected.

#Mainnet (chain id 8454, since 2026-11-18): the respected type's initial bond is the standard
0.08 ETH, the DelayedWETH delay 7 days, the proposal cadence one a day (`profiles/mainnet.env`),
so about 10.5 games and 0.84 ETH are in flight at steady state; the proposer's standing float is
1.2 ETH, the batcher's 0.3 ETH, the challenger's 0.1 ETH (`docs/mainnet.md`, decisions 2 and 7).
A bond comes back only when someone calls `claimCredit(proposer)` on the resolved game after the
delay; op-proposer never does, and op-challenger's bond claimer claims only for its own account
unless told otherwise. On host B's mainnet stack the claimer is given the proposer as an
additional claimant (`OP_CHALLENGER_ADDITIONAL_BOND_CLAIMANTS` in
`node-b/secrets.mainnet/op-challenger-extra.env`), so the float revolves on its own; without it
the bonds sit in DelayedWETH as credit until claimed by hand. The bond float is operating
capital, not spend: what the chain consumes is gas (deployment 0.012 ETH; batcher, proposer and
challenger together about 0.015-0.02 ETH a day at 1 gwei), and the float returns in full once the
chain stops proposing and its last game has resolved and matured.

### 3b. Full dispute path

Every move inside a dispute posts `getRequiredBond(position)`, which grows with depth. The
OP Stack documentation gives, for standard parameters, a worst-case liquidity need of about
315.6 ETH for one side walking a maximum-depth path. Measured on the isolated devnet during
the M4 drill (K3, 2026-11-16, `manifests/evidence/devnet-dispute-854220-20261116T161502Z.json`;
the schedule depends on the max game depth, 73 on the devnet as on Finchain Sepolia): 0.088 ETH
at depth 1, 1.33 ETH at depth 31, 60 ETH at depth 73; the honest side of one full-depth game
posted 36 claims and had 329.9 ETH locked until resolution, the attacker 37 claims and 361.3
ETH; at resolution every bond of the game, 691.15 ETH, was credited to the honest challenger.
The full path is not budgeted on public Sepolia in v0.1.

## 4. ETH deposited into L2

The public testnet mints nothing at genesis. ETH for the deployer of the covenant World,
the treasury, the faucet and users enters through `OptimismPortal`
(`make deposit AMOUNT=...`). This line is sized by what the World deployment, FOGA cells
and the faucet need on L2 (`PLANNED_L2_DEPOSIT_ETH`).

## 5. L1 RPC capacity (not ETH)

The resident challenger on host B runs an update cycle on every L1 head it sees (one per L1
block, 12 s, at the upstream defaults). A cycle re-reads the whole game list inside its window
(`--game-window`, 28 days upstream) and, for every game in it, the bond claimer's reads - credit
and status, whether the game is closed, and a `closeGame()` simulation until it is closed,
about five `eth_call` per game whether the game is resolved or not - plus about ten per game in
progress (claims, status, credit, the challenged-block flag). With 48 hourly games on
2026-11-13 that was roughly 50 requests per second against the free public endpoint host B
shared with op-node; the endpoint answered a steady 1,400-1,600 `429 Too Many Requests` per
hour through the day, and even the L1 head poll was hit. On 2026-11-18, with 72 games in the
window and four a day being added, 66 cycles an hour still failed on the same endpoint. Every
failure is retried on the next cycle, so the service kept tracking all games, but the volume
grows with the games in the window. Four measures follow. The `steady` profile creates four
games a day instead of 24, which cuts the games in flight (and the proposer's gas) to a sixth.
`--min-update-interval` (`CHALLENGER_MIN_UPDATE_INTERVAL`, node-b/.env, 60s since
v0.3.0-alpha.24) runs one cycle per minute of L1 time instead of one per block, a fifth of the
reads; a move, a resolution or a claim is at most a minute later than it could be, against
clocks of 3.5 days and a 3-hour clock extension. `--game-window` (`CHALLENGER_GAME_WINDOW`,
336h since the same version) tracks 14 days instead of 28: two full chess clocks (7 days) plus
the 3.5-day finality and withdrawal delays, plus 3.5 days of margin; at four games a day that
is 56 games in the window at steady state instead of 112, and any older game's bond stays
claimable by hand. `CHALLENGER_L1_RPC_URL` gives the challenger an endpoint with a known
quota, separate from op-node's endpoint and from the ad hoc reads of `make games`; a metered
provider counts each call inside a batch, so size the plan from the figures above - the free
tiers of the metered providers checked on 2026-11-18 allow on the order of a million calls a
month (Alchemy: 30M compute units, 26 per `eth_call`), less than the challenger read in a day
at the upstream defaults, and a tier that is used up stops answering, which is worse than a
public endpoint that rate-limits; such a tier fits only after the two settings above and with
the usage watched. An operator's own L1 node removes the quota question and is the planning
assumption for mainnet (M5, `docs/mainnet.md` decision 3).

## Sources of Sepolia ETH

Priority: existing balances held by the operator; developer quotas from L1 providers;
public faucets (the Superchain faucet gives 0.05 ETH per claim). A purchase of testnet ETH
through a bridge service is not decided in v0.1; if it is considered later, availability,
rate and the actual requirement are checked at that time.

## Reporting

The funding table for the chosen profile, the measured deployment cost and the hot-role
balances (`make status-a`) are part of the M1 record.
