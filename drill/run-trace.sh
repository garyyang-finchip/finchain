#!/usr/bin/env bash
# M4: the trace self-check (docs/acceptance.md M4, "Trace self-check (run-trace) passes for a recent game";
# docs/proof-plan.md). `op-challenger run-trace` takes a recent L2 block of the live chain - the safe head at a
# finalized L1 block and its parent, from the host's own op-node - and runs op-program inside the Cannon VM from the
# given prestate until it has derived and executed that block; the run passes when the VM exits with the claim
# verified. This is the same program, VM and prestate family the public chain's `permissioned` games use, so a pass
# with the Finchain-embedding prestate (drill/prestate.sh) shows that prestate can prove a real Finchain block before
# any game implementation is changed.
#
# Two services feed it: a rollup RPC whose op-node keeps the safe-head database (--safedb.path; host B's does, it is
# what the challenger needs) and an L2 RPC with the debug namespace (host A's op-reth serves it privately; host B's
# public op-reth deliberately does not). The run joins the chosen host's compose network, reads only, and writes
# nothing but the datadir volume and the files named below. On host B the L2 RPC is therefore host A's op-reth over
# the private network - the address host B already uses as SEQUENCER_HTTP.
#
# Usage: drill/run-trace.sh [prestate.bin.gz] [a|b]
#   prestate: default the file in drill/out/prestates/ (name it when there are several); host: default b.
#   Environment: ROLLUP_RPC (default http://op-node:8547 in the stack network), L2_RPC_DEBUG (default: on host b the
#   SEQUENCER_HTTP of its env, on host a http://op-reth:8545), DRILL_NETWORK (default the host stack's compose
#   network; `host` on a scratch machine that reaches both RPCs over the private network and runs no stack),
#   RUN_TIMEOUT (default 3h, the VM timeout), L1_RPC_URL / L1_BEACON_URL (default the env files'), OP_PROGRAM_TAG
#   (default op-program/v1.9.0: the monorepo checkout the host is built from) or OP_PROGRAM_BIN (a built host).
#   Scratch host example: ROLLUP_RPC=http://<host B>:8547 L2_RPC_DEBUG=http://<host A>:8545 DRILL_NETWORK=host
# Outputs: drill/out/logs/run-trace-<date>.log (the service log), manifests/evidence/run-trace-<date>.json.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd docker jq openssl
PRESTATE="${1:-}"; HOST="${2:-b}"
case "$HOST" in a|b) ;; *) die "host must be a or b" ;; esac
load_standard_env
henv="$(host_env "$HOST")"; [ -f "$henv" ] && load_env "$henv"
ROLLUP_RPC="${ROLLUP_RPC:-http://op-node:8547}"
if [ -z "${L2_RPC_DEBUG:-}" ]; then
  if [ "$HOST" = b ]; then L2_RPC_DEBUG="${SEQUENCER_HTTP:?SEQUENCER_HTTP missing in $(host_env b): the L2 RPC with debug is the op-reth of host A}"; else L2_RPC_DEBUG="http://op-reth:8545"; fi
