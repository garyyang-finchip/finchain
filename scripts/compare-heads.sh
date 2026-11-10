#!/usr/bin/env bash
# Compare block hash and state root between two Finchain execution endpoints at the same
# height, and show each op-node's unsafe/safe/finalized heads.
#
# Usage: scripts/compare-heads.sh <rpc-a> <rpc-b> [height|safe|finalized] [opnode-rpc-a] [opnode-rpc-b]
# Example: scripts/compare-heads.sh http://100.64.0.1:8545 http://127.0.0.1:8545 finalized \
#                                   http://100.64.0.1:8547 http://127.0.0.1:8547

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl

A="${1:?rpc-a}"; B="${2:?rpc-b}"; TAG="${3:-finalized}"
NA="${4:-}"; NB="${5:-}"

sync_status() { # <op-node rpc>
  rpc "$1" optimism_syncStatus | jq -r '.result | "unsafe=\(.unsafe_l2.number) safe=\(.safe_l2.number) finalized=\(.finalized_l2.number) l1_head=\(.head_l1.number) l1_finalized=\(.finalized_l1.number)"'
}

if [ -n "$NA" ]; then echo "op-node A: $(sync_status "$NA")"; fi
if [ -n "$NB" ]; then echo "op-node B: $(sync_status "$NB")"; fi

# Resolve the height: a number, or a tag resolved on B (the verifier), then fetched on both.
case "$TAG" in
  safe|finalized|latest)
    height_hex="$(rpc "$B" eth_getBlockByNumber "[\"$TAG\",false]" | jq -r .result.number)"
    ;;
  *) height_hex="$(printf '0x%x' "$TAG")" ;;
esac

blk_a="$(rpc "$A" eth_getBlockByNumber "[\"$height_hex\",false]" | jq -c '.result | {number, hash, stateRoot, timestamp}')"
blk_b="$(rpc "$B" eth_getBlockByNumber "[\"$height_hex\",false]" | jq -c '.result | {number, hash, stateRoot, timestamp}')"

echo "height $((height_hex)) ($TAG on B)"
echo "A: $blk_a"
echo "B: $blk_b"
if [ "$(echo "$blk_a" | jq -r .hash)" = "$(echo "$blk_b" | jq -r .hash)" ] && [ "$(echo "$blk_a" | jq -r .stateRoot)" = "$(echo "$blk_b" | jq -r .stateRoot)" ]; then
  echo "RESULT: MATCH (block hash and state root identical)"
else
  echo "RESULT: MISMATCH"
  exit 2
fi
