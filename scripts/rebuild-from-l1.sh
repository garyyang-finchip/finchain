#!/usr/bin/env bash
# Acceptance item "rebuild from L1 only" (docs/acceptance.md, M2):
# wipe host B's execution and rollup-node data, restart with p2p peers removed so that
# every block is derived from L1 data, wait until the finalized head reaches a target,
# and compare block hash and state root with a reference endpoint.
#
# Run on host B. Usage:
#   scripts/rebuild-from-l1.sh <target-l2-height> <reference-rpc> [profile]
# The reference endpoint is only used for the final comparison, never as a data source.
# RESUME=1 skips the wipe and restart and only waits and compares (for a run that was
# interrupted after the stack had already been wiped and restarted in L1-only mode).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd docker jq curl
load_env "$FINCHAIN_ROOT/versions.lock"

TARGET="${1:?target L2 height}"
REF="${2:?reference execution RPC for comparison}"
PROFILE="${3:-demo}"
load_env "$FINCHAIN_ROOT/.env" "$FINCHAIN_ROOT/profiles/${PROFILE}.env" "$FINCHAIN_ROOT/node-b/.env"

COMPOSE=(docker compose -f "$FINCHAIN_ROOT/node-b/docker-compose.yml"
         --env-file "$FINCHAIN_ROOT/versions.lock"
         --env-file "$FINCHAIN_ROOT/profiles/${PROFILE}.env"
         --env-file "$FINCHAIN_ROOT/node-b/.env")

LOCAL_RPC="http://${B_BIND_IP}:8545"
LOCAL_NODE="http://${B_BIND_IP}:8547"

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "${RESUME:-0}" = "1" ]; then
  log "RESUME=1: keeping the current (already wiped, L1-only) stack; waiting and comparing only"
else
  log "stopping host B stack and removing execution + rollup-node volumes"
  "${COMPOSE[@]}" down
  docker volume rm -f finchain-b_reth-data finchain-b_op-node-data >/dev/null

  log "starting with P2P_STATIC_PEERS cleared (L1-only derivation)"
  P2P_STATIC_PEERS="" "${COMPOSE[@]}" up -d op-reth op-node
fi

log "waiting for finalized head >= $TARGET (this takes as long as L1 finality and derivation need)"
while :; do
  # op-node answers only once it is up; a failed call counts as "not yet", never as an error
  fin="$(rpc "$LOCAL_NODE" optimism_syncStatus 2>/dev/null | jq -r '.result.finalized_l2.number // 0' 2>/dev/null || true)"
  case "$fin" in ''|*[!0-9]*) fin=0 ;; esac
  printf '\r  finalized=%s  (%s)' "$fin" "$(date -u +%H:%M:%SZ)" >&2
  if [ "$fin" -ge "$TARGET" ]; then echo >&2; break; fi
  sleep 20
done

h="$(printf '0x%x' "$TARGET")"
local_blk="$(rpc "$LOCAL_RPC" eth_getBlockByNumber "[\"$h\",false]" | jq -c '.result | {number, hash, stateRoot}')"
ref_blk="$(rpc "$REF" eth_getBlockByNumber "[\"$h\",false]" | jq -c '.result | {number, hash, stateRoot}')"

result="MISMATCH"
if [ "$(echo "$local_blk" | jq -r .hash)" = "$(echo "$ref_blk" | jq -r .hash)" ] && \
   [ "$(echo "$local_blk" | jq -r .stateRoot)" = "$(echo "$ref_blk" | jq -r .stateRoot)" ]; then
  result="MATCH"
fi

mkdir -p "$FINCHAIN_ROOT/manifests/evidence"
rec="$FINCHAIN_ROOT/manifests/evidence/rebuild-from-l1-$(date -u +%Y%m%dT%H%M%SZ).json"
jq -n --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson target "$TARGET" --argjson local "$local_blk" --argjson ref "$ref_blk" --arg result "$result" \
  --arg l1 "$(printf '%s' "$L1_RPC_URL" | sed -E 's|^(https?://[^/]+).*|\1|')" \
  '{acceptance: "M2 rebuild-from-L1", startedAt: $started, finishedAt: $finished, l1DataSourceHost: $l1,
    targetHeight: $target, rebuilt: $local, reference: $ref, result: $result,
    method: "empty data volumes, no p2p peers, derivation from public genesis/rollup config and L1 data only"}' \
  > "$rec"
echo "RESULT: $result  (record: $rec)"

log "restoring the configured static peers"
"${COMPOSE[@]}" up -d
[ "$result" = "MATCH" ] || exit 2
