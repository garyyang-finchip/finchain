#!/usr/bin/env bash
# Send ETH from the deployer key to the hot role addresses (keys/addresses.env).
#
# Usage: scripts/fund-roles.sh <role>=<eth> [<role>=<eth> ...]
#   roles: batcher | proposer | challenger | unsafe_block_signer   (lower case)
#   e.g.   scripts/fund-roles.sh batcher=0.3 proposer=0.2 challenger=0.1
#
# One plain transfer per role, sent by cast with the node's own fee estimate; each transfer
# is confirmed before the next one is sent. Balances are printed before and after. The
# deployer key is read from keys/deployer.json, so this runs on the host that holds keys/.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl
load_standard_env
load_env "$FINCHAIN_ROOT/keys/addresses.env"
[ -n "${CAST_BIN:-}" ] || require_cmd docker
[ "$#" -ge 1 ] || die "usage: fund-roles.sh <role>=<eth> ...   (roles: batcher proposer challenger unsafe_block_signer)"

deployer_addr="$(key_field deployer address)"
deployer_pk="$(key_field deployer private_key)"

balance_eth() { hex_to_eth "$(rpc "$L1_RPC_URL" eth_getBalance "[\"$1\",\"latest\"]" | jq -r '.result // "0x0"')"; }

role_addr() { # role -> address from keys/addresses.env
  case "$1" in
    batcher) echo "${BATCHER_ADDRESS:-}" ;;
    proposer) echo "${PROPOSER_ADDRESS:-}" ;;
    challenger) echo "${CHALLENGER_ADDRESS:-}" ;;
    unsafe_block_signer) echo "${UNSAFE_BLOCK_SIGNER_ADDRESS:-}" ;;
    *) echo "" ;;
  esac
}

wait_receipt() { # <txhash> -> receipt JSON, fails after 600 s
  local h="$1" waited=0 r
  while :; do
    r="$(rpc "$L1_RPC_URL" eth_getTransactionReceipt "[\"$h\"]" 2>/dev/null | jq -c '.result // empty' 2>/dev/null || true)"
    if [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
    [ "$waited" -lt 600 ] || return 1
    sleep 12; waited=$((waited + 12))
  done
}

echo "Deployer $deployer_addr: $(balance_eth "$deployer_addr") ETH"
total=0
for spec in "$@"; do
  role="${spec%%=*}"; amount="${spec#*=}"
  addr="$(role_addr "$role")"
  [ -n "$addr" ] || die "unknown role or address missing in keys/addresses.env: $role"
  awk -v a="$amount" 'BEGIN { exit !(a > 0 && a < 10) }' || die "amount for $role must be between 0 and 10 ETH: $amount"
  echo "  $role $addr: $(balance_eth "$addr") ETH  ->  +$amount ETH"
  total="$(awk -v t="$total" -v a="$amount" 'BEGIN { printf "%.6f", t + a }')"
done
echo "Total to send: $total ETH"
if [ "${YES:-0}" != "1" ]; then
  read -r -p "Send these transfers from the deployer now? [yes/NO] " answer
  [ "$answer" = "yes" ] || die "aborted; nothing was sent"
fi

for spec in "$@"; do
  role="${spec%%=*}"; amount="${spec#*=}"
  addr="$(role_addr "$role")"
  tx="$(cast send --rpc-url "$L1_RPC_URL" --private-key "$deployer_pk" --value "${amount}ether" --async "$addr" | tr -d '[:space:]')"
  case "$tx" in 0x*) ;; *) die "cast send failed for $role: $tx" ;; esac
  log "$role: sent $amount ETH, tx $tx"
  receipt="$(wait_receipt "$tx")" || die "no receipt for $tx after 600 s; check the explorer before retrying"
  [ "$(( $(printf '%s' "$receipt" | jq -r .status) ))" = "1" ] || die "transfer to $role failed on chain: $tx"
  echo "  $role now $(balance_eth "$addr") ETH (block $(( $(printf '%s' "$receipt" | jq -r .blockNumber) )))"
done
echo "Deployer $deployer_addr: $(balance_eth "$deployer_addr") ETH"
