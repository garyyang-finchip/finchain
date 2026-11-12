#!/usr/bin/env bash
# Host B's half of the EVM acceptance: re-read the record chain/out/evm-acceptance.json against the chain at a
# finalized block, through an endpoint that is not the one the transactions were sent to when possible (host B's
# own op-reth, or the public endpoint it serves). Receipts, blocks, code, storage and a call are checked; the
# report lands in manifests/evidence/evm-acceptance-verify-<block>.json. Exit 3 on any mismatch.
#
# Usage: scripts/verify-evm.sh [record=chain/out/evm-acceptance.json] [l2-rpc=http://<B_BIND_IP>:8545] [block=finalized]

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl
load_env "$FINCHAIN_ROOT/versions.lock"
[ -n "${CAST_BIN:-}" ] || require_cmd docker

RECORD="${1:-$FINCHAIN_ROOT/chain/out/evm-acceptance.json}"
L2_RPC="${2:-}"
AT="${3:-finalized}"
[ -f "$RECORD" ] || die "record not found: $RECORD"
if [ -z "$L2_RPC" ]; then
  if [ -f "$FINCHAIN_ROOT/node-b/.env" ]; then load_env "$FINCHAIN_ROOT/node-b/.env"; L2_RPC="http://${B_BIND_IP:-127.0.0.1}:8545"; else L2_RPC="https://rpc.finchain.one"; fi
fi

case "$AT" in
  finalized|safe|latest) block_hex="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$AT\",false]" | jq -r .result.number)" ;;
  0x*) block_hex="$AT" ;;
  *) block_hex="$(printf '0x%x' "$AT")" ;;
esac
[ -n "$block_hex" ] && [ "$block_hex" != "null" ] || die "could not resolve block $AT on $L2_RPC"
block=$(( block_hex ))
echo "chain $(( $(rpc "$L2_RPC" eth_chainId | jq -r .result) )) via $L2_RPC; checking at block $block ($AT)"

rows=""; failed=0
check() { # <name> <actual> <expected>
  local a b
  a="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; b="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
  if [ "$a" = "$b" ]; then printf '  %-10s %s = %s\n' match "$1" "$2"; rows="$rows{\"check\":\"$1\",\"result\":\"match\",\"actual\":\"$2\",\"expected\":\"$3\"},"
  else printf '  %-10s %s = %s (recorded %s)\n' MISMATCH "$1" "$2" "$3"; rows="$rows{\"check\":\"$1\",\"result\":\"mismatch\",\"actual\":\"$2\",\"expected\":\"$3\"},"; failed=1; fi
}
receipt_check() { # <label> <tx> <recorded block> <recorded block hash>
  local r
  r="$(rpc "$L2_RPC" eth_getTransactionReceipt "[\"$2\"]" | jq -c '.result // empty')"
  if [ -z "$r" ]; then check "$1.receipt" "missing" "present"; return; fi
  check "$1.status" "$(printf '%s' "$r" | jq -r .status)" "0x1"
  check "$1.block" "$(( $(printf '%s' "$r" | jq -r .blockNumber) ))" "$3"
  check "$1.blockHash" "$(printf '%s' "$r" | jq -r .blockHash)" "$4"
  [ "$3" -le "$block" ] || check "$1.atOrBelowCheckedBlock" "$3" "<= $block"
}

echo "== transactions"
receipt_check transfer "$(jq -r .transfer.receipt.tx "$RECORD")" "$(jq -r .transfer.receipt.block "$RECORD")" "$(jq -r .transfer.receipt.blockHash "$RECORD")"
receipt_check deployment "$(jq -r .contract.deployment.tx "$RECORD")" "$(jq -r .contract.deployment.block "$RECORD")" "$(jq -r .contract.deployment.blockHash "$RECORD")"
receipt_check write "$(jq -r .write.receipt.tx "$RECORD")" "$(jq -r .write.receipt.block "$RECORD")" "$(jq -r .write.receipt.blockHash "$RECORD")"

