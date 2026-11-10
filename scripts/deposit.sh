#!/usr/bin/env bash
# Bridge ETH from Sepolia into Finchain through the OptimismPortal (the only way balances
# enter the public testnet - no genesis pre-funding). Sending ETH to the portal credits the
# same address on L2 once the deposit is derived (a few L1 blocks).
#
# Usage: scripts/deposit.sh <amount-eth> [key-role=deployer] [l2-rpc=http://127.0.0.1:8545]
# Example: scripts/deposit.sh 0.5 deployer http://127.0.0.1:8545

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl docker
load_standard_env

AMOUNT="${1:?amount in ETH}"
ROLE="${2:-deployer}"
L2_RPC="${3:-http://127.0.0.1:8545}"

PORTAL="$(jq -r '.l1.OptimismPortalProxy // empty' "$FINCHAIN_ROOT/chain/out/chain-record.json")"
[ -n "$PORTAL" ] || die "OptimismPortalProxy missing in chain/out/chain-record.json"

from="$(key_field "$ROLE" address)"
pk="$(key_field "$ROLE" private_key)"

before="$(rpc "$L2_RPC" eth_getBalance "[\"$from\",\"latest\"]" | jq -r .result)"
log "L2 balance of $from before: $(awk -v w="$((before))" 'BEGIN { printf "%.6f", w / 1e18 }') ETH"
log "sending $AMOUNT ETH to OptimismPortal $PORTAL on Sepolia"

tx="$(cast send "$PORTAL" --value "${AMOUNT}ether" --private-key "$pk" --rpc-url "$L1_RPC_URL" --json)"
echo "$tx" | jq -c '{transactionHash, blockNumber, status, gasUsed}'

log "waiting for the deposit to be derived on L2 (up to ~10 minutes)"
for _ in $(seq 1 60); do
  after="$(rpc "$L2_RPC" eth_getBalance "[\"$from\",\"latest\"]" | jq -r .result)"
  if [ "$((after))" -gt "$((before))" ]; then
    echo "L2 balance now: $(awk -v w="$((after))" 'BEGIN { printf "%.6f", w / 1e18 }') ETH"
    exit 0
  fi
  sleep 10
done
warn "deposit not visible on L2 yet; check op-node derivation and L1 confirmations"
exit 2
