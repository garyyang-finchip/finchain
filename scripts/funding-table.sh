#!/usr/bin/env bash
# Itemised Sepolia ETH budget for a runtime profile (docs/funding-model.md).
# Four separate needs: (1) L1 contract deployment, (2) daily operations of batcher,
# proposer and challenger, (3) dispute bonds - initial bonds in flight plus the full
# dispute path, (4) ETH deposited into L2 for users and the faucet.
#
# Usage: PROFILE=demo scripts/funding-table.sh [gas-price-gwei]
# Gas-per-transaction inputs are placeholders from .env until measured after M1.
# Bond and clock parameters are read from the latest manifests/onchain-*.json when present.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk
PROFILE="${PROFILE:-demo}"
load_standard_env

if [ -n "${1:-}" ]; then
  gwei="$1"; src="given"
else
  gwei="$(awk -v p="$(l1_gas_price_wei "$L1_RPC_URL")" 'BEGIN { printf "%.6f", p / 1e9 }')"; src="live ($L1_RPC_URL)"
fi

to_seconds() { # 6h | 90m | 3600s | 3600
  local v="$1"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}

snap_glob='onchain-[0-9]*.json'; [ "$CHAIN" = sepolia ] || snap_glob="onchain-$CHAIN-*.json"   # verify-onchain names a second chain's snapshot after it
snap="$(find "$FINCHAIN_ROOT/manifests" -maxdepth 1 -name "$snap_glob" -print 2>/dev/null | sort | tail -1 || true)"
# each parameter of the bond cycle with its source: the chain's own snapshot (make verify-onchain) where it holds the value,
# otherwise an assumption, named as such in the table
init_bond_wei="80000000000000000"; max_clock=302400; finality=302400; weth_delay=302400
src_bond="assumed"; src_clock="assumed"; src_finality="assumed"; src_weth="assumed"
if [ -n "$snap" ]; then
  t="$(jq -r '.optimismPortal.respectedGameType' "$snap")"
  g="$(jq -c --arg t "$t" '.disputeGameFactory.games[] | select((.gameType|tostring) == $t)' "$snap")"
  if [ -n "$g" ]; then
    b="$(echo "$g" | jq -r '.initBondWei // "n/a"')"; c="$(echo "$g" | jq -r '.maxClockDurationSeconds // "n/a"')"; d="$(echo "$g" | jq -r '.delayedWeth.delaySeconds // "n/a"')"
    [ "$b" != "n/a" ] && { init_bond_wei="${b%% *}"; src_bond="on-chain"; }
    [ "$c" != "n/a" ] && { max_clock="${c%% *}"; src_clock="on-chain"; }
    [ "$d" != "n/a" ] && { weth_delay="${d%% *}"; src_weth="on-chain"; }
  fi
  f="$(jq -r '.optimismPortal.disputeGameFinalityDelaySeconds // "n/a"' "$snap")"
  [ "$f" != "n/a" ] && { finality="${f%% *}"; src_finality="on-chain"; }
fi
bond_src="bond $src_bond, clock $src_clock, game finality $src_finality, WETH delay $src_weth"
if [ -n "$snap" ]; then bond_src="$bond_src; snapshot $(basename "$snap")"; else bond_src="$bond_src; no snapshot, the values of the Finchain deployments assumed"; fi

channel_blocks="${BATCHER_MAX_CHANNEL_DURATION:?}"
proposal_s="$(to_seconds "${PROPOSER_INTERVAL:?}")"

awk -v gwei="$gwei" -v src="$src" -v profile="$PROFILE" \
    -v deploy_gas="${EST_DEPLOY_GAS:-60000000}" \
    -v batcher_gas="${EST_BATCHER_GAS_PER_TX:-160000}" -v channel_blocks="$channel_blocks" \
    -v proposer_gas="${EST_PROPOSER_GAS_PER_TX:-600000}" -v proposal_s="$proposal_s" \
    -v challenger_gas="${EST_CHALLENGER_GAS_PER_GAME:-350000}" \
    -v init_bond_wei="$init_bond_wei" -v max_clock="$max_clock" -v finality="$finality" -v weth_delay="$weth_delay" -v bond_src="$bond_src" \
    -v deposit="${PLANNED_L2_DEPOSIT_ETH:-1.0}" '
BEGIN {
  price = gwei * 1e9;                           # wei per gas
  eth = 1e18;
  batcher_tx_day = 86400 / (12 * channel_blocks);   # quiet chain: one tx per channel
  proposals_day  = 86400 / proposal_s;
  deploy_eth     = deploy_gas * price / eth;
  batcher_eth    = batcher_tx_day * batcher_gas * price / eth;
  proposer_eth   = proposals_day * proposer_gas * price / eth;
  challenger_eth = proposals_day * challenger_gas * price / eth;
  init_bond_eth  = init_bond_wei / eth;
  # a bond is paid after three waits: the clock (resolve), the game finality delay (claimCredit closes the game and
  # unlocks the credit in DelayedWETH), the WETH delay (a second claimCredit pays it); plus the delay of the services
  recovery_days  = (max_clock + finality + weth_delay) / 86400;
  in_flight      = proposals_day * recovery_days;
  bonds_eth      = in_flight * init_bond_eth;

  printf "Finchain Sepolia funding table - profile %s, gas price %.6f gwei (%s)\n\n", profile, gwei, src;
  printf "| # | Need | Driver | Estimate |\n|---|---|---|---|\n";
  printf "| 1 | L1 contract deployment (one-off, deployer key) | %d gas x price | %.6f ETH |\n", deploy_gas, deploy_eth;
  printf "| 2a | Batcher, daily | %.1f tx/day x %d gas | %.6f ETH/day |\n", batcher_tx_day, batcher_gas, batcher_eth;
  printf "| 2b | Proposer, daily | %.1f proposals/day x %d gas | %.6f ETH/day |\n", proposals_day, proposer_gas, proposer_eth;
  printf "| 2c | Challenger, daily (resolve + claim) | %.1f games/day x %d gas | %.6f ETH/day |\n", proposals_day, challenger_gas, challenger_eth;
  printf "| 3a | Initial bonds in flight (proposer) | %.1f games x %.4f ETH, recovery %.1f days (%s) | %.4f ETH locked |\n", in_flight, init_bond_eth, recovery_days, bond_src, bonds_eth;
  printf "| 3b | Full dispute path (both sides) | per-move bonds from getRequiredBond(position); documented reference up to ~315.6 ETH per side at standard parameters | measured on the isolated devnet in M4; not budgeted on public Sepolia |\n";
  printf "| 4 | ETH deposited into L2 (users, faucet) | bridged through OptimismPortal | %.2f ETH |\n\n", deposit;
  printf "Daily operations total: %.6f ETH/day; 30 days: %.4f ETH (excluding bonds and deposits).\n", batcher_eth + proposer_eth + challenger_eth, 30 * (batcher_eth + proposer_eth + challenger_eth);
  printf "Gas prices on Sepolia swing by orders of magnitude; re-run before each funding decision.\n";
  printf "Gas-per-transaction inputs are placeholders until measured after M1 (see .env).\n";
}'
