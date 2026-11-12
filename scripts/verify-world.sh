#!/usr/bin/env bash
# Independent check of the covenant World address book against the chain: every contract listed in a
# manifest `covenantWorld` section (and its identity root) must hold code whose keccak256 equals the
# recorded codeHash at one fixed block, the completing block must still be canonical, and the block
# the section was verified at must be at or below the chain's `finalized` head.
#
# Usage: scripts/verify-world.sh <covenant-world.json> [l2-rpc=https://rpc.finchain.one] [block=finalized]
# Reads the chain only (curl + cast keccak); needs no FOGA checkout, no bundle and no key. The report
# lands in manifests/evidence/world-verify-<block>.json. Exit 3 on any mismatch.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl
load_env "$FINCHAIN_ROOT/versions.lock"
[ -n "${CAST_BIN:-}" ] || require_cmd docker

SECTION="${1:-}"
[ -n "$SECTION" ] || die "usage: scripts/verify-world.sh <covenant-world.json> [l2-rpc] [block] (make verify-world SECTION=manifests/covenant-world-<name>.json ...)"
L2_RPC="${2:-https://rpc.finchain.one}"
AT="${3:-finalized}"
[ -f "$SECTION" ] || die "not found: $SECTION"

case "$AT" in
  finalized|safe|latest) block_hex="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$AT\",false]" | jq -r .result.number)" ;;
  0x*) block_hex="$AT" ;;
  *) block_hex="$(printf '0x%x' "$AT")" ;;
esac
[ -n "$block_hex" ] && [ "$block_hex" != "null" ] || die "could not resolve block $AT on $L2_RPC"
block=$(( block_hex ))
chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
echo "chain $((chain_hex)) via $L2_RPC; checking at block $block ($AT)"

rows=""; failed=0; total=0
check_contract() { # <name> <address> <expected keccak>
  local code actual verdict
  code="$(rpc "$L2_RPC" eth_getCode "[\"$2\",\"$block_hex\"]" | jq -r '.result // "0x"')"
  if [ "$code" = "0x" ]; then actual="0x (no code)"; else actual="$(cast keccak "$code")"; fi
  if [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')" ]; then verdict=match; else verdict=MISMATCH; failed=1; fi
  total=$((total + 1))
  printf '  %-10s %-40s %s\n' "$verdict" "$1" "$2"
  rows="$rows{\"name\":\"$1\",\"address\":\"$2\",\"expected\":\"$3\",\"actual\":\"$actual\",\"result\":\"$verdict\"},"
}

echo "== identity root"
while IFS=$'\t' read -r name addr hash; do
  [ -n "$name" ] && check_contract "$name" "$addr" "$hash"
done < <(jq -r '.identityRoot.contracts[]? | [.name, .address, .codeHash] | @tsv' "$SECTION")

echo "== covenant World contracts"
while IFS=$'\t' read -r name addr hash; do
  [ -n "$name" ] && check_contract "$name" "$addr" "$hash"
done < <(jq -r '.contracts[]? | [.name, .address, .codeHash] | @tsv' "$SECTION")

echo "== blocks"
completion_n="$(jq -r '.completionBlock.number // empty' "$SECTION")"; completion_h="$(jq -r '.completionBlock.hash // empty' "$SECTION")"
blocks_ok=1
if [ -n "$completion_n" ] && [ "$completion_n" != "0" ]; then
  onchain="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$(printf '0x%x' "$completion_n")\",false]" | jq -r '.result.hash // empty')"
  if [ "$onchain" = "$completion_h" ]; then echo "  match      completionBlock $completion_n $completion_h"; else echo "  MISMATCH   completionBlock $completion_n recorded $completion_h, chain $onchain"; blocks_ok=0; fi
  [ "$completion_n" -le "$block" ] || { echo "  NOT YET    completionBlock $completion_n is above the checked block $block"; blocks_ok=0; }
else
  echo "  missing    completionBlock"; blocks_ok=0
fi
finalized_n=$(( $(rpc "$L2_RPC" eth_getBlockByNumber '["finalized",false]' | jq -r .result.number) ))
block_hash="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$block_hex\",false]" | jq -r '.result.hash // empty')"
verified_n="$(jq -r '.verifiedAt.number // empty' "$SECTION")"; verified_h="$(jq -r '.verifiedAt.hash // empty' "$SECTION")"
if [ -n "$verified_n" ] && [ "$verified_n" != "0" ]; then
  onchain="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$(printf '0x%x' "$verified_n")\",false]" | jq -r '.result.hash // empty')"
  if [ "$onchain" = "$verified_h" ] && [ "$verified_n" -le "$finalized_n" ]; then echo "  match      verifiedAt $verified_n $verified_h (finalized head $finalized_n)"; else echo "  MISMATCH   verifiedAt $verified_n recorded $verified_h, chain $onchain, finalized head $finalized_n"; blocks_ok=0; fi
elif [ "$block" -le "$finalized_n" ]; then
  echo "  candidate  verifiedAt not set yet; this check at block $block $block_hash (finalized head $finalized_n) is the candidate: pass this report to scripts/world-manifest.sh"
else
  echo "  NOT YET    verifiedAt not set and the checked block $block is above the finalized head $finalized_n; check again at finalized"; blocks_ok=0
fi

result="MATCH"; [ "$failed" = "0" ] && [ "$blocks_ok" = "1" ] || result="MISMATCH"
mkdir -p "$FINCHAIN_ROOT/manifests/evidence"
out="$FINCHAIN_ROOT/manifests/evidence/world-verify-$block.json"
jq -n --arg section "$SECTION" --arg rpc "$L2_RPC" --argjson chainId "$((chain_hex))" --argjson block "$block" --arg blockHash "$block_hash" --arg tag "$AT" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson finalized "$finalized_n" --argjson rows "[${rows%,}]" --arg result "$result" --argjson blocksOk "$blocks_ok" '
  { acceptance: "M3-C address book vs chain code", section: $section, rpc: $rpc, chainId: $chainId, checkedAt: $at, block: $block, blockHash: $blockHash, tag: $tag, finalizedHead: $finalized,
    contracts: $rows, blocksCanonical: ($blocksOk == 1), result: $result,
    method: "eth_getCode at the fixed block, keccak256 compared with the recorded codeHash; completion and verification blocks compared with the canonical chain" }' > "$out"
echo "RESULT: $result ($total contracts); report $out"
[ "$result" = "MATCH" ] || exit 3
