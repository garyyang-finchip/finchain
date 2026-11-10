#!/usr/bin/env bash
# Deploy the Finchain L1 system contracts on Sepolia with op-deployer apply.
#
# Preconditions: chain/deployer/intent.toml reviewed, deployer key funded (make funding-table),
# L1_RPC_URL reachable. Writes chain/deployer/state.json and chain/out/deployment.json.
# This step spends Sepolia ETH and is not reversible; it asks for confirmation.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl docker
load_standard_env

WORKDIR="$FINCHAIN_ROOT/chain/deployer"
INTENT="$WORKDIR/intent.toml"
BIN="$(op_deployer_bin)"
[ -x "$BIN" ] || die "op-deployer binary missing; run: make op-deployer"
[ -f "$INTENT" ] || die "intent.toml missing; run: make intent"

deployer_addr="$(key_field deployer address)"
deployer_pk="$(key_field deployer private_key)"

l1_chain="$(rpc "$L1_RPC_URL" eth_chainId | jq -r .result)"
[ "$((l1_chain))" = "${L1_CHAIN_ID:?}" ] || die "L1_RPC_URL reports chain id $((l1_chain)), expected $L1_CHAIN_ID"

bal_hex="$(rpc "$L1_RPC_URL" eth_getBalance "[\"$deployer_addr\",\"latest\"]" | jq -r .result)"
bal_wei=$((bal_hex))
bal_eth="$(awk -v w="$bal_wei" 'BEGIN { printf "%.4f", w / 1e18 }')"
gas_price_wei=$(( $(rpc "$L1_RPC_URL" eth_gasPrice | jq -r .result) ))
need_eth="$(awk -v g="${EST_DEPLOY_GAS:-40000000}" -v p="$gas_price_wei" 'BEGIN { printf "%.4f", g * p * 1.5 / 1e18 }')"

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

"$BIN" apply \
  --workdir "$WORKDIR" \
  --l1-rpc-url "$L1_RPC_URL" \
  --private-key "$deployer_pk"

end_block=$(( $(rpc "$L1_RPC_URL" eth_blockNumber | jq -r .result) ))
bal_after=$(( $(rpc "$L1_RPC_URL" eth_getBalance "[\"$deployer_addr\",\"latest\"]" | jq -r .result) ))
spent_eth="$(awk -v a="$bal_wei" -v b="$bal_after" 'BEGIN { printf "%.6f", (a - b) / 1e18 }')"

mkdir -p "$FINCHAIN_ROOT/chain/out"
jq -n \
  --arg chainId "$CHAIN_ID" --arg l1ChainId "$L1_CHAIN_ID" \
  --arg deployer "$deployer_addr" --arg contracts "$OP_CONTRACTS_TAG" \
  --arg opDeployer "$OP_DEPLOYER_VERSION" --arg startedAt "$started_at" \
  --argjson startBlock "$start_block" --argjson endBlock "$end_block" \
  --arg spentEth "$spent_eth" \
  '{chainId: ($chainId|tonumber), l1ChainId: ($l1ChainId|tonumber), deployer: $deployer,
    contractsRelease: $contracts, opDeployerVersion: $opDeployer, startedAt: $startedAt,
    l1BlockRange: {from: $startBlock, to: $endBlock}, deployerSpentEth: ($spentEth|tonumber)}' \
  > "$FINCHAIN_ROOT/chain/out/deployment.json"

echo
echo "apply finished. Deployer spent about $spent_eth ETH over L1 blocks $start_block..$end_block."
echo "Record: chain/out/deployment.json. Next: make export"
