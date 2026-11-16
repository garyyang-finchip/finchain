#!/usr/bin/env bash
# Evidence for the end of the op-program route (docs/proof-plan.md): the raw L1 header, as the RPC served it, of the
# block on which `op-challenger run-trace` with op-program/v1.9.0 stopped with
#   failed to verify block hash: computed 0x... but RPC said 0x...
# The record keeps the complete eth_getBlockByHash response and the node's web3_clientVersion verbatim, names the
# header fields that version of op-program does not model (so that its recomputed hash cannot match), and the digests
# of the files the values came from. Nothing in it is derived from a document; everything is the RPC's own answer.
#
# Usage: drill/l1-header-evidence.sh [BLOCK_HASH]
#   The raw answers are expected in drill/out/logs/l1-header-<number>.json and l1-client-version.json (see
#   drill/README.md for the two curl commands that produce them). When they are missing and L1_RPC_URL is set, the
#   script fetches them; the endpoint is recorded as scheme and host only.
#   COMPUTED_HASH: the hash op-program computed (from the run-trace log of the failed run when it is under
#   drill/out/logs/, else from the environment).
# Output: manifests/evidence/l1-header-<number>-<date>.json

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd jq
LOGS="$FINCHAIN_ROOT/drill/out/logs"; mkdir -p "$LOGS" "$FINCHAIN_ROOT/manifests/evidence"
BLOCK_HASH="${1:-${BLOCK_HASH:-}}"

# the saved raw answer, or the one for BLOCK_HASH
raw=""
if [ -n "$BLOCK_HASH" ]; then
  raw="$(grep -l -i "\"hash\": *\"$BLOCK_HASH\"" "$LOGS"/l1-header-*.json 2>/dev/null | head -1 || true)"
else
  raw="$(find "$LOGS" -maxdepth 1 -name 'l1-header-*.json' -print 2>/dev/null | sort | tail -1 || true)"
fi
if [ -z "$raw" ]; then
  [ -n "$BLOCK_HASH" ] || die "no drill/out/logs/l1-header-<number>.json; name the block hash to fetch it (L1_RPC_URL in the environment)"
  [ -n "${L1_RPC_URL:-}" ] || { [ -f "$FINCHAIN_ROOT/.env$ENV_SUFFIX" ] && load_env "$FINCHAIN_ROOT/.env$ENV_SUFFIX"; }
  [ -n "${L1_RPC_URL:-}" ] || die "L1_RPC_URL not set and no saved answer for $BLOCK_HASH"
  num_hex="$(rpc "$L1_RPC_URL" eth_getBlockByHash "[\"$BLOCK_HASH\",false]" | jq -r '.result.number // empty')"
  [ -n "$num_hex" ] || die "the endpoint $(rpc_label "$L1_RPC_URL") has no block $BLOCK_HASH"
  raw="$LOGS/l1-header-$((num_hex)).json"
  rpc "$L1_RPC_URL" eth_getBlockByHash "[\"$BLOCK_HASH\",false]" | jq . > "$raw"
  rpc "$L1_RPC_URL" web3_clientVersion '[]' | jq . > "$LOGS/l1-client-version.json"
  log "fetched $raw and $LOGS/l1-client-version.json from $(rpc_label "$L1_RPC_URL")"
fi
jq -e '.result.hash and .result.number' "$raw" >/dev/null 2>&1 || die "$raw is not an eth_getBlockByHash answer"
client_file="$LOGS/l1-client-version.json"
client="$(jq -r '.result // "unknown"' "$client_file" 2>/dev/null || echo unknown)"

hash="$(jq -r '.result.hash' "$raw")"; number=$(( $(jq -r '.result.number' "$raw") ))
# the two header fields op-program/v1.9.0 (op-service/sources/types.go at that tag) does not carry
bal="$(jq -r '.result.blockAccessListHash // empty' "$raw")"; slot="$(jq -r '.result.slotNumber // empty' "$raw")"
missing_in_client='["blockAccessListHash","slotNumber"]'
present="$(jq -c --argjson m "$missing_in_client" '[.result | keys[] | select(IN($m[]))]' "$raw")"

