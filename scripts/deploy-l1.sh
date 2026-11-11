#!/usr/bin/env bash
# Deploy the Finchain L1 system contracts on Sepolia.
#
# DEPLOY_MODE=auto (default) | live | calldata
#   live      op-deployer apply broadcasts the transactions itself. Its gas limits come from
#             its built-in EVM simulation (Cancun-era rules) padded by 1.2x.
#   calldata  op-deployer only produces the calldata; scripts/deploy-l1-calldata.sh sizes the
#             gas on the live node and sends with cast. Required on an L1 that enforces
#             EIP-8037 (Sepolia since Glamsterdam, 2026-10-06), where the live mode's gas
#             check fails with DeploymentFailed() before anything is sent.
#   auto      calldata when the L1 head carries blockAccessListHash (Amsterdam rules), else live.
#
# Preconditions: chain/deployer/intent.toml reviewed, deployer key funded (make funding-table),
# L1_RPC_URL reachable. Writes chain/deployer/state.json and chain/out/deployment.json.
# This step spends Sepolia ETH and is not reversible; it asks for confirmation.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl
load_standard_env

WORKDIR="$FINCHAIN_ROOT/chain/deployer"
INTENT="$WORKDIR/intent.toml"
BIN="$(op_deployer_bin)"
[ -x "$BIN" ] || die "op-deployer binary missing; run: make op-deployer"
[ -f "$INTENT" ] || die "intent.toml missing; run: make intent"

l1_chain="$(rpc "$L1_RPC_URL" eth_chainId | jq -r .result)"
[ "$((l1_chain))" = "${L1_CHAIN_ID:?}" ] || die "L1_RPC_URL reports chain id $((l1_chain)), expected $L1_CHAIN_ID"

mode="${DEPLOY_MODE:-auto}"
if [ "$mode" = "auto" ]; then
  amsterdam="$(rpc "$L1_RPC_URL" eth_getBlockByNumber '["latest",false]' | jq -r '.result | has("blockAccessListHash")' 2>/dev/null || echo false)"
  if [ "$amsterdam" = "true" ]; then
    log "L1 head carries blockAccessListHash (Amsterdam rules, EIP-8037): using the calldata path"
    mode=calldata
  else
    mode=live
  fi
fi
if [ "$mode" = "calldata" ]; then
  exec bash "$FINCHAIN_ROOT/scripts/deploy-l1-calldata.sh"
fi
[ "$mode" = "live" ] || die "DEPLOY_MODE must be auto, live or calldata"

deployer_addr="$(key_field deployer address)"
deployer_pk="$(key_field deployer private_key)"

bal_hex="$(rpc "$L1_RPC_URL" eth_getBalance "[\"$deployer_addr\",\"latest\"]" | jq -r .result)"
bal_eth="$(hex_to_eth "$bal_hex")"
gas_price_wei="$(l1_gas_price_wei "$L1_RPC_URL")"
need_eth="$(awk -v g="${EST_DEPLOY_GAS:-60000000}" -v p="$gas_price_wei" 'BEGIN { printf "%.4f", g * p * 1.5 / 1e18 }')"

echo "Deployer:            $deployer_addr"
echo "Deployer balance:    $bal_eth ETH (Sepolia)"
echo "L1 gas price:        $(awk -v p="$gas_price_wei" 'BEGIN { printf "%.2f", p / 1e9 }') gwei"
echo "Estimated need:      $need_eth ETH (EST_DEPLOY_GAS x gas price x 1.5; replace the estimate with the measured value after this run)"
echo "Contracts release:   ${OP_CONTRACTS_TAG}  op-deployer ${OP_DEPLOYER_VERSION}"
echo "Chain id:            ${CHAIN_ID}"
echo

if awk -v b="$bal_eth" -v n="$need_eth" 'BEGIN { exit !(b < n) }'; then
  warn "deployer balance is below the estimate; apply may run out of funds midway (op-deployer can resume from state.json after top-up)"
fi

if [ "${YES:-0}" != "1" ]; then
  read -r -p "Run op-deployer apply on Sepolia now? [yes/NO] " answer
  [ "$answer" = "yes" ] || die "aborted"
fi

start_block=$(( $(rpc "$L1_RPC_URL" eth_blockNumber | jq -r .result) ))
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

DEPLOYER_PRIVATE_KEY="$deployer_pk" "$BIN" apply \
  --workdir "$WORKDIR" \
  --l1-rpc-url "$L1_RPC_URL"

end_block=$(( $(rpc "$L1_RPC_URL" eth_blockNumber | jq -r .result) ))
bal_after_eth="$(hex_to_eth "$(rpc "$L1_RPC_URL" eth_getBalance "[\"$deployer_addr\",\"latest\"]" | jq -r .result)")"
spent_eth="$(awk -v a="$bal_eth" -v b="$bal_after_eth" 'BEGIN { printf "%.6f", a - b }')"

mkdir -p "$FINCHAIN_ROOT/chain/out"
jq -n \
  --arg chainId "$CHAIN_ID" --arg l1ChainId "$L1_CHAIN_ID" \
  --arg deployer "$deployer_addr" --arg contracts "$OP_CONTRACTS_TAG" \
  --arg opDeployer "$OP_DEPLOYER_VERSION" --arg startedAt "$started_at" \
  --argjson startBlock "$start_block" --argjson endBlock "$end_block" \
  --arg spentEth "$spent_eth" \
  '{chainId: ($chainId|tonumber), l1ChainId: ($l1ChainId|tonumber), deployer: $deployer,
    contractsRelease: $contracts, opDeployerVersion: $opDeployer, mode: "live", startedAt: $startedAt,
    l1BlockRange: {from: $startBlock, to: $endBlock}, deployerSpentEth: ($spentEth|tonumber)}' \
  > "$FINCHAIN_ROOT/chain/out/deployment.json"

echo
echo "apply finished. Deployer spent about $spent_eth ETH over L1 blocks $start_block..$end_block."
echo "Record: chain/out/deployment.json. Next: make export"
