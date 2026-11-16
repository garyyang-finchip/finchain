#!/usr/bin/env bash
# M4 K2: the trace self-check (docs/acceptance.md M4, "Trace self-check (run-trace) passes for a recent game";
# docs/proof-plan.md K2). `op-challenger run-trace` takes a recent L2 block of the live chain - the safe head at a
# finalized L1 block and its parent, from the host's own op-node - and runs the fault-proof client inside the Cannon
# VM from the given prestate until it has derived and executed that block; the run passes when the VM exits with the
# claim verified. A pass with the Finchain-embedding prestate (drill/prestate.sh) shows that prestate proves a real
# Finchain block before any game implementation is changed.
#
# TRACE=cannon-kona (default): kona-client in the VM, kona-host (shipped in the op-challenger image) as the preimage
#   server - the path of the cannon-kona game type (8, CANNON_KONA) that the devnet drill (K3) will install.
# TRACE=cannon: op-program in the VM with the op-program host built from source; kept for the record of the first
#   attempt (docs/proof-plan.md: that client cannot follow the current Sepolia L1).
#
# Two services feed it: a rollup RPC whose op-node keeps the safe-head database (--safedb.path; host B's does, it is
# what the challenger needs) and an L2 RPC with the debug namespace (host A's op-reth serves it privately; host B's
# public op-reth deliberately does not). The run joins the chosen host's compose network, reads only, and writes
# nothing but the datadir volume and the files named below. On host B the L2 RPC is therefore host A's op-reth over
# the private network - the address host B already uses as SEQUENCER_HTTP.
#
# Usage: drill/run-trace.sh [prestate.bin.gz] [a|b]
#   prestate: default the file in drill/out/prestates/ (name it when there are several); host: default b.
#   Environment: TRACE (cannon-kona | cannon), ROLLUP_RPC (default http://op-node:8547 in the stack network), L2_RPC_DEBUG
#   (default: on host b the SEQUENCER_HTTP of its env, on host a http://op-reth:8545), DRILL_NETWORK (default the host
#   stack's compose network; `host` on a scratch machine that reaches both RPCs over the private network and runs no
#   stack), RUN_TIMEOUT (default 3h, the VM timeout), L1_RPC_URL / L1_BEACON_URL (default the env files'); TRACE=cannon
#   only: OP_PROGRAM_TAG (default op-program/v1.9.0, the checkout the host is built from) or OP_PROGRAM_BIN.
#   Scratch host example: ROLLUP_RPC=http://<host B>:8547 L2_RPC_DEBUG=http://<host A>:8545 DRILL_NETWORK=host
# Outputs: drill/out/logs/run-trace-<date>.log (the service log), manifests/evidence/run-trace-<date>.json.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd docker jq openssl
PRESTATE="${1:-}"; HOST="${2:-b}"
case "$HOST" in a|b) ;; *) die "host must be a or b" ;; esac
TRACE="${TRACE:-cannon-kona}"
case "$TRACE" in cannon-kona|cannon) ;; *) die "TRACE must be cannon-kona or cannon" ;; esac
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

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$FINCHAIN_ROOT/manifests/evidence"

