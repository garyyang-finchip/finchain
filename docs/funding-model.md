# Funding model (Sepolia ETH)

Four separate needs. They are budgeted, funded and reported separately; "2-3 ETH for a
testnet" (the figure in the OP Stack tutorial) covers at most the first two and must not be
read as covering bonds. `make funding-table PROFILE=<demo|lowcost>` prints the live table
from the parameters below and the current gas price.

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
| batcher | one per channel on a quiet chain: 86400 / (12 s x `BATCHER_MAX_CHANNEL_DURATION`) per day | demo (15 blocks): ~480/day; lowcost (300 blocks): ~24/day. Busy periods add transactions. |
| proposer | 24 h / `PROPOSER_INTERVAL` game creations per day | demo (1 h): 24/day; lowcost (6 h): 4/day |
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

### 3b. Full dispute path

Every move inside a dispute posts `getRequiredBond(position)`, which grows with depth. The
OP Stack documentation gives, for standard parameters, a worst-case liquidity need of about
315.6 ETH for one side walking a maximum-depth path. Finchain's exact figures depend on the
deployed game parameters and are measured on the isolated devnet during the M4 drill
(`docs/proof-plan.md`). The full path is not budgeted on public Sepolia in v0.1.

## 4. ETH deposited into L2

The public testnet mints nothing at genesis. ETH for the deployer of the covenant World,
the treasury, the faucet and users enters through `OptimismPortal`
(`make deposit AMOUNT=...`). This line is sized by what the World deployment, FOGA cells
and the faucet need on L2 (`PLANNED_L2_DEPOSIT_ETH`).

## Sources of Sepolia ETH

Priority: existing balances held by the operator; developer quotas from L1 providers;
public faucets (the Superchain faucet gives 0.05 ETH per claim). A purchase of testnet ETH
through a bridge service is not decided in v0.1; if it is considered later, availability,
rate and the actual requirement are checked at that time.

## Reporting

The funding table for the chosen profile, the measured deployment cost and the hot-role
balances (`make status-a`) are part of the M1 record.