echo "== state at block $block"
probe="$(jq -r .contract.address "$RECORD")"; value="$(jq -r .write.value "$RECORD")"
code="$(rpc "$L2_RPC" eth_getCode "[\"$probe\",\"$block_hex\"]" | jq -r '.result // "0x"')"
if [ "$code" = "0x" ]; then code_hash="0x (no code)"; else code_hash="$(cast keccak "$code")"; fi
check "code.keccak" "$code_hash" "$(jq -r .contract.runtimeCodeKeccak "$RECORD")"
check "storage.slot0" "$(( $(rpc "$L2_RPC" eth_getStorageAt "[\"$probe\",\"0x0\",\"$block_hex\"]" | jq -r .result) ))" "$value"
check "call.value" "$(cast call "$probe" 'value()(uint256)' --block "$block" --rpc-url "$L2_RPC")" "$value"
check "call.writes" "$(cast call "$probe" 'writes()(uint256)' --block "$block" --rpc-url "$L2_RPC")" "1"
to="$(jq -r .transfer.to "$RECORD")"
bal="$(hex_to_eth "$(rpc "$L2_RPC" eth_getBalance "[\"$to\",\"$block_hex\"]" | jq -r .result)")"
amt="$(jq -r .transfer.amountEth "$RECORD")"
if awk -v b="$bal" -v a="$amt" 'BEGIN { exit !(b >= a) }'; then printf '  %-10s %s = %s ETH (>= %s)\n' match "recipient.balance" "$bal" "$amt"; rows="$rows{\"check\":\"recipient.balance\",\"result\":\"match\",\"actual\":\"$bal\",\"expected\":\">= $amt\"},"; else printf '  %-10s %s = %s ETH (< %s)\n' MISMATCH "recipient.balance" "$bal" "$amt"; rows="$rows{\"check\":\"recipient.balance\",\"result\":\"mismatch\",\"actual\":\"$bal\",\"expected\":\">= $amt\"},"; failed=1; fi

echo "== blocks"
cn="$(jq -r .completion.number "$RECORD")"; ch="$(jq -r .completion.hash "$RECORD")"
onchain="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$(printf '0x%x' "$cn")\",false]" | jq -r '.result.hash // empty')"
check "completion.canonical" "$onchain" "$ch"
fin=$(( $(rpc "$L2_RPC" eth_getBlockByNumber '["finalized",false]' | jq -r .result.number) ))
if [ "$cn" -le "$fin" ]; then printf '  %-10s completion block %s is finalized (finalized head %s)\n' match "$cn" "$fin"; rows="$rows{\"check\":\"completion.finalized\",\"result\":\"match\",\"actual\":\"$fin\",\"expected\":\">= $cn\"},"; else printf '  %-10s completion block %s is not yet finalized (finalized head %s)\n' "NOT YET" "$cn" "$fin"; rows="$rows{\"check\":\"completion.finalized\",\"result\":\"mismatch\",\"actual\":\"$fin\",\"expected\":\">= $cn\"},"; failed=1; fi

result=MATCH; [ "$failed" = "0" ] || result=MISMATCH
mkdir -p "$FINCHAIN_ROOT/manifests/evidence"
out="$FINCHAIN_ROOT/manifests/evidence/evm-acceptance-verify-$block.json"
jq -n --arg record "$RECORD" --arg rpc "$L2_RPC" --argjson block "$block" --arg tag "$AT" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson finalized "$fin" --argjson rows "[${rows%,}]" --arg result "$result" '
  { acceptance: "M3-A Finchain on its own (verification)", record: $record, rpc: $rpc, checkedAt: $at, block: $block, tag: $tag, finalizedHead: $finalized, checks: $rows, result: $result,
    method: "receipts by hash (status, block, block hash), code keccak and storage slot 0 at the fixed block, eth_call at the block, recipient balance, completion block canonical and finalized" }' > "$out"
echo "RESULT: $result; report $out"
[ "$result" = "MATCH" ] || exit 3
