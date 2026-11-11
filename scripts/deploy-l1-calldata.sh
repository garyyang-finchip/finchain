#!/usr/bin/env bash
# Deploy the Finchain L1 contracts as transactions signed and sent by cast, with gas limits
# taken from the live L1 node, instead of letting op-deployer broadcast them.
#
# Why this path exists: op-deployer's live mode runs the deployment in its built-in EVM
# (forks up to Cancun), pads the simulated gas by 1.2x and has txmgr check that limit with
# eth_call before sending. On an L1 that enforces EIP-8037 (Sepolia since Glamsterdam,
# 2026-10-06) creating state costs 5-8x more than that simulation assumes: the check fails
# with DeploymentFailed() and nothing is sent. The OPCM deploy() for one chain needs about
# 56M gas in total there (about 9M execution gas, the rest state gas). The 16,777,216 cap of
# EIP-7825 applies to execution gas only, so a transaction of that size is valid.
#
# Steps:
#   1. op-deployer apply --deployment-target calldata: fills state.json with the transaction
#      calldata, the predicted (CREATE2) addresses and the L2 genesis allocs; sends nothing.
#      Skipped when state.json already holds DeploymentCalldata.
#   2. For each transaction: eth_estimateGas on the live node; gas limit = estimate + 5%
#      (at least +1M, at most the block gas limit); eth_call dry run at that limit.
#   3. Print the cost and ask for confirmation (YES=1 skips the prompt).
#   4. cast send with the deployer key, wait for the receipt, require status 1.
#   5. Set the chain's startBlock in state.json to the block of the last transaction and
#      write chain/out/deployment.json. Then: make export.
#
# The deployer key must be the one op-deployer simulated with: the CREATE2 salt mixes in
# msg.sender, so another sender would create different addresses than those in state.json.
#
# Fees: EIP-1559 with an explicit priority fee (TX_PRIORITY_GWEI, default 2) and a fee cap of
# priority fee + 2 x current base fee + 1 gwei. Both are passed to cast explicitly because
# cast's own fee estimate on a quiet L1 (Sepolia base fee near zero) comes out below the
# chosen priority fee, which the node rejects ("max priority fee per gas higher than max fee").
#
# Variables: TX_PRIORITY_GWEI (priority fee, default 2), RECEIPT_TIMEOUT (seconds, default
# 1200), SEND_RPC_URL (endpoint for sending and receipts when it differs from L1_RPC_URL,
# which must accept estimates and calls up to the block gas limit), YES=1 (no prompt),
# FORCE=1 (ignore an existing chain/out/deployment.json).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl
load_standard_env

WORKDIR="$FINCHAIN_ROOT/chain/deployer"
STATE="$WORKDIR/state.json"
INTENT="$WORKDIR/intent.toml"
OUT="$FINCHAIN_ROOT/chain/out"
BIN="$(op_deployer_bin)"
[ -x "$BIN" ] || die "op-deployer binary missing; run: make op-deployer"
[ -f "$INTENT" ] || die "intent.toml missing; run: make intent"
if [ -f "$OUT/deployment.json" ] && [ "${FORCE:-0}" != "1" ]; then
  die "chain/out/deployment.json exists: the L1 contracts are already deployed (FORCE=1 to override)"
fi
[ -n "${CAST_BIN:-}" ] || require_cmd docker

deployer_addr="$(key_field deployer address)"
deployer_pk="$(key_field deployer private_key)"
chain_id_hex="$(chain_id_hex32)"
EIP7825_CAP=16777216
RPC_ERROR=""

# rpc_result <method> <params-json>: prints .result; on an RPC error sets RPC_ERROR and fails.
rpc_result() {
  local out
  RPC_ERROR=""
  out="$(rpc "$L1_RPC_URL" "$1" "$2" 2>/dev/null)" || { RPC_ERROR="no answer from $L1_RPC_URL"; return 1; }
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    RPC_ERROR="non-JSON reply: $(printf '%s' "$out" | head -c 200)"
    return 1
  fi
  RPC_ERROR="$(printf '%s' "$out" | jq -r '.error | select(. != null) | "\(.message // "error")\(if .data then " data=" + (.data|tostring) else "" end)"')"
  [ -z "$RPC_ERROR" ] || return 1
  printf '%s' "$out" | jq -r '.result'
}

# Known revert selectors, for readable error messages.
explain_revert() {
  case "$1" in
    *0x30116425*) echo "DeploymentFailed(): a CREATE2 inside the OPCM returned the zero address, usually out of gas in the creation frame" ;;
    *) echo "" ;;
  esac
}

