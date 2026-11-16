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
#   stack), RUN_TIMEOUT (default 3h, the VM timeout), L1_RPC_URL / L1_BEACON_URL (the env files' unless given), L1_RAW_SHIM
#   (auto | 1 | 0: drill/rpc-shim.py --synth in front of an L1 endpoint without the raw debug methods); TRACE=cannon
#   only: OP_PROGRAM_TAG (default op-program/v1.9.0, the checkout the host is built from) or OP_PROGRAM_BIN.
#   Scratch host example: ROLLUP_RPC=http://<host B>:8547 L2_RPC_DEBUG=http://<host A>:8545 DRILL_NETWORK=host
#   Another chain (the devnet of K3, drill/devnet/): CHAIN_OUT=<dir with rollup.json, genesis.json, chain-record.json>
#   together with L1_RPC_URL and L1_BEACON_URL skips the public chain's env files; KONA_CHAIN_SLUG picks that chain's
#   embedded kona-host (drill/out/bin/kona-host-<slug>-<tag>); ENVIRONMENT (default public-testnet) names the
#   environment in the record.
# Outputs: drill/out/logs/run-trace-<date>.log (the service log), manifests/evidence/run-trace-<date>.json.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd docker jq openssl
PRESTATE="${1:-}"; HOST="${2:-b}"
case "$HOST" in a|b) ;; *) die "host must be a or b" ;; esac
TRACE="${TRACE:-cannon-kona}"
case "$TRACE" in cannon-kona|cannon) ;; *) die "TRACE must be cannon-kona or cannon" ;; esac
pre_l1="${L1_RPC_URL:-}"; pre_beacon="${L1_BEACON_URL:-}"   # given on the command line: they win over the env files
if [ -n "${CHAIN_OUT:-}" ] && [ -n "$pre_l1" ] && [ -n "$pre_beacon" ]; then
  load_env "$FINCHAIN_ROOT/versions.lock"   # another chain's artifacts and endpoints: the public chain's env files stay out of it
else
  load_standard_env
  henv="$(host_env "$HOST")"; [ -f "$henv" ] && load_env "$henv"
fi
[ -z "$pre_l1" ] || L1_RPC_URL="$pre_l1"; [ -z "$pre_beacon" ] || L1_BEACON_URL="$pre_beacon"
CHAIN_OUT="${CHAIN_OUT:-$CHAIN_DIR/out}"; [ -f "$CHAIN_OUT/rollup.json" ] || die "rollup.json not found under $CHAIN_OUT"
ENVIRONMENT="${ENVIRONMENT:-public-testnet}"
ROLLUP_RPC="${ROLLUP_RPC:-http://op-node:8547}"
if [ -z "${L2_RPC_DEBUG:-}" ]; then
  if [ "$HOST" = b ]; then L2_RPC_DEBUG="${SEQUENCER_HTTP:?SEQUENCER_HTTP missing in $(host_env b): the L2 RPC with debug is the op-reth of host A}"; else L2_RPC_DEBUG="http://op-reth:8545"; fi