fi
L1_RPC_URL="${L1_RPC_URL:?L1_RPC_URL missing (.env or the host env file)}"; L1_BEACON_URL="${L1_BEACON_URL:?L1_BEACON_URL missing (.env or the host env file)}"
if [ -z "$PRESTATE" ]; then
  PRESTATE="$(find "$FINCHAIN_ROOT/drill/out/prestates" -maxdepth 1 -name '0x*.bin.gz' -print 2>/dev/null | sort | tail -1 || true)"
  [ -n "$PRESTATE" ] || die "no prestate under drill/out/prestates/; run make prestate first or name the file"
  [ "$(find "$FINCHAIN_ROOT/drill/out/prestates" -maxdepth 1 -name '0x*.bin.gz' 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || warn "several prestates under drill/out/prestates/; using $PRESTATE (name the file to choose)"
fi
[ -f "$PRESTATE" ] || die "prestate not found: $PRESTATE"
PRESTATE="$(cd "$(dirname "$PRESTATE")" && pwd)/$(basename "$PRESTATE")"
hash="$(basename "$PRESTATE" .bin.gz)"
REC="$CHAIN_DIR/out/chain-record.json"; [ -f "$REC" ] || die "chain record not found: $REC"
DGF="$(jq -r '.l1.DisputeGameFactoryProxy // empty' "$REC")"; [ -n "$DGF" ] || die "DisputeGameFactoryProxy missing in $REC"
network="${DRILL_NETWORK:-$STACK-${HOST}_default}"
[ "$network" = host ] || docker network inspect "$network" >/dev/null 2>&1 || die "compose network $network not found: is the host $HOST stack up on this machine? (DRILL_NETWORK=host on a scratch machine)"
IMAGE="${OP_CHALLENGER_IMAGE:?OP_CHALLENGER_IMAGE missing in versions.lock}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3h}"
LOGS="$FINCHAIN_ROOT/drill/out/logs"; mkdir -p "$LOGS" "$FINCHAIN_ROOT/drill/out/bin"

# The op-program host is the preimage server of the cannon and permissioned paths. The op-challenger image ships
# cannon and kona-host but not op-program, so the host is built once from the monorepo checkout of the prestate's
# tag (the one drill/prestate.sh cloned), inside the Go image that tag names, and mounted into the run.
OP_PROGRAM_TAG="${OP_PROGRAM_TAG:-op-program/v1.9.0}"
tagslug="$(printf '%s' "$OP_PROGRAM_TAG" | tr '/' '-')"
repo="$FINCHAIN_ROOT/drill/work/optimism-$tagslug"
OPP_BIN="${OP_PROGRAM_BIN:-$FINCHAIN_ROOT/drill/out/bin/op-program-$tagslug}"
if [ ! -x "$OPP_BIN" ]; then
  [ -d "$repo/op-program" ] || die "monorepo checkout not found at $repo (make prestate clones it); or set OP_PROGRAM_BIN to a built op-program host"
  go_version="$(grep -oE 'GO_VERSION=[0-9][^ ]*' "$repo/op-program/Makefile" | head -1 | cut -d= -f2)"
  [ -n "$go_version" ] || die "GO_VERSION not found in $repo/op-program/Makefile"
  log "building the op-program host from $OP_PROGRAM_TAG in golang:$go_version (a few minutes; log $LOGS/op-program-host-$tagslug.log)"
  docker run --rm -v "$repo:/src:ro" -v "$FINCHAIN_ROOT/drill/out/bin:/out" -e "OUT_OWNER=$(id -u):$(id -g)" -e "OUT_NAME=op-program-$tagslug" -e GOFLAGS=-buildvcs=false \
    "golang:$go_version" sh -c 'apk add --no-cache make gcc musl-dev linux-headers git >/dev/null && cp -r /src /app && cd /app/op-program && make op-program-host && cp bin/op-program "/out/$OUT_NAME" && chown "$OUT_OWNER" "/out/$OUT_NAME"' \
    >"$LOGS/op-program-host-$tagslug.log" 2>&1 || die "op-program host build failed; see $LOGS/op-program-host-$tagslug.log"
  [ -x "$OPP_BIN" ] || die "op-program host not produced at $OPP_BIN"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$FINCHAIN_ROOT/manifests/evidence"
logf="$LOGS/run-trace-$stamp.log"
name="finchain-drill-run-trace-$stamp"
# a throwaway signer: run-trace sends no transaction, the transaction manager only wants a key to exist.
# --cannon-prestate names the same file as --run: the configuration check wants a prestate source before the runner
# reads the run's own file.
throwaway="$(openssl rand -hex 32)"

log "run-trace on host $HOST: prestate $hash, network $network, rollup RPC $(rpc_label "$ROLLUP_RPC"), L2 debug RPC $(rpc_label "$L2_RPC_DEBUG")"
log "VM timeout $RUN_TIMEOUT; log $logf"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; t0="$(date +%s)"
docker run -d --name "$name" --network "$network" \
  -v "$CHAIN_DIR/out:/chain:ro" -v "$(dirname "$PRESTATE"):/prestates:ro" -v "finchain-drill-run-trace:/data" -v "$OPP_BIN:/usr/local/bin/op-program:ro" \
  --entrypoint op-challenger "$IMAGE" run-trace \
  --l1-eth-rpc "$L1_RPC_URL" --l1-beacon "$L1_BEACON_URL" \
  --rollup-rpc "$ROLLUP_RPC" --l2-eth-rpc "$L2_RPC_DEBUG" --l2-experimental-eth-rpc "$L2_RPC_DEBUG" \
  --game-factory-address "$DGF" --datadir /data --trace-type cannon \
  --cannon-bin /usr/local/bin/cannon --cannon-server /usr/local/bin/op-program \
  --cannon-rollup-config /chain/rollup.json --cannon-l2-genesis /chain/genesis.json \
  --cannon-prestate "/prestates/$(basename "$PRESTATE")" --run "cannon/finchain/file:/prestates/$(basename "$PRESTATE")" --vm-timeout "$RUN_TIMEOUT" \
  --private-key "$throwaway" --log.format json --log.level info >/dev/null
unset throwaway

# follow the log until the first verdict; run-trace itself loops forever
result=""; reason=""
while :; do
  docker logs "$name" >"$logf" 2>&1 || true
  if grep -q '"msg":"Successfully verified output root"' "$logf"; then result=PASS; reason="VM exited with the claim verified"; break; fi
  if grep -q '"msg":"Incorrect status code"' "$logf"; then result=FAIL; reason="VM exited but the claim was not verified"; break; fi
  if grep -q '"msg":"VM panicked"' "$logf"; then result=FAIL; reason="VM panicked"; break; fi
  if grep -q '"msg":"VM execution timed out"' "$logf"; then result=FAIL; reason="VM timed out after $RUN_TIMEOUT"; break; fi
  if grep -q '"msg":"Failed to run"' "$logf"; then result=FAIL; reason="setup failure: $(jq -r 'select(.msg=="Failed to run") | .err' <"$logf" 2>/dev/null | head -1 | cut -c1-300)"; break; fi
  if ! docker ps -q --no-trunc --filter "name=^/$name$" | grep -q .; then result=FAIL; reason="the container exited: $(tail -n 3 "$logf" | tr '\n' ' ' | cut -c1-300)"; break; fi
  sleep 20
done
docker rm -f "$name" >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - t0 ))