# kona-host takes raw RLP from the nodes instead of re-encoding JSON: debug_getRawHeader and debug_getRawReceipts on
# L1, debug_getRawHeader and debug_dbGet on L2. Probe the two endpoints from here before the long run. An endpoint that
# cannot be reached from this shell (a compose-internal name) is skipped. An L1 endpoint that answers "method not
# found" gets drill/l1-raw-shim.py in front of it (L1_RAW_SHIM=auto, the default; 1 forces it, 0 refuses): the shim
# forwards everything and synthesises the two raw methods from eth_getBlockByHash and eth_getBlockReceipts, serving
# nothing whose hash or trie root the node's own header does not confirm. The record says when it was used.
probe_debug() {   # probe_debug <label> <url> <block hash> <method>... -> 0 all served, 1 a method is missing, 2 unreachable
  local label="$1" url="$2" block="$3" m resp err
  for m in "${@:4}"; do
    resp="$(rpc "$url" "$m" "[\"$block\"]" 2>/dev/null || true)"
    if [ -z "$resp" ]; then warn "could not probe $m on the $label endpoint $(rpc_label "$url") from this shell; the run will tell"; return 2; fi
    err="$(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null || true)"
    if [ -n "$err" ]; then warn "the $label endpoint $(rpc_label "$url") does not serve $m ($err)"; return 1; fi
  done
  log "$label endpoint $(rpc_label "$url") serves ${*:4}"
}
L1_UPSTREAM="$L1_RPC_URL"; shim_pid=""; shim_log=""; shim_rec=null; L1_FOR_CONTAINER="$L1_RPC_URL"
if [ "$TRACE" = cannon-kona ]; then
  fin="$(rpc "$L1_RPC_URL" eth_getBlockByNumber '["finalized",false]' 2>/dev/null | jq -r '.result.hash // empty' 2>/dev/null || true)"
  l1_ok=2; [ -z "$fin" ] || { probe_debug L1 "$L1_RPC_URL" "$fin" debug_getRawHeader debug_getRawReceipts && l1_ok=0 || l1_ok=$?; }
  want_shim="${L1_RAW_SHIM:-auto}"
  if [ "$want_shim" = 1 ] || { [ "$want_shim" = auto ] && [ "$l1_ok" = 1 ]; }; then
    require_cmd python3
    [ "$l1_ok" != 1 ] || log "the L1 endpoint lacks the raw methods kona-host reads; starting drill/l1-raw-shim.py in front of it (L1_RAW_SHIM=0 to refuse)"
    shim_port="${L1_RAW_SHIM_PORT:-8550}"; shim_log="$LOGS/l1-raw-shim-$stamp.log"
    if [ "$network" = host ]; then shim_bind=127.0.0.1; else
      shim_bind="$(docker network inspect "$network" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
      [ -n "$shim_bind" ] || die "cannot find the gateway address of the compose network $network for the shim"
    fi
    python3 -I "$FINCHAIN_ROOT/drill/l1-raw-shim.py" --upstream "$L1_UPSTREAM" --listen "$shim_bind:$shim_port" --log "$shim_log" &
    shim_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://$shim_bind:$shim_port/healthz" >/dev/null 2>&1 && break; sleep 1; done
    curl -sf "http://$shim_bind:$shim_port/healthz" >/dev/null 2>&1 || die "the shim did not come up on $shim_bind:$shim_port; see $shim_log"
    L1_FOR_CONTAINER="http://$shim_bind:$shim_port"
    probe_debug "L1 (shim)" "$L1_FOR_CONTAINER" "$fin" debug_getRawHeader debug_getRawReceipts || { kill "$shim_pid" 2>/dev/null; die "the shim cannot synthesise the raw methods from $(rpc_label "$L1_UPSTREAM"); see $shim_log"; }
    log "L1 for the run: the shim at $L1_FOR_CONTAINER, upstream $(rpc_label "$L1_UPSTREAM"); log $shim_log"
  elif [ "$l1_ok" = 1 ]; then
    die "the L1 endpoint $(rpc_label "$L1_RPC_URL") does not serve the raw methods and L1_RAW_SHIM=0; the cannon-kona path needs them (drill/README.md, K2)"
  fi
  l2h="$(rpc "$L2_RPC_DEBUG" eth_getBlockByNumber '["latest",false]' 2>/dev/null | jq -r '.result.hash // empty' 2>/dev/null || true)"
  if [ -n "$l2h" ]; then probe_debug L2 "$L2_RPC_DEBUG" "$l2h" debug_getRawHeader || { [ $? = 2 ] || { [ -z "$shim_pid" ] || kill "$shim_pid" 2>/dev/null; die "the L2 endpoint must be an op-reth with the debug namespace (drill/README.md, K2)"; }; }; fi
fi
stop_shim() {
  [ -n "$shim_pid" ] || return 0
  local counts; counts="$(curl -sf "http://${L1_FOR_CONTAINER#http://}/healthz" 2>/dev/null || echo '{}')"
  kill "$shim_pid" 2>/dev/null || true; wait "$shim_pid" 2>/dev/null || true
  shim_rec="$(jq -cn --arg up "$(rpc_label "$L1_UPSTREAM")" --arg log "drill/out/logs/$(basename "$shim_log")" --arg sha "$(sha256_of "$shim_log")" --argjson c "$counts" \
    '{used: true, what: "drill/l1-raw-shim.py: debug_getRawHeader and debug_getRawReceipts synthesised from eth_getBlockByHash and eth_getBlockReceipts, each answer verified against the header (block hash, receiptsRoot) before it is served; every other method forwarded", upstream: $up, counts: ($c | {forwarded, headers, receipts, failed}), log: $log, logSha256: $sha}')"
  shim_pid=""
}
trap stop_shim EXIT