fi
L1_RPC_URL="${L1_RPC_URL:?L1_RPC_URL missing (.env or the host env file)}"; L1_BEACON_URL="${L1_BEACON_URL:?L1_BEACON_URL missing (.env or the host env file)}"
if [ -z "$PRESTATE" ]; then
  PRESTATE="$(find "$FINCHAIN_ROOT/drill/out/prestates" -maxdepth 1 -name '0x*.bin.gz' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)"
  [ -n "$PRESTATE" ] || die "no prestate under drill/out/prestates/; run make prestate first or name the file"
  [ "$(find "$FINCHAIN_ROOT/drill/out/prestates" -maxdepth 1 -name '0x*.bin.gz' 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || warn "several prestates under drill/out/prestates/; using the newest, $(basename "$PRESTATE") (PRESTATE=<file> to choose)"
fi
[ -f "$PRESTATE" ] || die "prestate not found: $PRESTATE"
PRESTATE="$(cd "$(dirname "$PRESTATE")" && pwd)/$(basename "$PRESTATE")"
hash="$(basename "$PRESTATE" .bin.gz)"
REC="$CHAIN_OUT/chain-record.json"; [ -f "$REC" ] || die "chain record not found: $REC"
DGF="$(jq -r '.l1.DisputeGameFactoryProxy // empty' "$REC")"; [ -n "$DGF" ] || die "DisputeGameFactoryProxy missing in $REC"
network="${DRILL_NETWORK:-$STACK-${HOST}_default}"
[ "$network" = host ] || docker network inspect "$network" >/dev/null 2>&1 || die "compose network $network not found: is the host $HOST stack up on this machine? (DRILL_NETWORK=host on a scratch machine)"
IMAGE="${OP_CHALLENGER_IMAGE:?OP_CHALLENGER_IMAGE missing in versions.lock}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3h}"
LOGS="$FINCHAIN_ROOT/drill/out/logs"; mkdir -p "$LOGS" "$FINCHAIN_ROOT/drill/out/bin"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$FINCHAIN_ROOT/manifests/evidence"

# kona-host reads the nodes as raw RLP and proofs: debug_getRawHeader and debug_getRawReceipts on L1; debug_getRawHeader,
# debug_dbGet and eth_getProof at the agreed L2 block on L2. Probe both endpoints from here before the long run (an
# endpoint this shell cannot reach, a compose-internal name, is skipped). drill/rpc-shim.py fills the two gaps that
# public endpoints and the hosts' own settings leave, and the record says when it did:
#   L1: an endpoint without the raw methods gets the shim in front of it (L1_RAW_SHIM=auto, the default; 1 forces, 0
#       refuses), which synthesises them from the standard methods and serves nothing whose hash or trie root the
#       node's own header does not confirm;
#   L2: host A's op-reth answers eth_getProof only at its head (reth's default proof window), so when the probe says
#       "exceeds maximum proof window" the shim routes eth_getProof to an op-reth that has a window - host B's
#       (L2_PROOF_RPC; default http://<B_BIND_IP>:<B_RPC_PORT> when the host env knows them) - and everything else
#       to A. The lasting fix is --rpc.eth-proof-window on host A's op-reth (drill/README.md, K2b).
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
shim_pids=(); shim_logs=(); shim_urls=(); shim_recs=(); SHIM_URL=""
start_shim() {   # start_shim <name> <upstream> <port> <shim args...>; sets SHIM_URL (no subshell: the pid must reach stop_shims)
  local name="$1" up="$2" port="$3" bind logf pid
  if [ "$network" = host ]; then bind=127.0.0.1; else
    bind="$(docker network inspect "$network" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
    [ -n "$bind" ] || die "cannot find the gateway address of the compose network $network for the $name shim"
  fi
  logf="$LOGS/rpc-shim-$name-$stamp.log"
  python3 -I "$FINCHAIN_ROOT/drill/rpc-shim.py" --upstream "$up" --listen "$bind:$port" --log "$logf" "${@:4}" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://$bind:$port/healthz" >/dev/null 2>&1 && break; sleep 1; done
  curl -sf "http://$bind:$port/healthz" >/dev/null 2>&1 || { kill "$pid" 2>/dev/null; die "the $name shim did not come up on $bind:$port; see $logf"; }
  SHIM_URL="http://$bind:$port"
  shim_pids+=("$pid"); shim_logs+=("$logf"); shim_urls+=("$SHIM_URL")
}
stop_shims() {
  local i counts
  for i in "${!shim_pids[@]}"; do
    counts="$(curl -sf "${shim_urls[$i]}/healthz" 2>/dev/null || echo '{}')"
    kill "${shim_pids[$i]}" 2>/dev/null || true; wait "${shim_pids[$i]}" 2>/dev/null || true
    shim_recs+=("$(jq -cn --argjson c "$counts" --arg log "drill/out/logs/$(basename "${shim_logs[$i]}")" --arg sha "$(sha256_of "${shim_logs[$i]}")" \
      '{upstream: $c.upstream, synthesised: ($c.synth // []), routes: ($c.routes // {}), beaconStub: ($c.beaconStub // null), counts: ($c | {forwarded, routed, headers, receipts, beacon, failed}), log: $log, logSha256: $sha}')")
  done
  shim_pids=()
}
trap stop_shims EXIT
L1_UPSTREAM="$L1_RPC_URL"; L1_FOR_CONTAINER="$L1_RPC_URL"; L2_FOR_CONTAINER="$L2_RPC_DEBUG"; L2_PROOF_USED=""
if [ "$TRACE" = cannon-kona ]; then
  fin="$(rpc "$L1_RPC_URL" eth_getBlockByNumber '["finalized",false]' 2>/dev/null | jq -r '.result.hash // empty' 2>/dev/null || true)"
  l1_ok=2; [ -z "$fin" ] || { probe_debug L1 "$L1_RPC_URL" "$fin" debug_getRawHeader debug_getRawReceipts && l1_ok=0 || l1_ok=$?; }
  want_shim="${L1_RAW_SHIM:-auto}"
  if [ "$want_shim" = 1 ] || { [ "$want_shim" = auto ] && [ "$l1_ok" = 1 ]; }; then
    require_cmd python3
    [ "$l1_ok" != 1 ] || log "the L1 endpoint lacks the raw methods kona-host reads; starting drill/rpc-shim.py --synth in front of it (L1_RAW_SHIM=0 to refuse)"
    start_shim l1 "$L1_UPSTREAM" "${L1_RAW_SHIM_PORT:-8550}" --synth; L1_FOR_CONTAINER="$SHIM_URL"
    probe_debug "L1 (shim)" "$L1_FOR_CONTAINER" "$fin" debug_getRawHeader debug_getRawReceipts || die "the shim cannot synthesise the raw methods from $(rpc_label "$L1_UPSTREAM"); see $LOGS/rpc-shim-l1-$stamp.log"
    log "L1 for the run: the shim at $L1_FOR_CONTAINER, upstream $(rpc_label "$L1_UPSTREAM")"
  elif [ "$l1_ok" = 1 ]; then
    die "the L1 endpoint $(rpc_label "$L1_RPC_URL") does not serve the raw methods and L1_RAW_SHIM=0; the cannon-kona path needs them (drill/README.md, K2)"
  fi
  l2h="$(rpc "$L2_RPC_DEBUG" eth_getBlockByNumber '["latest",false]' 2>/dev/null | jq -r '.result.hash // empty' 2>/dev/null || true)"
  if [ -n "$l2h" ]; then
    probe_debug L2 "$L2_RPC_DEBUG" "$l2h" debug_getRawHeader || { [ $? = 2 ] || die "the L2 endpoint must be an op-reth with the debug namespace (drill/README.md, K2)"; }
    # eth_getProof at a block a few minutes old, as kona-host asks it for the agreed L2 head
    l2n="$(rpc "$L2_RPC_DEBUG" eth_blockNumber 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
    if [ -n "$l2n" ]; then
      past="$(printf '0x%x' $(( l2n - 300 )))"
      perr="$(rpc "$L2_RPC_DEBUG" eth_getProof "[\"0x4200000000000000000000000000000000000016\",[],\"$past\"]" 2>/dev/null | jq -r '.error.message // empty' 2>/dev/null || true)"
      if [ -n "$perr" ]; then
        warn "the L2 endpoint $(rpc_label "$L2_RPC_DEBUG") refuses eth_getProof at block $((l2n - 300)) ($perr)"
        L2_PROOF_RPC="${L2_PROOF_RPC:-${B_BIND_IP:+http://$B_BIND_IP:${B_RPC_PORT:-8545}}}"
        [ -n "${L2_PROOF_RPC:-}" ] || die "set L2_PROOF_RPC to an op-reth of this chain with --rpc.eth-proof-window (host B's private RPC), or give host A's op-reth that flag (drill/README.md, K2b)"
        pres2="$(rpc "$L2_PROOF_RPC" eth_getProof "[\"0x4200000000000000000000000000000000000016\",[],\"$past\"]" 2>/dev/null || true)"
        [ "$(jq -r '.result.storageHash // empty' <<<"$pres2" 2>/dev/null || true)" != "" ] || die "the proof endpoint $(rpc_label "$L2_PROOF_RPC") gives no eth_getProof at block $((l2n - 300)): $( [ -n "$pres2" ] && jq -r '.error.message // "no result"' <<<"$pres2" 2>/dev/null || echo unreachable)"
        require_cmd python3
        log "routing eth_getProof to $(rpc_label "$L2_PROOF_RPC") and everything else to $(rpc_label "$L2_RPC_DEBUG") through drill/rpc-shim.py"
        start_shim l2 "$L2_RPC_DEBUG" "${L2_SHIM_PORT:-8551}" --route "eth_getProof=$L2_PROOF_RPC"; L2_FOR_CONTAINER="$SHIM_URL"
        L2_PROOF_USED="$L2_PROOF_RPC"
        probe_debug "L2 (shim)" "$L2_FOR_CONTAINER" "$l2h" debug_getRawHeader || die "the L2 shim does not forward to $(rpc_label "$L2_RPC_DEBUG"); see $LOGS/rpc-shim-l2-$stamp.log"
      else
        log "L2 endpoint $(rpc_label "$L2_RPC_DEBUG") serves eth_getProof at block $((l2n - 300))"
      fi
    fi
  fi
fi

# The preimage server of each path.
# cannon-kona: kona-host built with the chain in its registry (drill/kona-host-build.sh), run through
#   drill/kona-host-wrapper.sh so that the client gets the chain id the game contract would give it and looks the
#   chain up in the registry embedded in the prestate. The kona-host shipped in the image knows only registry chains:
#   with it the client boots with chain id 0 and the oracle-supplied configuration, which the run reports and which
#   does not count (result PASS-WITH-ORACLE-CONFIG).
# cannon: the op-program host, which the image does not ship; built once from the monorepo checkout of the
#   prestate's tag inside the Go image that tag names, and mounted into the run.
server_args=(); kona_server=/usr/local/bin/kona-host; embedded_host=false; kona_host_sha=""
if [ "$TRACE" = cannon-kona ]; then
  KONA_TAG="${KONA_TAG:-kona-client/v1.9.0}"
  KONA_HOST_BIN="${KONA_HOST_BIN:-$FINCHAIN_ROOT/drill/out/bin/kona-host-${KONA_CHAIN_SLUG:-finchain}-$(printf '%s' "$KONA_TAG" | tr '/' '-')}"
  l2_chain_id="$(jq -r '.l2_chain_id' "$CHAIN_OUT/rollup.json")"
  if [ -s "$KONA_HOST_BIN" ]; then
    wrapper="$FINCHAIN_ROOT/drill/out/bin/kona-host-wrapper.sh"
    cp "$FINCHAIN_ROOT/drill/kona-host-wrapper.sh" "$wrapper"; chmod +x "$wrapper" "$KONA_HOST_BIN"
    ver="$(docker run --rm -v "$KONA_HOST_BIN:/usr/local/bin/kona-host-finchain-bin:ro" --entrypoint /usr/local/bin/kona-host-finchain-bin "$IMAGE" --version 2>/dev/null | head -1 || true)"
    [ -n "$ver" ] || die "the embedded kona-host $KONA_HOST_BIN does not run inside $IMAGE"
    kona_host_sha="$(sha256_of "$KONA_HOST_BIN")"
    server_args=(-v "$KONA_HOST_BIN:/usr/local/bin/kona-host-finchain-bin:ro" -v "$wrapper:/usr/local/bin/kona-host-finchain:ro" -e "KONA_L2_CHAIN_ID=$l2_chain_id")
    kona_server=/usr/local/bin/kona-host-finchain
    server_desc="$ver built from $KONA_TAG with chain $l2_chain_id in its registry (sha256 ${kona_host_sha:0:16}...), through drill/kona-host-wrapper.sh: --l2-chain-id $l2_chain_id instead of --rollup-config-path"
    embedded_host=true
  else
    server_desc="$(docker run --rm --entrypoint /usr/local/bin/kona-host "$IMAGE" --version 2>/dev/null | head -1 || true)"
    [ -n "$server_desc" ] || die "the image $IMAGE has no working /usr/local/bin/kona-host"
    server_desc="$server_desc (shipped in the op-challenger image; it hands the client chain id 0, so the client uses the oracle-supplied configuration)"
    warn "no embedded kona-host at $KONA_HOST_BIN (make kona-host builds it): the image's kona-host will give the client chain id 0 and the oracle-supplied configuration; such a run is reported as PASS-WITH-ORACLE-CONFIG and does not count for K2"
  fi
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
  server_args=(-v "$OPP_BIN:/usr/local/bin/op-program:ro")
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
  trace_flags=(--trace-type cannon-kona --cannon-bin /usr/local/bin/cannon --cannon-kona-server "$kona_server"
    --cannon-kona-rollup-config /chain/rollup.json --cannon-kona-l2-genesis /chain/genesis.json
    --cannon-kona-prestate "$pfile" --run "cannon-kona/finchain/file:$pfile" --l2-eth-rpc "$L2_FOR_CONTAINER")
else
  trace_flags=(--trace-type cannon --cannon-bin /usr/local/bin/cannon --cannon-server /usr/local/bin/op-program
    --cannon-rollup-config /chain/rollup.json --cannon-l2-genesis /chain/genesis.json
    --cannon-prestate "$pfile" --run "cannon/finchain/file:$pfile" --l2-eth-rpc "$L2_FOR_CONTAINER" --l2-experimental-eth-rpc "$L2_FOR_CONTAINER")
fi

log "run-trace ($TRACE) on host $HOST: prestate $hash, network $network, rollup RPC $(rpc_label "$ROLLUP_RPC"), L2 debug RPC $(rpc_label "$L2_RPC_DEBUG")"
log "preimage server: $server_desc; VM timeout $RUN_TIMEOUT; log $logf"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; t0="$(date +%s)"
docker run -d --name "$name" --network "$network" \
  -v "$CHAIN_OUT:/chain:ro" -v "$(dirname "$PRESTATE"):/prestates:ro" -v "finchain-drill-run-trace:/data" ${server_args[@]+"${server_args[@]}"} \
  --entrypoint op-challenger "$IMAGE" run-trace \
  --l1-eth-rpc "$L1_FOR_CONTAINER" --l1-beacon "$L1_BEACON_URL" --rollup-rpc "$ROLLUP_RPC" \
  --game-factory-address "$DGF" --datadir /data "${trace_flags[@]}" --vm-timeout "$RUN_TIMEOUT" \
  --private-key "$throwaway" --log.format json --log.level info >/dev/null
unset throwaway

# first_line <jq filter>: the first matching line of the service log, compact; the log is JSON lines, one object
# per line, and may be long - jq stops after the first match, so no pipe is closed on a writer (pipefail is on)
first_line() { jq -c "first(inputs | $1)" -n <"$logf" 2>/dev/null || true; }

# follow the log until the first verdict; run-trace itself loops forever
result=""; reason=""
while :; do
  docker logs "$name" >"$logf" 2>&1 || true
  if grep -q '"msg":"Successfully verified output root"' "$logf"; then result=PASS; reason="VM exited with the claim verified"; break; fi
  if grep -q '"msg":"Incorrect status code"' "$logf"; then result=FAIL; reason="VM exited but the claim was not verified"; break; fi
  if grep -q '"msg":"VM panicked"' "$logf"; then result=FAIL; reason="VM panicked"; break; fi
  if grep -q '"msg":"VM execution timed out"' "$logf"; then result=FAIL; reason="VM timed out after $RUN_TIMEOUT"; break; fi
  if grep -q '"msg":"Failed to run"' "$logf"; then result=FAIL; reason="setup failure: $(first_line 'select(.msg=="Failed to run") | .err' | jq -r . 2>/dev/null | cut -c1-300)"; break; fi
  if ! docker ps -q --no-trunc --filter "name=^/$name$" | grep -q .; then result=FAIL; reason="the container exited: $(tail -n 3 "$logf" | tr '\n' ' ' | cut -c1-300)"; break; fi
  sleep 20
done
docker rm -f "$name" >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - t0 ))
stop_shims
shims_json="$(printf '%s\n' "${shim_recs[@]+"${shim_recs[@]}"}" | jq -cs 'map(select(. != null))')"

