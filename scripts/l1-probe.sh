#!/usr/bin/env bash
# Probe Sepolia execution RPC endpoints from this host and report which ones are usable:
# correct chain id, `finalized` block tag served, eth_getLogs allowed, and latency.
# Use it to pick L1_RPC_URL for a host (each host should use a different provider).
#
# Usage: scripts/l1-probe.sh [url ...]      (default: a list of public endpoints)

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd curl jq

if [ "$#" -gt 0 ]; then
  urls=("$@")
else
  urls=(
    https://ethereum-sepolia-rpc.publicnode.com
    https://sepolia.gateway.tenderly.co
    https://1rpc.io/sepolia
    https://rpc.sepolia.org
    https://ethereum-sepolia.blockpi.network/v1/rpc/public
    https://sepolia.drpc.org
    https://rpc2.sepolia.org
  )
fi

printf '%-60s %-8s %-10s %-9s %-8s\n' "endpoint" "chainId" "finalized" "getLogs" "ms"
for u in "${urls[@]}"; do
  start=$(date +%s%N 2>/dev/null || echo 0)
  cid="$(curl -sS -m 10 -X POST "$u" -H 'content-type: application/json' \
          --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' 2>/dev/null | jq -r '.result // empty')"
  end=$(date +%s%N 2>/dev/null || echo 0)
  if [ -z "$cid" ]; then
    printf '%-60s %-8s %-10s %-9s %-8s\n' "$u" "-" "-" "-" "unreachable"
    continue
  fi
  ms=$(( (end - start) / 1000000 ))
  fin="$(curl -sS -m 10 -X POST "$u" -H 'content-type: application/json' \
          --data '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["finalized",false]}' 2>/dev/null | jq -r '.result.number // empty')"
  [ -n "$fin" ] && fin="$((fin))" || fin="no"
  logs="$(curl -sS -m 15 -X POST "$u" -H 'content-type: application/json' \
          --data '{"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"fromBlock":"latest","toBlock":"latest"}]}' 2>/dev/null | jq -r 'if .result then "ok" elif .error then "ERR" else "no" end')"
  printf '%-60s %-8s %-10s %-9s %-8s\n' "$u" "$((cid))" "$fin" "$logs" "$ms"
done
echo
echo "Usable = chainId 11155111, a finalized block number, getLogs ok. Put the chosen URL in L1_RPC_URL."