# The preimage server of each path. cannon-kona: kona-host, shipped in the op-challenger image. cannon: the
# op-program host, which the image does not ship; it is built once from the monorepo checkout of the prestate's
# tag (the one drill/prestate.sh cloned), inside the Go image that tag names, and mounted into the run.
server_mounts=()
if [ "$TRACE" = cannon-kona ]; then
  server_desc="$(docker run --rm --entrypoint /usr/local/bin/kona-host "$IMAGE" --version 2>/dev/null | head -1 || true)"
  [ -n "$server_desc" ] || die "the image $IMAGE has no working /usr/local/bin/kona-host"
  server_desc="$server_desc (shipped in the op-challenger image)"
else
  OP_PROGRAM_TAG="${OP_PROGRAM_TAG:-op-program/v1.9.0}"
  tagslug="$(printf '%s' "$OP_PROGRAM_TAG" | tr '/' '-')"
  repo="$FINCHAIN_ROOT/drill/work/optimism-$tagslug"
  OPP_BIN="${OP_PROGRAM_BIN:-$FINCHAIN_ROOT/drill/out/bin/op-program-$tagslug}"
  if [ ! -x "$OPP_BIN" ]; then
    [ -d "$repo/op-program" ] || die "monorepo checkout not found at $repo (PROVER=op-program make prestate clones it); or set OP_PROGRAM_BIN to a built op-program host"
    go_version="$(grep -oE 'GO_VERSION=[0-9][^ ]*' "$repo/op-program/Makefile" | head -1 | cut -d= -f2)"
    [ -n "$go_version" ] || die "GO_VERSION not found in $repo/op-program/Makefile"
    log "building the op-program host from $OP_PROGRAM_TAG in golang:$go_version (a few minutes; log $LOGS/op-program-host-$tagslug.log)"
    docker run --rm -v "$repo:/src:ro" -v "$FINCHAIN_ROOT/drill/out/bin:/out" -e "OUT_OWNER=$(id -u):$(id -g)" -e "OUT_NAME=op-program-$tagslug" -e GOFLAGS=-buildvcs=false \
      "golang:$go_version" sh -c 'apk add --no-cache make gcc musl-dev linux-headers git >/dev/null && cp -r /src /app && cd /app/op-program && make op-program-host && cp bin/op-program "/out/$OUT_NAME" && chown "$OUT_OWNER" "/out/$OUT_NAME"' \
      >"$LOGS/op-program-host-$tagslug.log" 2>&1 || die "op-program host build failed; see $LOGS/op-program-host-$tagslug.log"
    [ -x "$OPP_BIN" ] || die "op-program host not produced at $OPP_BIN"
  fi
  server_mounts=(-v "$OPP_BIN:/usr/local/bin/op-program:ro")
  server_desc="op-program host built from $OP_PROGRAM_TAG (sha256 $(sha256_of "$OPP_BIN" | cut -c1-16)...)"
fi

logf="$LOGS/run-trace-$stamp.log"
name="finchain-drill-run-trace-$stamp"
pfile="/prestates/$(basename "$PRESTATE")"
# a throwaway signer: run-trace sends no transaction, the transaction manager only wants a key to exist.
# --<trace>-prestate names the same file as --run: the configuration check wants a prestate source before the
# runner reads the run's own file.
throwaway="$(openssl rand -hex 32)"
# the flags of each path; the chain's rollup.json and genesis.json are given to the host side of the VM in both
if [ "$TRACE" = cannon-kona ]; then
  trace_flags=(--trace-type cannon-kona --cannon-bin /usr/local/bin/cannon --cannon-kona-server /usr/local/bin/kona-host
    --cannon-kona-rollup-config /chain/rollup.json --cannon-kona-l2-genesis /chain/genesis.json
    --cannon-kona-prestate "$pfile" --run "cannon-kona/finchain/file:$pfile" --l2-eth-rpc "$L2_RPC_DEBUG")
else
  trace_flags=(--trace-type cannon --cannon-bin /usr/local/bin/cannon --cannon-server /usr/local/bin/op-program
    --cannon-rollup-config /chain/rollup.json --cannon-l2-genesis /chain/genesis.json
    --cannon-prestate "$pfile" --run "cannon/finchain/file:$pfile" --l2-eth-rpc "$L2_RPC_DEBUG" --l2-experimental-eth-rpc "$L2_RPC_DEBUG")