# what the run looked at, from its own log
inputs="$(jq -c 'select(.msg=="Using L1 head") | {l1Head: .num, l1HeadHash: .hash, disputeL1: .disputeL1}' <"$logf" 2>/dev/null | head -1)"; [ -n "$inputs" ] || inputs=null
l2="$(jq -c 'select(.msg=="Got sync status") | .status | {finalizedL1: .finalized_l1.number, safeL2: .safe_l2.number, finalizedL2: .finalized_l2.number}' <"$logf" 2>/dev/null | head -1)"; [ -n "$l2" ] || l2=null
claim="$(jq -c 'select(.l2Block != null and .claim != null) | {l2Block: .l2Block, claim: .claim, l2Head: .l2, l1: .l1}' <"$logf" 2>/dev/null | head -1)"; [ -n "$claim" ] || claim=null
ev="$FINCHAIN_ROOT/manifests/evidence/run-trace-$stamp.json"
jq -n --arg at "$started" --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson secs "$elapsed" --arg host "$HOST" --arg hash "$hash" --arg file "$(basename "$PRESTATE")" \
  --arg image "$IMAGE" --arg l1 "$(rpc_label "$L1_RPC_URL")" --arg dgf "$DGF" --argjson inputs "$inputs" --argjson sync "$l2" --argjson claim "$claim" \
  --arg result "$result" --arg reason "$reason" --arg logname "drill/out/logs/run-trace-$stamp.log" --argjson cid "${CHAIN_ID:-0}" \
  --arg rollup "$(rpc_label "$ROLLUP_RPC")" --arg l2src "$(rpc_label "$L2_RPC_DEBUG")" --arg opp "$OP_PROGRAM_TAG host built from source (sha256 $(sha256_of "$OPP_BIN" | cut -c1-16)...)" '
  {schema: "finchain.run-trace/1",
   acceptance: "M4: trace self-check (run-trace) passes for a recent game (docs/acceptance.md M4; docs/proof-plan.md)",
   environment: "public-testnet", chainId: $cid, host: $host, startedAt: $at, finishedAt: $end, seconds: $secs,
   what: "op-challenger run-trace: op-program executed inside the Cannon VM from the prestate below for one recent L2 block of the live chain (the safe head at a finalized L1 block and its parent, from the host op-node); PASS = the VM exited with the claim verified",
   prestate: {hash: $hash, file: $file, source: "drill/prestate.sh (manifests/evidence/prestate-<chainId>-<date>.json)"},
   image: $image, opProgramHost: $opp, l1: $l1, disputeGameFactory: $dgf, traceType: "cannon", rollupRpc: $rollup, l2Source: ($l2src + " (execution-witness path)"),
   inputs: {syncStatus: $sync, l1Head: $inputs, block: $claim},
   result: $result, reason: $reason, log: $logname}' > "$ev"
echo "run-trace $result: $reason (${elapsed}s)"
echo "record: $ev"
echo "log:    $logf"
[ "$result" = PASS ] || exit 3
