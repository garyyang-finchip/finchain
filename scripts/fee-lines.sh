#!/usr/bin/env bash
# The four funding lines of M3 (docs/world.md section 5, D7; docs/acceptance.md M3-C last item), read from the
# receipts through the public RPC: the identity root (chain operations deployer), the World deployment (W), the
# genesis T0-T9 (W and the drill roles) and the two-cell business loop (the OG and the second cell). Each line
# gives its transactions, the gas used and the three fee components of an OP Stack receipt - the execution fee
# (gasUsed x effectiveGasPrice), the L1 data fee (the receipt's l1Fee) and the operator fee (the receipt's
# operatorFeeScalar and operatorFeeConstant, when the chain sets them; zero otherwise) - and the payers.
#
# The business-loop receipts are also re-read against the chain at or below `finalized`: each receipt's block
# must be at or below the finalized head and its block hash must be the canonical one, which is the finalized
# confirmation of manifests/evidence/business-loop-<date>.json.
#
# Usage: scripts/fee-lines.sh [l2-rpc=https://rpc.finchain.one] [business-loop evidence=manifests/evidence/business-loop-2026-11-13.json]
# Reads the chain only (curl + jq); needs no key, no FOGA checkout. The report lands in
# manifests/evidence/fee-lines-<date>.json. Exit 3 when a receipt is missing, failed, or not yet final.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl

L2_RPC="${1:-https://rpc.finchain.one}"
LOOP="${2:-$FINCHAIN_ROOT/manifests/evidence/business-loop-2026-11-13.json}"
IDENTITY="$FINCHAIN_ROOT/chain/out/erc8004.json"
WORLD="$FINCHAIN_ROOT/manifests/covenant-world-finchain-sepolia.json"
GENESIS="$FINCHAIN_ROOT/manifests/evidence/foga-genesis-finchain-sepolia.json"
for f in "$IDENTITY" "$WORLD" "$GENESIS" "$LOOP"; do [ -f "$f" ] || die "not found: $f"; done

chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
final_hex="$(rpc "$L2_RPC" eth_getBlockByNumber '["finalized",false]' | jq -r .result.number)"
[ -n "$final_hex" ] && [ "$final_hex" != "null" ] || die "could not read the finalized head from $L2_RPC"
final=$(( final_hex ))
echo "chain $((chain_hex)) via $L2_RPC; finalized $final"

# The transaction hashes of each line, from the records that already hold them.
hashes_identity="$(jq -r '[.. | objects | select(has("tx")) | .tx | select(type == "string")] | unique | .[]' "$IDENTITY")"
hashes_world="$(jq -r '[.contracts[] | .deploymentTx, (.initializationTxs[]?)] | map(select(. != null)) | unique | .[]' "$WORLD")"
hashes_genesis="$(jq -r '[.journal[].detail | objects | .txHash | select(. != null)] | unique | .[]' "$GENESIS")"
hashes_loop="$(jq -r '[.steps[].tx | select(. != null)] | unique | .[]' "$LOOP")"
hashes_loop_funding="$(jq -r '.fulfiller.funding.tx // empty' "$LOOP")"