# what the run looked at, from its own log
inputs="$(first_line 'select(.msg=="Using L1 head") | {l1Head: .num, l1HeadHash: .hash, disputeL1: .disputeL1}')"; [ -n "$inputs" ] || inputs=null
l2="$(first_line 'select(.msg=="Got sync status") | .status | {finalizedL1: .finalized_l1.number, safeL2: .safe_l2.number, finalizedL2: .finalized_l2.number}')"; [ -n "$l2" ] || l2=null
claim="$(first_line 'select(.l2Block != null and .claim != null) | {l2Block: .l2Block, claim: .claim, l2Head: .l2, l1: .l1}')"; [ -n "$claim" ] || claim=null
if [ "$TRACE" = cannon-kona ]; then client="kona-client"; l2note=" (kona-host preimage path: eth and debug namespaces)"; else client="op-program"; l2note=" (execution-witness path)"; fi
# the client's boot path, from the guest's own stdout: a chain id its registry does not hold makes it fall back to the
# oracle-supplied configuration (rollup or L1), which is not what the game contract would put it on; such a pass does
# not count
boot_line="$(first_line 'select(.msg | test("boot_loader: No .* config found for chain ID")) | .msg' | jq -r . 2>/dev/null | sed -E 's/.*(boot_loader: [^"\\]*).*/\1/' | head -c 300 || true)"
boot_chain=""; embedded_used=true
if [ -n "$boot_line" ]; then embedded_used=false; boot_chain="$(sed -nE 's/.*chain ID ([0-9]+).*/\1/p' <<<"$boot_line")"; fi
if [ "$result" = PASS ] && [ "$embedded_used" = false ]; then
  result="PASS-WITH-ORACLE-CONFIG"; reason="VM exited with the claim verified, but the client booted with chain id ${boot_chain:-?} and the oracle-supplied rollup configuration, not the one embedded in the prestate (the kona-host in front of it does not know the chain); not acceptable for K2"