# the hash op-program computed: the run-trace log of the failed run, else the environment
computed="${COMPUTED_HASH:-}"; runlog=""
if [ -z "$computed" ]; then
  runlog="$(grep -l -F "but RPC said $hash" "$LOGS"/run-trace-*.log 2>/dev/null | head -1 || true)"
  [ -z "$runlog" ] || computed="$(grep -o -E "computed 0x[0-9a-f]{64} but RPC said $hash" "$runlog" | head -1 | awk '{print $2}')"
fi
runlog_rec=null
[ -z "$runlog" ] || runlog_rec="$(jq -cn --arg f "drill/out/logs/$(basename "$runlog")" --arg s "$(sha256_of "$runlog")" '{file: $f, sha256: $s}')"

# the op-program checkout the failed run used, when it is still there: its header type lacks the two fields
opp_rec=null
opp_repo="$FINCHAIN_ROOT/drill/work/optimism-op-program-v1.9.0"
if [ -f "$opp_repo/op-service/sources/types.go" ]; then
  opp_rec="$(jq -cn --arg c "$(git -C "$opp_repo" rev-parse HEAD 2>/dev/null || echo unknown)" \
    --argjson bal "$(grep -c 'BlockAccessListHash' "$opp_repo/op-service/sources/types.go" || true)" \
    --argjson slot "$(grep -c 'SlotNumber' "$opp_repo/op-service/sources/types.go" || true)" \
    '{tag: "op-program/v1.9.0", commit: $c, file: "op-service/sources/types.go", occurrences: {BlockAccessListHash: $bal, SlotNumber: $slot}}')"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ev="$FINCHAIN_ROOT/manifests/evidence/l1-header-$number-$stamp.json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson number "$number" --arg hash "$hash" --arg computed "$computed" \
  --arg bal "$bal" --arg slot "$slot" --argjson present "$present" --argjson missing "$missing_in_client" \
  --slurpfile rawb "$raw" --arg rawsha "$(sha256_of "$raw")" --arg rawname "drill/out/logs/$(basename "$raw")" \
  --arg client "$client" --arg csha "$( [ -f "$client_file" ] && sha256_of "$client_file" || echo "")" \
  --argjson runlog "$runlog_rec" --argjson opp "$opp_rec" '
  {schema: "finchain.l1-header/1",
   purpose: "why the op-program route of M4 ended: the L1 header the public Sepolia node serves carries fields the pinned op-program release does not model, so its recomputed block hash cannot match the node (docs/proof-plan.md)",
   environment: "public-testnet", recordedAt: $at, l1ChainId: 11155111,
   block: {number: $number, hash: $hash, timestamp: ($rawb[0].result.timestamp | if type == "string" then (ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d)) else . end),
           parentHash: $rawb[0].result.parentHash, stateRoot: $rawb[0].result.stateRoot},
   headerFieldsNotInOpProgram: {fields: $missing, presentInAnswer: $present, blockAccessListHash: $bal, slotNumber: $slot,
                                 note: "EIP-7928 block-level access lists and EIP-7843 slot numbers (the Amsterdam upgrade) add these header fields; op-program/v1.9.0 predates them, op-challenger/v1.9.6 has them (op-service/sources/types.go of each tag)"},
   opProgramComputedHash: (if $computed == "" then null else $computed end),
   failedRun: {log: $runlog, message: ("failed to verify block hash: computed " + (if $computed == "" then "<unknown>" else $computed end) + " but RPC said " + $hash)},
   opProgramCheckout: $opp,
   node: {web3_clientVersion: $client, file: "drill/out/logs/l1-client-version.json", sha256: $csha},
   raw: {method: "eth_getBlockByHash", params: [$hash, false], file: $rawname, sha256: $rawsha, response: $rawb[0]}}' > "$ev"
echo "block $number $hash: fields op-program/v1.9.0 lacks and the node serves: $present (blockAccessListHash $bal, slotNumber $slot); node $client"
echo "record: $ev"