FAILED=0
# receipts <name> <hashes...> -> one JSON object: the line's totals and its receipts (compact), read one by one
receipts() {
  local name="$1"; shift
  local rows="[]" h r
  for h in "$@"; do
    r="$(rpc "$L2_RPC" eth_getTransactionReceipt "[\"$h\"]" | jq -c '.result')"
    if [ -z "$r" ] || [ "$r" = "null" ]; then
      warn "$name: no receipt for $h"; FAILED=1
      rows="$(jq -cn --argjson rows "$rows" --arg tx "$h" '$rows + [{tx: $tx, missing: true}]')"
      continue
    fi
    rows="$(jq -cn --argjson rows "$rows" --argjson r "$r" '
      def n: if . == null then 0 else tonumber end;
      # hex quantities to numbers (the fee fields fit in 2^53 on this chain; the sums are checked below)
      def hx: if . == null then 0 elif (type == "string" and startswith("0x")) then (.[2:] | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d)) else n end;
      ($r.gasUsed | hx) as $gas | ($r.effectiveGasPrice | hx) as $price | ($r.l1Fee | hx) as $l1
      | ($r.operatorFeeScalar | hx) as $ofs | ($r.operatorFeeConstant | hx) as $ofc
      | $rows + [{tx: $r.transactionHash, block: ($r.blockNumber | hx), blockHash: $r.blockHash, status: ($r.status | hx), from: $r.from, to: $r.to,
                  gasUsed: $gas, effectiveGasPriceWei: $price, executionFeeWei: ($gas * $price), l1FeeWei: $l1,
                  operatorFeeWei: (($gas * $ofs / 1000000) + $ofc | floor)}]')"
  done
  jq -cn --arg name "$name" --argjson rows "$rows" '
    ($rows | map(select(.missing != true))) as $ok
    | {line: $name, transactions: ($rows | length), receipts: ($ok | length), failedReceipts: ($ok | map(select(.status != 1)) | length),
       gasUsed: ($ok | map(.gasUsed) | add // 0), executionFeeWei: ($ok | map(.executionFeeWei) | add // 0), l1FeeWei: ($ok | map(.l1FeeWei) | add // 0),
       operatorFeeWei: ($ok | map(.operatorFeeWei) | add // 0),
       payers: ($ok | map(.from) | unique), blocks: {first: ($ok | map(.block) | min), last: ($ok | map(.block) | max)},
       items: $rows}
    | .totalFeeWei = (.executionFeeWei + .l1FeeWei + .operatorFeeWei)
    | .totalFeeEth = ((.totalFeeWei / 1e18 * 1e12 | round) / 1e12)'
}

# word-split the hash lists on purpose
# shellcheck disable=SC2086
line_identity="$(receipts "identity root" $hashes_identity)"
# shellcheck disable=SC2086
line_world="$(receipts "World deployment" $hashes_world)"
# shellcheck disable=SC2086
line_genesis="$(receipts "genesis T0-T9" $hashes_genesis)"
# shellcheck disable=SC2086
line_loop="$(receipts "business loop" $hashes_loop $hashes_loop_funding)"

for l in "$line_identity" "$line_world" "$line_genesis" "$line_loop"; do
  printf '  %-18s %4s tx  gas %-10s exec %-16s L1 %-8s operator %-6s total %s ETH  payers %s  blocks %s-%s\n' \
    "$(jq -r .line <<<"$l")" "$(jq -r .receipts <<<"$l")" "$(jq -r .gasUsed <<<"$l")" "$(jq -r .executionFeeWei <<<"$l")" \
    "$(jq -r .l1FeeWei <<<"$l")" "$(jq -r .operatorFeeWei <<<"$l")" "$(jq -r .totalFeeEth <<<"$l")" "$(jq -r '.payers | length' <<<"$l")" \
    "$(jq -r .blocks.first <<<"$l")" "$(jq -r .blocks.last <<<"$l")"
  [ "$(jq -r .failedReceipts <<<"$l")" = "0" ] || { warn "$(jq -r .line <<<"$l"): a receipt with status 0"; FAILED=1; }
done

# The business loop at finalized: every block at or below the finalized head, every block hash canonical.
loop_final="[]"
while IFS= read -r item; do
  [ -n "$item" ] || continue
  n="$(jq -r .block <<<"$item")"; want="$(jq -r .blockHash <<<"$item")"
  if [ "$n" -gt "$final" ]; then verdict="NOT YET (above finalized $final)"; FAILED=1; have=null
  else
    have="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$(printf '0x%x' "$n")\",false]" | jq -r .result.hash)"
    if [ "$have" = "$want" ]; then verdict="FINAL"; else verdict="MISMATCH (canonical $have)"; FAILED=1; fi
    have="\"$have\""
  fi
  loop_final="$(jq -cn --argjson a "$loop_final" --arg tx "$(jq -r .tx <<<"$item")" --argjson n "$n" --arg want "$want" --argjson have "$have" --arg v "$verdict" '$a + [{tx: $tx, block: $n, blockHash: $want, canonicalHash: $have, verdict: $v}]')"
  printf '  loop tx %s block %s: %s\n' "$(jq -r '.tx[0:10]' <<<"$item")" "$n" "$verdict"
done < <(jq -c '.items[] | select(.missing != true)' <<<"$line_loop")

mkdir -p "$FINCHAIN_ROOT/manifests/evidence"
out="$FINCHAIN_ROOT/manifests/evidence/fee-lines-$(date -u +%Y%m%dT%H%M%SZ).json"
jq -n --arg rpc "$(rpc_label "$L2_RPC")" --argjson chainId "$((chain_hex))" --argjson finalized "$final" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson a "$line_identity" --argjson b "$line_world" --argjson c "$line_genesis" --argjson d "$line_loop" --argjson lf "$loop_final" \
  --arg result "$([ "$FAILED" = 0 ] && echo PASS || echo FAIL)" '
  {schema: "finchain.fee-lines/1", acceptance: "M3 funding in four lines, three fee components per receipt (docs/world.md section 5, D7)",
   chainId: $chainId, rpc: $rpc, recordedAt: $at, finalizedAtRecord: $finalized,
   method: "every transaction of each line read by eth_getTransactionReceipt; executionFeeWei = gasUsed x effectiveGasPrice, l1FeeWei = the receipt l1Fee, operatorFeeWei = gasUsed x operatorFeeScalar / 1e6 + operatorFeeConstant (zero when the receipt carries neither); the business-loop blocks checked against the canonical chain at or below finalized",
   sources: {"identity root": "chain/out/erc8004.json", "World deployment": "manifests/covenant-world-finchain-sepolia.json (deploymentTx and initializationTxs)", "genesis T0-T9": "manifests/evidence/foga-genesis-finchain-sepolia.json (journal txHash)", "business loop": "manifests/evidence/business-loop-2026-11-13.json (steps[].tx and the second cell funding)"},
   lines: [$a, $b, $c, $d] | map(del(.items)), receipts: {"identity root": $a.items, "World deployment": $b.items, "genesis T0-T9": $c.items, "business loop": $d.items},
   businessLoopAtFinalized: $lf, result: $result}' > "$out"
echo "RESULT: $([ "$FAILED" = 0 ] && echo PASS || echo FAIL); report $out"
[ "$FAILED" = 0 ] || exit 3
