#!/usr/bin/env bash
# One-screen status of a host: container state, L2 heads, L1 heads, role balances.
# Usage: scripts/status.sh <a|b> [profile]

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd docker jq curl
host="${1:?a|b}"; PROFILE="${2:-demo}"
load_standard_env
load_env "$FINCHAIN_ROOT/node-$host/.env"

bind="$([ "$host" = a ] && echo "${A_BIND_IP}" || echo "${B_BIND_IP}")"
L2="http://${bind}:8545"; NODE="http://${bind}:8547"

echo "== containers (finchain-$host)"
docker compose -f "$FINCHAIN_ROOT/node-$host/docker-compose.yml" \
  --env-file "$FINCHAIN_ROOT/versions.lock" --env-file "$FINCHAIN_ROOT/profiles/${PROFILE}.env" \
  --env-file "$FINCHAIN_ROOT/node-$host/.env" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

echo "== L2 heads (op-node optimism_syncStatus)"
if s="$(rpc "$NODE" optimism_syncStatus 2>/dev/null)"; then
  echo "$s" | jq -r '.result | "unsafe     #\(.unsafe_l2.number)  \(.unsafe_l2.hash)\nsafe       #\(.safe_l2.number)  \(.safe_l2.hash)\nfinalized  #\(.finalized_l2.number)  \(.finalized_l2.hash)\nL1 head    #\(.head_l1.number)   L1 finalized #\(.finalized_l1.number)"'
  # The two numbers that say whether this node still follows L1: the age of the L1 head it holds, and the
  # distance between unsafe (p2p) and safe (derived from L1). Both grow without bound when the L1 endpoint
  # fails (quota, outage) while unsafe blocks keep arriving over p2p: the chain looks alive, finality stalls.
  l1_age=$(( $(date +%s) - $(echo "$s" | jq -r '.result.head_l1.timestamp // 0') ))
  gap=$(( $(echo "$s" | jq -r '.result.unsafe_l2.number // 0') - $(echo "$s" | jq -r '.result.safe_l2.number // 0') ))
  echo "L1 head age $((l1_age / 60)) min; unsafe-safe gap $gap blocks"
  if [ "$l1_age" -gt 600 ] || [ "$gap" -gt 1800 ]; then
    echo "WARNING: L1 tracking looks stalled (L1 head older than 10 min or safe more than an hour behind unsafe)."
    echo "         Check the op-node log for L1 RPC errors (quota, 429, timeouts) and see docs/runbook.md, section 8."
  fi
else
  echo "op-node RPC not reachable at $NODE"
fi

echo "== execution client"
if b="$(rpc "$L2" eth_blockNumber 2>/dev/null | jq -r .result)"; then
  echo "latest block: $((b))  chain id: $(( $(rpc "$L2" eth_chainId | jq -r .result) ))"
fi

echo "== peers"
rpc "$NODE" opp2p_peers '[true]' 2>/dev/null | jq -r '"connected: \(.result.totalConnected)"' || true

if [ -f "$FINCHAIN_ROOT/keys/addresses.env" ]; then
  echo "== Sepolia balances of hot roles"
  load_env "$FINCHAIN_ROOT/keys/addresses.env"
  for pair in "batcher:$BATCHER_ADDRESS" "proposer:$PROPOSER_ADDRESS" "challenger:$CHALLENGER_ADDRESS" "deployer:$DEPLOYER_ADDRESS"; do
    name="${pair%%:*}"; a="${pair##*:}"
    w="$(( $(rpc "$L1_RPC_URL" eth_getBalance "[\"$a\",\"latest\"]" | jq -r .result) ))"
    printf '  %-10s %s  %s ETH\n' "$name" "$a" "$(awk -v w="$w" 'BEGIN { printf "%.4f", w / 1e18 }')"
  done
fi
