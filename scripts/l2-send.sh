#!/usr/bin/env bash
# Plain ETH transfer on Finchain (L2) from a repository key, e.g. to fund FOGA's World deployer W
# from the deployer's bridged balance.
#
# Usage: scripts/l2-send.sh <to-address> <amount-eth> [key-role=deployer] [l2-rpc=https://rpc.finchain.one]
#   env: YES=1 skips the confirmation prompt
# One transaction, waited for; balances printed before and after.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk
load_standard_env
[ -n "${CAST_BIN:-}" ] || require_cmd docker

TO="${1:?to address}"
AMOUNT="${2:?amount in ETH}"
ROLE="${3:-deployer}"
L2_RPC="${4:-https://rpc.finchain.one}"
case "$TO" in 0x[0-9a-fA-F]*) [ "${#TO}" = "42" ] || die "bad address: $TO" ;; *) die "bad address: $TO" ;; esac
awk -v a="$AMOUNT" 'BEGIN { exit !(a > 0 && a < 100) }' || die "amount must be between 0 and 100 ETH: $AMOUNT"

from="$(key_field "$ROLE" address)"
pk="$(key_field "$ROLE" private_key)"
chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
[ "$((chain_hex))" = "${CHAIN_ID:?}" ] || die "L2 RPC $L2_RPC reports chain id $((chain_hex)), .env says $CHAIN_ID"
bal_eth() { hex_to_eth "$(rpc "$L2_RPC" eth_getBalance "[\"$1\",\"latest\"]" | jq -r .result)"; }
echo "L2 RPC: $L2_RPC (chain id $((chain_hex)))"
echo "from:   $from ($ROLE)  $(bal_eth "$from") ETH"
echo "to:     $TO  $(bal_eth "$TO") ETH"
echo "amount: $AMOUNT ETH"
if [ "${YES:-0}" != "1" ]; then
  read -r -p "Send now? [yes/NO] " answer
  [ "$answer" = "yes" ] || die "aborted; nothing was sent"
fi
r="$(cast send --rpc-url "$L2_RPC" --private-key "$pk" --value "${AMOUNT}ether" --json "$TO")" || die "transfer failed"
[ "$(printf '%s' "$r" | jq -r .status)" = "0x1" ] || die "transfer reverted: $(printf '%s' "$r" | jq -r .transactionHash)"
echo "tx $(printf '%s' "$r" | jq -r .transactionHash) in block $(( $(printf '%s' "$r" | jq -r .blockNumber) ))"
echo "from:   $from  $(bal_eth "$from") ETH"
echo "to:     $TO  $(bal_eth "$TO") ETH"