to_eth() { awk -v w="$1" 'BEGIN { printf "%.6f", w / 1e18 }'; }
to_gwei() { awk -v w="$1" 'BEGIN { printf "%.3f", w / 1e9 }'; }
cost_eth() { awk -v g="$1" -v p="$2" 'BEGIN { printf "%.6f", g * p / 1e18 }'; }   # gas x wei, no 64-bit overflow

l1_chain="$(rpc_result eth_chainId '[]')" || die "L1_RPC_URL: $RPC_ERROR"
[ "$((l1_chain))" = "${L1_CHAIN_ID:?}" ] || die "L1_RPC_URL reports chain id $((l1_chain)), expected $L1_CHAIN_ID"

# ---------------------------------------------------------------------------------------------
# 1. Calldata from op-deployer (simulation only)
# ---------------------------------------------------------------------------------------------
n_tx=0
[ -f "$STATE" ] && n_tx="$(jq -r '(.DeploymentCalldata // []) | length' "$STATE" 2>/dev/null || echo 0)"
if [ "$n_tx" -gt 0 ]; then
  log "state.json already holds $n_tx deployment transaction(s); op-deployer is not re-run"
else
  log "op-deployer apply --deployment-target calldata (simulation against $L1_RPC_URL; nothing is sent)"
  DEPLOYER_PRIVATE_KEY="$deployer_pk" "$BIN" apply \
    --workdir "$WORKDIR" \
    --l1-rpc-url "$L1_RPC_URL" \
    --deployment-target calldata
  n_tx="$(jq -r '(.DeploymentCalldata // []) | length' "$STATE" 2>/dev/null || echo 0)"
  [ "$n_tx" -gt 0 ] || die "op-deployer produced no deployment calldata (is the chain already recorded as deployed in state.json?)"
fi

sys_cfg="$(jq -r --arg id "$chain_id_hex" '.opChainDeployments[] | select(.id == $id) | .SystemConfigProxy // .systemConfigProxyAddress // empty' "$STATE")"
[ -n "$sys_cfg" ] || die "state.json has no SystemConfigProxy for chain $chain_id_hex"
code="$(rpc_result eth_getCode "[\"$sys_cfg\",\"latest\"]")" || die "eth_getCode: $RPC_ERROR"
if [ "$code" != "0x" ] && [ -n "$code" ]; then
  die "SystemConfigProxy $sys_cfg already has code on L1: the contracts are deployed. Set startBlock in state.json by hand if deployment.json is missing."
fi

# ---------------------------------------------------------------------------------------------
# 2. Gas limits from the live node, dry run at those limits
# ---------------------------------------------------------------------------------------------
blk="$(rpc_result eth_getBlockByNumber '["latest",false]')" || die "eth_getBlockByNumber: $RPC_ERROR"
block_gas_limit=$(( $(printf '%s' "$blk" | jq -r .gasLimit) ))
amsterdam="$(printf '%s' "$blk" | jq -r 'has("blockAccessListHash")')"
base_fee_wei=$(( $(printf '%s' "$blk" | jq -r '.baseFeePerGas // "0x0"') ))
prio_wei="$(awk -v g="${TX_PRIORITY_GWEI:-2}" 'BEGIN { printf "%d", g * 1e9 }')"
max_fee_wei=$(( prio_wei + 2 * base_fee_wei + 1000000000 ))
exp_price_wei=$(( base_fee_wei + prio_wei ))
bal_eth="$(hex_to_eth "$(rpc_result eth_getBalance "[\"$deployer_addr\",\"latest\"]" || echo 0x0)")"

echo "Deployer:             $deployer_addr"
echo "Deployer balance:     $bal_eth ETH"
echo "L1 head:              block $(( $(printf '%s' "$blk" | jq -r .number) )), gas limit $block_gas_limit, Amsterdam rules: $amsterdam"
echo "L1 fees:              base fee $(to_gwei "$base_fee_wei") gwei, priority fee $(to_gwei "$prio_wei") gwei, fee cap $(to_gwei "$max_fee_wei") gwei"
echo "Contracts release:    ${OP_CONTRACTS_TAG}  op-deployer ${OP_DEPLOYER_VERSION}"
echo "Chain id:             ${CHAIN_ID}  SystemConfigProxy (predicted) $sys_cfg"
echo "Transactions:         $n_tx"
echo

