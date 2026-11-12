#!/usr/bin/env bash
# Finchain on its own: the EVM acceptance (docs/world.md, "Finchain on its own"; docs/acceptance.md M3-A).
# Through the public RPC, with an ordinary key and ordinary tooling, nothing of any application involved:
#   1. a plain L2 transfer (deployer key -> OWNER_ADDRESS, the owner's wallet address);
#   2. the deployment of FinchainProbe (chain/contracts/probe);
#   3. a write (set(<the deployment block number>)) and the event it emits;
#   4. the read-back: value(), writes(), the storage slot, the code hash against the build;
#   5. the record chain/out/evm-acceptance.json, which scripts/verify-evm.sh re-reads at a finalized block on host B.
#
# Usage: scripts/evm-acceptance.sh [l2-rpc=https://rpc.finchain.one] [transfer-eth=0.05]
#   env: YES=1 (no prompt), FORCE=1 (ignore an existing record), ROLE=deployer (the key used)

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk
load_standard_env
[ -n "${CAST_BIN:-}" ] || require_cmd docker

L2_RPC="${1:-https://rpc.finchain.one}"
TRANSFER_ETH="${2:-0.05}"
ROLE="${ROLE:-deployer}"
BUILD="$FINCHAIN_ROOT/chain/contracts/probe/build.json"
OUT="$FINCHAIN_ROOT/chain/out/evm-acceptance.json"
[ -f "$BUILD" ] || die "build record missing: $BUILD"
[ -n "${OWNER_ADDRESS:-}" ] || die "OWNER_ADDRESS is empty in .env (the transfer's recipient: an ordinary wallet address)"
if [ -f "$OUT" ] && [ "${FORCE:-0}" != "1" ]; then die "$OUT exists; FORCE=1 to run the acceptance again"; fi

from="$(key_field "$ROLE" address)"
pk="$(key_field "$ROLE" private_key)"
chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
[ "$((chain_hex))" = "${CHAIN_ID:?}" ] || die "L2 RPC $L2_RPC reports chain id $((chain_hex)), .env says $CHAIN_ID"
client="$(rpc "$L2_RPC" web3_clientVersion | jq -r '.result // "unknown"')"
bal_hex() { rpc "$L2_RPC" eth_getBalance "[\"$1\",\"latest\"]" | jq -r .result; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
rfield() { printf '%s' "$1" | jq -r ".$2"; }
rec() { printf '%s' "$1" | jq -c '{tx: .transactionHash, block: (.blockNumber | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d)), blockHash: .blockHash, gasUsed: (.gasUsed | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d)), effectiveGasPrice: .effectiveGasPrice, l1Fee: (.l1Fee // null), status: .status}'; }
send() { # <args...> -> receipt JSON with status checked
  local r
  r="$(cast send --rpc-url "$L2_RPC" --private-key "$pk" --json "$@")" || die "transaction failed"
  [ "$(rfield "$r" status)" = "0x1" ] || die "transaction reverted: $(rfield "$r" transactionHash)"
  printf '%s' "$r"
}
ROWS=""; FAILED=0
check() { # <name> <actual> <expected>
  if [ "$(lower "$2")" = "$(lower "$3")" ]; then echo "  ok   $1 = $2"; ROWS="$ROWS$1	pass	$2	$3
"; else echo "  FAIL $1 = $2 (expected $3)"; ROWS="$ROWS$1	fail	$2	$3
"; FAILED=1; fi
}

echo "L2 RPC:   $L2_RPC (chain id $((chain_hex)); $client)"
echo "key:      $from ($ROLE)  $(hex_to_eth "$(bal_hex "$from")") ETH"
echo "transfer: $TRANSFER_ETH ETH -> $OWNER_ADDRESS ($(hex_to_eth "$(bal_hex "$OWNER_ADDRESS")") ETH now)"
echo "contract: FinchainProbe ($(jq -r '.compiler.solc' "$BUILD"), runtime keccak $(jq -r .runtimeBytecodeKeccak "$BUILD"))"
if [ "${YES:-0}" != "1" ]; then
  read -r -p "Run the EVM acceptance now (one transfer, one deployment, one write)? [yes/NO] " answer
  [ "$answer" = "yes" ] || die "aborted; nothing was sent"
fi

log "1/4 plain transfer"
to_before="$(bal_hex "$OWNER_ADDRESS")"
r_tr="$(send --value "${TRANSFER_ETH}ether" "$OWNER_ADDRESS")"
to_after="$(bal_hex "$OWNER_ADDRESS")"
echo "  tx $(rfield "$r_tr" transactionHash) block $(( $(rfield "$r_tr" blockNumber) )); recipient $(hex_to_eth "$to_before") -> $(hex_to_eth "$to_after") ETH"
delta="$(jq -rn --arg a "$to_after" --arg b "$to_before" '
  def h: ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d);
  (($a | h) - ($b | h)) / 1e18')"