fi
ev="$FINCHAIN_ROOT/manifests/evidence/run-trace-$stamp.json"
jq -n --arg at "$started" --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson secs "$elapsed" --arg host "$HOST" --arg hash "$hash" --arg file "$(basename "$PRESTATE")" \
  --arg image "$IMAGE" --arg l1 "$(rpc_label "$L1_UPSTREAM")" --argjson shims "$shims_json" --arg l2proof "$( [ -n "$L2_PROOF_USED" ] && rpc_label "$L2_PROOF_USED" || echo "")" --arg dgf "$DGF" --argjson inputs "$inputs" --argjson sync "$l2" --argjson claim "$claim" \
  --arg result "$result" --arg reason "$reason" --arg logname "drill/out/logs/run-trace-$stamp.log" --argjson cid "$(jq -r '.l2_chain_id' "$CHAIN_OUT/rollup.json")" \
  --arg rollup "$(rpc_label "$ROLLUP_RPC")" --arg l2src "$(rpc_label "$L2_RPC_DEBUG")$l2note" --arg server "$server_desc" --arg trace "$TRACE" --arg client "$client" --arg environment "$ENVIRONMENT" \
  --argjson emb_host "$embedded_host" --arg khsha "$kona_host_sha" --argjson emb_used "$embedded_used" --arg bootline "$boot_line" --arg bootchain "$boot_chain" '
  {schema: "finchain.run-trace/2",
   acceptance: "M4 K2: trace self-check (run-trace) passes for a recent block (docs/acceptance.md M4; docs/proof-plan.md K2)",
   environment: $environment, chainId: $cid, host: $host, startedAt: $at, finishedAt: $end, seconds: $secs,
   what: ("op-challenger run-trace: " + $client + " executed inside the Cannon VM from the prestate below for one recent L2 block of the chain (the safe head at a finalized L1 block and its parent, from the op-node named below); PASS = the VM exited with the claim verified"),
   prestate: {hash: $hash, file: $file, source: "drill/prestate.sh (manifests/evidence/prestate-<chainId>-<date>.json)"},
   image: $image, traceType: $trace, preimageServer: $server,
   konaHost: (if $trace == "cannon-kona" then {embeddedRegistry: $emb_host, binarySha256: (if $khsha == "" then null else $khsha end), record: (if $emb_host then "manifests/evidence/kona-host-<chainId>-<date>.json" else null end)} else null end),
   clientBoot: (if $trace == "cannon-kona" then {embeddedConfigUsed: $emb_used, chainIdSeenByClient: (if $bootchain == "" then null else ($bootchain | tonumber) end), guestLine: (if $bootline == "" then null else $bootline end),
                 meaning: "on chain the game contract gives the client its L2 chain id (local preimage key 5) and the client reads the configuration embedded in the prestate; a client that fell back to the oracle-supplied configuration ran a different boot path"} else null end),
   l1: $l1, disputeGameFactory: $dgf, rollupRpc: $rollup, l2Source: $l2src,
   l2ProofSource: (if $l2proof == "" then null else ($l2proof + " (eth_getProof routed there by the shim: host A answers proofs only at its head)") end),
   rpcShims: {what: "drill/rpc-shim.py between op-challenger/kona-host and the endpoints; synthesised = raw methods built from standard ones and verified against the header before being served; routes = methods sent to another endpoint", instances: $shims},
   inputs: {syncStatus: $sync, l1Head: $inputs, block: $claim},
   result: $result, reason: $reason, log: $logname}' > "$ev"
echo "run-trace ($TRACE) $result: $reason (${elapsed}s)"
echo "record: $ev"
echo "log:    $logf"
[ "$result" = PASS ] || exit 3