total_gas=0
i=0
GAS_LIMITS=""
while [ "$i" -lt "$n_tx" ]; do
  to="$(jq -r ".DeploymentCalldata[$i].to // empty" "$STATE")"
  data="$(jq -r ".DeploymentCalldata[$i].data" "$STATE")"
  value="$(jq -r ".DeploymentCalldata[$i].value // \"0x0\"" "$STATE")"
  [ "$value" != "null" ] || value="0x0"
  if [ -n "$to" ]; then to_json="\"$to\""; kind="call $to"; else to_json="null"; kind="contract creation"; fi
  call_obj="{\"from\":\"$deployer_addr\",\"to\":$to_json,\"data\":\"$data\",\"value\":\"$value\"}"

  est=""
  if est_hex="$(rpc_result eth_estimateGas "[$call_obj]")"; then
    est=$(( est_hex ))
  else
    warn "tx $((i+1)): eth_estimateGas failed: $RPC_ERROR"
    hint="$(explain_revert "$RPC_ERROR")"; [ -z "$hint" ] || warn "$hint"
    warn "trying the block gas limit as the limit instead (providers often cap estimates at 50M; Tenderly's gateway allowed more)"
  fi
  if [ -n "$est" ]; then
    margin=$(( est / 20 )); [ "$margin" -ge 1000000 ] || margin=1000000
    gas=$(( est + margin ))
  else
    gas=$block_gas_limit
  fi
  [ "$gas" -le "$block_gas_limit" ] || gas=$block_gas_limit

  if ! rpc_result eth_call "[{\"from\":\"$deployer_addr\",\"to\":$to_json,\"data\":\"$data\",\"value\":\"$value\",\"gas\":\"$(printf '0x%x' "$gas")\"},\"latest\"]" >/dev/null; then
    hint="$(explain_revert "$RPC_ERROR")"
    die "tx $((i+1)) ($kind) reverts in eth_call with gas limit $gas: $RPC_ERROR${hint:+ -> $hint}. Nothing was sent."
  fi

  note=""
  if [ "$gas" -gt "$EIP7825_CAP" ]; then
    if [ "$amsterdam" = "true" ]; then
      note=" (above the EIP-7825 cap of $EIP7825_CAP; under EIP-8037 that cap applies to execution gas only)"
    else
      note=" (above the EIP-7825 cap of $EIP7825_CAP and the L1 does not show Amsterdam rules: the node will refuse this transaction)"
    fi
  fi
  printf 'tx %d: %s\n      estimate %s, gas limit %d, expected cost %s ETH, maximum %s ETH%s\n' \
    "$((i+1))" "$kind" "${est:-n/a}" "$gas" "$(cost_eth "${est:-$gas}" "$exp_price_wei")" "$(cost_eth "$gas" "$max_fee_wei")" "$note"
  GAS_LIMITS="$GAS_LIMITS $gas"
  total_gas=$(( total_gas + gas ))
  i=$((i+1))
done
echo
max_cost_eth="$(cost_eth "$total_gas" "$max_fee_wei")"
echo "Total gas limit $total_gas; maximum cost at the fee cap $max_cost_eth ETH (unused gas is refunded; the expected cost is gas used x (base fee + priority fee))."
if awk -v b="$bal_eth" -v c="$max_cost_eth" 'BEGIN { exit !(b < c) }'; then
  die "deployer balance $bal_eth ETH is below gas limit x fee cap ($max_cost_eth ETH); the node rejects such a transaction. Top up or lower TX_PRIORITY_GWEI."
fi

if [ "${YES:-0}" != "1" ]; then
  read -r -p "Send the deployment transaction(s) from $deployer_addr now? [yes/NO] " answer
  [ "$answer" = "yes" ] || die "aborted; nothing was sent"
fi