fi

log "run-trace ($TRACE) on host $HOST: prestate $hash, network $network, rollup RPC $(rpc_label "$ROLLUP_RPC"), L2 debug RPC $(rpc_label "$L2_RPC_DEBUG")"
log "preimage server: $server_desc; VM timeout $RUN_TIMEOUT; log $logf"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; t0="$(date +%s)"
docker run -d --name "$name" --network "$network" \
  -v "$CHAIN_DIR/out:/chain:ro" -v "$(dirname "$PRESTATE"):/prestates:ro" -v "finchain-drill-run-trace:/data" ${server_mounts[@]+"${server_mounts[@]}"} \
  --entrypoint op-challenger "$IMAGE" run-trace \
  --l1-eth-rpc "$L1_FOR_CONTAINER" --l1-beacon "$L1_BEACON_URL" --rollup-rpc "$ROLLUP_RPC" \
  --game-factory-address "$DGF" --datadir /data "${trace_flags[@]}" --vm-timeout "$RUN_TIMEOUT" \
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
stop_shim

# what the run looked at, from its own log
inputs="$(jq -c 'select(.msg=="Using L1 head") | {l1Head: .num, l1HeadHash: .hash, disputeL1: .disputeL1}' <"$logf" 2>/dev/null | head -1)"; [ -n "$inputs" ] || inputs=null
l2="$(jq -c 'select(.msg=="Got sync status") | .status | {finalizedL1: .finalized_l1.number, safeL2: .safe_l2.number, finalizedL2: .finalized_l2.number}' <"$logf" 2>/dev/null | head -1)"; [ -n "$l2" ] || l2=null
claim="$(jq -c 'select(.l2Block != null and .claim != null) | {l2Block: .l2Block, claim: .claim, l2Head: .l2, l1: .l1}' <"$logf" 2>/dev/null | head -1)"; [ -n "$claim" ] || claim=null
if [ "$TRACE" = cannon-kona ]; then client="kona-client"; l2note=" (kona-host preimage path: eth and debug namespaces)"; else client="op-program"; l2note=" (execution-witness path)"; fi
ev="$FINCHAIN_ROOT/manifests/evidence/run-trace-$stamp.json"
jq -n --arg at "$started" --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson secs "$elapsed" --arg host "$HOST" --arg hash "$hash" --arg file "$(basename "$PRESTATE")" \
  --arg image "$IMAGE" --arg l1 "$(rpc_label "$L1_UPSTREAM")" --argjson shim "$shim_rec" --arg dgf "$DGF" --argjson inputs "$inputs" --argjson sync "$l2" --argjson claim "$claim" \
  --arg result "$result" --arg reason "$reason" --arg logname "drill/out/logs/run-trace-$stamp.log" --argjson cid "${CHAIN_ID:-0}" \
  --arg rollup "$(rpc_label "$ROLLUP_RPC")" --arg l2src "$(rpc_label "$L2_RPC_DEBUG")$l2note" --arg server "$server_desc" --arg trace "$TRACE" --arg client "$client" '
  {schema: "finchain.run-trace/2",
   acceptance: "M4 K2: trace self-check (run-trace) passes for a recent block (docs/acceptance.md M4; docs/proof-plan.md K2)",
   environment: "public-testnet", chainId: $cid, host: $host, startedAt: $at, finishedAt: $end, seconds: $secs,
   what: ("op-challenger run-trace: " + $client + " executed inside the Cannon VM from the prestate below for one recent L2 block of the live chain (the safe head at a finalized L1 block and its parent, from the host op-node); PASS = the VM exited with the claim verified"),
   prestate: {hash: $hash, file: $file, source: "drill/prestate.sh (manifests/evidence/prestate-<chainId>-<date>.json)"},
   image: $image, traceType: $trace, preimageServer: $server, l1: $l1, l1RawMethodsShim: $shim, disputeGameFactory: $dgf, rollupRpc: $rollup, l2Source: $l2src,
   inputs: {syncStatus: $sync, l1Head: $inputs, block: $claim},
   result: $result, reason: $reason, log: $logname}' > "$ev"
echo "run-trace ($TRACE) $result: $reason (${elapsed}s)"
echo "record: $ev"
echo "log:    $logf"
[ "$result" = PASS ] || exit 3