check "transfer.recipientDelta" "$(awk -v d="$delta" 'BEGIN { printf "%.6f", d }')" "$(awk -v d="$TRANSFER_ETH" 'BEGIN { printf "%.6f", d }')"

log "2/4 deployment"
r_dep="$(send --create "$(jq -r .creationBytecode "$BUILD")")"
probe="$(rfield "$r_dep" contractAddress)"
deploy_block=$(( $(rfield "$r_dep" blockNumber) ))
echo "  FinchainProbe $probe (tx $(rfield "$r_dep" transactionHash), block $deploy_block, gas $(( $(rfield "$r_dep" gasUsed) )))"
code_hash="$(cast keccak "$(rpc "$L2_RPC" eth_getCode "[\"$probe\",\"latest\"]" | jq -r .result)")"
check "probe.runtimeKeccak" "$code_hash" "$(jq -r .runtimeBytecodeKeccak "$BUILD")"
check "probe.deployer" "$(cast call "$probe" 'deployer()(address)' --rpc-url "$L2_RPC")" "$from"

log "3/4 write: set($deploy_block)"
r_set="$(send "$probe" "$(cast calldata 'set(uint256)' "$deploy_block")")"
echo "  tx $(rfield "$r_set" transactionHash) block $(( $(rfield "$r_set" blockNumber) ))"
topic="$(cast keccak 'Set(address,uint256,uint256)')"
check "set.eventTopic" "$(printf '%s' "$r_set" | jq -r '.logs[0].topics[0] // "none"')" "$topic"
check "set.eventEmitter" "$(printf '%s' "$r_set" | jq -r '.logs[0].address // "none"')" "$probe"

log "4/4 read-back"
check "value()" "$(cast call "$probe" 'value()(uint256)' --rpc-url "$L2_RPC")" "$deploy_block"
check "writes()" "$(cast call "$probe" 'writes()(uint256)' --rpc-url "$L2_RPC")" "1"
slot0="$(rpc "$L2_RPC" eth_getStorageAt "[\"$probe\",\"0x0\",\"latest\"]" | jq -r .result)"
check "storage.slot0" "$(( slot0 ))" "$deploy_block"
[ "$FAILED" = "0" ] || die "a check failed; the record is not written"

last_block_hex="$(rfield "$r_set" blockNumber)"
block_hash="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$last_block_hex\",false]" | jq -r .result.hash)"
checks_json="$(printf '%s' "$ROWS" | awk -F'\t' 'NF >= 3 { printf "{\"check\":\"%s\",\"result\":\"%s\",\"value\":\"%s\",\"expected\":\"%s\"}\n", $1, $2, $3, $4 }' | jq -s '.')"
mkdir -p "$(dirname "$OUT")"
jq -n --argjson chainId "$CHAIN_ID" --arg rpc "$L2_RPC" --arg client "$client" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from "$from" --arg role "$ROLE" --arg to "$OWNER_ADDRESS" --arg amount "$TRANSFER_ETH" --argjson tr "$(rec "$r_tr")" \
  --arg probe "$probe" --argjson dep "$(rec "$r_dep")" --argjson set "$(rec "$r_set")" --argjson value "$deploy_block" \
  --arg codeHash "$code_hash" --argjson build "$(jq -c '{compiler, runtimeBytecodeKeccak, sourceSha256}' "$BUILD")" \
  --argjson block "$(( last_block_hex ))" --arg blockHash "$block_hash" --argjson checks "$checks_json" '
  { schema: "finchain.evm-acceptance/1", acceptance: "M3-A Finchain on its own: transfer, deploy, write, read through the public RPC",
    chainId: $chainId, rpc: $rpc, client: $client, recordedAt: $at,
    transfer: { from: $from, role: $role, to: $to, amountEth: $amount, receipt: $tr },
    contract: { name: "FinchainProbe", address: $probe, build: $build, runtimeCodeKeccak: $codeHash, deployment: $dep },
    write: { call: "set(uint256)", value: $value, receipt: $set },
    completion: { number: $block, hash: $blockHash },
    checks: $checks,
    note: "Nothing here belongs to a covenant or to an agent runtime: an ordinary key, cast, the public endpoint. scripts/verify-evm.sh re-reads this record on host B at a finalized block." }' > "$OUT"
echo
echo "record: $OUT"
echo "  transfer tx   $(rfield "$r_tr" transactionHash)"
echo "  FinchainProbe $probe (deployed in block $deploy_block, value $deploy_block written in block $(( last_block_hex )))"
echo "Commit chain/out/evm-acceptance.json, then on host B: make verify-evm (after the completion block is finalized, about 20 minutes)."