# ---------------------------------------------------------------------------------------------
# 3. Send and wait
# ---------------------------------------------------------------------------------------------
send_url="${SEND_RPC_URL:-$L1_RPC_URL}"
wait_receipt() { # wait_receipt <txhash>: prints the receipt JSON or fails after RECEIPT_TIMEOUT
  local h="$1" waited=0 r
  while :; do
    r="$(rpc "$send_url" eth_getTransactionReceipt "[\"$h\"]" 2>/dev/null | jq -c '.result // empty' 2>/dev/null || true)"
    if [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
    [ "$waited" -lt "${RECEIPT_TIMEOUT:-1200}" ] || return 1
    sleep 12; waited=$((waited + 12))
    log "waiting for inclusion of $h (${waited}s)"
  done
}

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tx_records="[]"
last_block=""
i=0
for gas in $GAS_LIMITS; do
  to="$(jq -r ".DeploymentCalldata[$i].to // empty" "$STATE")"
  data="$(jq -r ".DeploymentCalldata[$i].data" "$STATE")"
  value="$(jq -r ".DeploymentCalldata[$i].value // \"0x0\"" "$STATE")"
  [ "$value" != "null" ] || value="0x0"

  log "sending tx $((i+1)) with gas limit $gas via $send_url"
  set -- --rpc-url "$send_url" --private-key "$deployer_pk" --gas-limit "$gas" \
    --gas-price "$max_fee_wei" --priority-gas-price "$prio_wei" --async
  [ "$((value))" -eq 0 ] || set -- "$@" --value "$((value))"
  if [ -n "$to" ]; then
    tx_hash="$(cast send "$@" "$to" "$data" | tr -d '[:space:]')"
  else
    tx_hash="$(cast send "$@" --create "$data" | tr -d '[:space:]')"
  fi
  case "$tx_hash" in
    0x*) ;;
    *) die "cast send did not return a transaction hash: $tx_hash" ;;
  esac
  log "tx $((i+1)) sent: $tx_hash"

  receipt="$(wait_receipt "$tx_hash")" || die "no receipt for $tx_hash after ${RECEIPT_TIMEOUT:-1200}s; check the explorer before doing anything else (the transaction may still be pending)"
  status="$(printf '%s' "$receipt" | jq -r .status)"
  blk_num=$(( $(printf '%s' "$receipt" | jq -r .blockNumber) ))
  gas_used=$(( $(printf '%s' "$receipt" | jq -r .gasUsed) ))
  eff_price=$(( $(printf '%s' "$receipt" | jq -r '.effectiveGasPrice // "0x0"') ))
  if [ "$((status))" != "1" ]; then
    die "tx $tx_hash was included in block $blk_num but FAILED (status $status, gas used $gas_used). Investigate before retrying; the deployer paid for this transaction."
  fi
  log "tx $((i+1)) confirmed in block $blk_num: gas used $gas_used, effective price $(to_gwei "$eff_price") gwei, cost $(cost_eth "$gas_used" "$eff_price") ETH"
  tx_records="$(printf '%s' "$tx_records" | jq -c \
    --arg hash "$tx_hash" --arg to "${to:-}" --argjson block "$blk_num" \
    --argjson gasLimit "$gas" --argjson gasUsed "$gas_used" --argjson effectiveGasPriceWei "$eff_price" \
    '. + [{hash: $hash, to: (if $to == "" then null else $to end), blockNumber: $block, gasLimit: $gasLimit, gasUsed: $gasUsed, effectiveGasPriceWei: $effectiveGasPriceWei}]')"
  last_block="$blk_num"
  i=$((i+1))
done

# ---------------------------------------------------------------------------------------------
# 4. Record: startBlock in state.json, chain/out/deployment.json
# ---------------------------------------------------------------------------------------------
sb="$(rpc_result eth_getBlockByNumber "[\"$(printf '0x%x' "$last_block")\",false]")" || die "eth_getBlockByNumber $last_block: $RPC_ERROR"
sb_json="$(printf '%s' "$sb" | jq -c '{hash, parentHash, number, timestamp}')"
jq --arg id "$chain_id_hex" --argjson sb "$sb_json" \
  '(.opChainDeployments[] | select(.id == $id)).startBlock = $sb' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
log "startBlock in state.json set to L1 block $last_block ($(printf '%s' "$sb_json" | jq -r .hash))"

bal_after_eth="$(hex_to_eth "$(rpc_result eth_getBalance "[\"$deployer_addr\",\"latest\"]" || echo 0x0)")"
spent_eth="$(awk -v a="$bal_eth" -v b="$bal_after_eth" 'BEGIN { printf "%.6f", a - b }')"

mkdir -p "$OUT"
jq -n \
  --arg chainId "$CHAIN_ID" --arg l1ChainId "$L1_CHAIN_ID" \
  --arg deployer "$deployer_addr" --arg contracts "$OP_CONTRACTS_TAG" \
  --arg opDeployer "$OP_DEPLOYER_VERSION" --arg startedAt "$started_at" \
  --argjson startBlock "$sb_json" --argjson startBlockNumber "$last_block" --argjson txs "$tx_records" \
  --arg spentEth "$spent_eth" --arg amsterdam "$amsterdam" \
  '{chainId: ($chainId|tonumber), l1ChainId: ($l1ChainId|tonumber), deployer: $deployer,
    contractsRelease: $contracts, opDeployerVersion: $opDeployer, mode: "calldata-cast",
    startedAt: $startedAt, l1AmsterdamRules: ($amsterdam == "true"),
    transactions: $txs,
    startBlock: {number: $startBlockNumber, hash: $startBlock.hash, timestamp: $startBlock.timestamp},
    deployerSpentEth: ($spentEth|tonumber)}' \
  > "$OUT/deployment.json"

echo
echo "Deployment done. Deployer spent $spent_eth ETH; L1 start block $last_block."
echo "Record: chain/out/deployment.json (transaction hashes, gas). Next: make export"
