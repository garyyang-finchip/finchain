#!/usr/bin/env bash
# M4 K4: what a Type 8 (CANNON_KONA) game implementation needs on the chain CHAIN selects (Finchain Sepolia by
# default), read back from the chain and from the host this runs on, and the exact owner transactions that would install it (docs/proof-plan.md, "K4"; docs/acceptance.md
# M4). Nothing here changes the chain: the installation itself is an owner transaction signed in the browser wallet
# (owner-console.html), and the respected game type is never touched.
#
# What is read:
#   - the DisputeGameFactory: owner, game count, the implementation and the packed arguments of game types 1 and 8, the
#     initial bonds; the AnchorStateRegistry: respected game type, the anchor root and whether it has left op-deployer's
#     placeholder (a Type 8 game is only playable once it has: drill/devnet/README.md); the shared FaultDisputeGame
#     implementation and its clocks; the MIPS64 VM, its state version and its PreimageOracle; the DelayedWETH delay;
#   - the K2 records: the Finchain-embedding kona-client prestate and the embedded kona-host, and whether their files are
#     present on this host (the challenger host needs both for a real dispute, the prestate alone to track a game);
#   - the challenger host, when this runs on it (node-b/.env present): whether the challenger's L1 endpoint serves the
#     raw-RLP debug methods kona-host reads, whether the local op-reth answers eth_getProof at an old block, and the
#     trace types, update interval and game window of the running challenger (else the compose files' defaults).
# What is written: manifests/evidence/k4-readiness-<date>.json (schema finchain.k4-readiness/1, the chain's environment),
# with the packed game arguments and the calldata of setImplementation(8, impl, args) and setInitBond(8, bond), and a
# verdict per item (ready / pending / missing). Endpoints are recorded by scheme and host only.
#
# Usage: scripts/k4-readiness.sh [l1-rpc]
#   The L1 RPC: the argument, else L1_RPC_URL, else node-b/.env, else .env. K4_INIT_BOND_WEI (default 0.08 ETH, the
#   standard) is the initial bond the setInitBond calldata carries. Reads the chain with curl + jq only (no docker).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk

L1="${1:-${L1_RPC_URL:-}}"
if [ -z "$L1" ]; then
  for f in "$(host_env b)" "$FINCHAIN_ROOT/.env$ENV_SUFFIX"; do
    [ -f "$f" ] && L1="$(grep -E '^L1_RPC_URL=' "$f" | tail -1 | cut -d= -f2- | tr -d '"')" && [ -n "$L1" ] && break
  done
fi
[ -n "$L1" ] || die "no L1 RPC: pass it as the first argument or set L1_RPC_URL"
L1_LABEL="$(rpc_label "$L1")"
# the endpoint must be the chain's L1: a second chain's env is a copy of the example until edited, and an answer of
# "0x" from the wrong L1 is otherwise mistaken for a revert (docs/runbook.md section 9)
l1_want="$(grep -E '^L1_CHAIN_ID=' "$FINCHAIN_ROOT/.env$ENV_SUFFIX" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
if [ -n "$l1_want" ]; then
  l1_got="$(rpc "$L1" eth_chainId '[]' 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
  [ -n "$l1_got" ] || die "$L1_LABEL did not answer eth_chainId"
  [ "$((l1_got))" = "$((l1_want))" ] || die "$L1_LABEL is L1 chain $((l1_got)), but CHAIN=$CHAIN settles on L1 chain $l1_want (.env$ENV_SUFFIX): pass the right endpoint (L1_RPC_URL=...)"
fi
REC="$CHAIN_DIR/out/chain-record.json"; ADDRS="$CHAIN_DIR/out/l1-addresses.json"
[ -f "$REC" ] && [ -f "$ADDRS" ] || die "chain record or L1 addresses missing under $CHAIN_REL/out (make export first)"
L2_CHAIN_ID="$(jq -r .chainId "$REC")"
DGF="$(jq -r '.DisputeGameFactoryProxy' "$ADDRS")"; ASR="$(jq -r '.AnchorStateRegistryProxy' "$ADDRS")"
PORTAL="$(jq -r '.OptimismPortalProxy' "$ADDRS")"; IMPL="$(jq -r '.FaultDisputeGameImpl' "$ADDRS")"
PIMPL="$(jq -r '.PermissionedDisputeGameImpl' "$ADDRS")"; MIPS="$(jq -r '.MipsImpl' "$ADDRS")"
WETH="$(jq -r '.DelayedWethPermissionlessGameProxy' "$ADDRS")"
GAME_TYPE="${K4_GAME_TYPE:-8}"
INIT_BOND_WEI="${K4_INIT_BOND_WEI:-80000000000000000}"
DEAD_ROOT=0xdead000000000000000000000000000000000000000000000000000000000000

# selectors (cast sig)
S_OWNER=0x8da5cb5b; S_GAME_IMPLS=0x1b685b9e; S_GAME_ARGS=0x74cc86ac; S_INIT_BONDS=0x6593dc6e; S_GAME_COUNT=0x4d1975b4
S_VERSION=0x54fd4d50; S_RESPECTED=0x3c9f397c; S_ANCHOR=0xd83ef267; S_FINALITY=0x952b2797; S_PROOF_MATURITY=0xbf653a5c
S_MAX_DEPTH=0xfa315aa9; S_SPLIT=0xec5e6308; S_EXT=0x6b6716c0; S_MAX_CLOCK=0xdabd396d; S_STATE_VERSION=0x1219a4e4
S_ORACLE=0x7dc0d1d0; S_CHALLENGE_PERIOD=0xf3f480d9; S_MIN_PROPOSAL=0xdd24f9bf; S_DELAY=0x6a42b8f8
S_SET_IMPL=0xb1070957; S_SET_INIT_BOND=0x1e334240

ecall() {   # ecall <to> <data> -> raw hex result, or "0x" after six attempts (a revert, or a rationed endpoint)
  local attempt raw r
  for attempt in 1 2 3 4 5 6; do
    raw="$(rpc "$L1" eth_call "[{\"to\":\"$1\",\"data\":\"$2\"},\"latest\"]" 2>/dev/null || true)"
    r="$(jq -r '.result // empty' <<<"$raw" 2>/dev/null || true)"
    if [ -n "$r" ]; then echo "$r"; return 0; fi
    sleep $((attempt * 2))
  done
  echo "0x"
}
word_n() { [ "${#1}" -ge $((2 + 64 * ($2 + 1))) ] && printf '%d' "0x$(printf '%s' "$1" | cut -c$((3 + 64 * $2))-$((2 + 64 * ($2 + 1))))" || echo 0; }
word_addr() { [ "${#1}" -ge $((2 + 64 * ($2 + 1))) ] && echo "0x$(printf '%s' "$1" | cut -c$((27 + 64 * $2))-$((2 + 64 * ($2 + 1))))" || echo 0x0000000000000000000000000000000000000000; }
word_hex() { [ "${#1}" -ge $((2 + 64 * ($2 + 1))) ] && echo "0x$(printf '%s' "$1" | cut -c$((3 + 64 * $2))-$((2 + 64 * ($2 + 1))))" || echo 0x; }
pad_u() { printf '%064x' "$1"; }
pad_a() { printf '%064s' "$(printf '%s' "$1" | sed 's/^0x//')" | tr ' ' 0; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# a `string` return value (version()): offset word, length word, then the bytes (ASCII)
# shellcheck disable=SC2059
str_ret() { local h len; h="$(printf '%s' "$1" | sed 's/^0x//')"; len="$(word_n "0x$h" 1)"; [ "$len" -gt 0 ] && [ "$len" -lt 200 ] && printf "$(printf '%s' "${h:128:$((len * 2))}" | sed 's/../\\x&/g')" || printf ''; }
# envval <file> <KEY> -> the value of KEY=... in a dotenv file (last one wins), without quotes
envval() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
# a `bytes` return value (gameArgs): the data as hex, without 0x
bytes_ret() { local h len; h="$(printf '%s' "$1" | sed 's/^0x//')"; len="$(word_n "0x$h" 1)"; printf '%s' "${h:128:$((len * 2))}"; }
# decode packed game arguments: absolutePrestate(32) vm(20) anchorStateRegistry(20) weth(20) l2ChainId(32) [proposer(20) challenger(20)]
decode_args() {
  local a="$1"
  if [ -z "$a" ]; then echo null; return; fi
  jq -cn --arg a "$a" '
    def hexnum: ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d);
    ($a | length / 2) as $n |
    {bytes: $n, absolutePrestate: ("0x" + $a[0:64]), vm: ("0x" + $a[64:104]), anchorStateRegistry: ("0x" + $a[104:144]), weth: ("0x" + $a[144:184]),
     l2ChainId: ($a[184:248] | hexnum)}
    + (if $n >= 164 then {proposer: ("0x" + $a[248:288]), challenger: ("0x" + $a[288:328])} else {} end)'
}

log "reading Finchain (chain id $L2_CHAIN_ID, CHAIN=$CHAIN) through $L1_LABEL"
owner="$(word_addr "$(ecall "$DGF" "$S_OWNER")" 0)"
count="$(word_n "$(ecall "$DGF" "$S_GAME_COUNT")" 0)"
dgf_version="$(str_ret "$(ecall "$DGF" "$S_VERSION")")"
impl1="$(word_addr "$(ecall "$DGF" "${S_GAME_IMPLS}$(pad_u 1)")" 0)"
implN="$(word_addr "$(ecall "$DGF" "${S_GAME_IMPLS}$(pad_u "$GAME_TYPE")")" 0)"
args1="$(bytes_ret "$(ecall "$DGF" "${S_GAME_ARGS}$(pad_u 1)")")"
argsN="$(bytes_ret "$(ecall "$DGF" "${S_GAME_ARGS}$(pad_u "$GAME_TYPE")")")"
bond1="$(word_n "$(ecall "$DGF" "${S_INIT_BONDS}$(pad_u 1)")" 0)"
bondN="$(word_n "$(ecall "$DGF" "${S_INIT_BONDS}$(pad_u "$GAME_TYPE")")" 0)"
respected_asr="$(word_n "$(ecall "$ASR" "$S_RESPECTED")" 0)"
respected_portal="$(word_n "$(ecall "$PORTAL" "$S_RESPECTED")" 0)"
anchor_raw="$(ecall "$ASR" "$S_ANCHOR")"; anchor_root="$(word_hex "$anchor_raw" 0)"; anchor_block="$(word_n "$anchor_raw" 1)"
asr_version="$(str_ret "$(ecall "$ASR" "$S_VERSION")")"
finality="$(word_n "$(ecall "$ASR" "$S_FINALITY")" 0)"
proof_maturity="$(word_n "$(ecall "$PORTAL" "$S_PROOF_MATURITY")" 0)"
impl_version="$(str_ret "$(ecall "$IMPL" "$S_VERSION")")"
pimpl_version="$(str_ret "$(ecall "$PIMPL" "$S_VERSION")")"
max_depth="$(word_n "$(ecall "$IMPL" "$S_MAX_DEPTH")" 0)"; split_depth="$(word_n "$(ecall "$IMPL" "$S_SPLIT")" 0)"
clock_ext="$(word_n "$(ecall "$IMPL" "$S_EXT")" 0)"; max_clock="$(word_n "$(ecall "$IMPL" "$S_MAX_CLOCK")" 0)"
mips_version="$(str_ret "$(ecall "$MIPS" "$S_VERSION")")"; state_version="$(word_n "$(ecall "$MIPS" "$S_STATE_VERSION")" 0)"
oracle="$(word_addr "$(ecall "$MIPS" "$S_ORACLE")" 0)"
oracle_version="$(str_ret "$(ecall "$oracle" "$S_VERSION")")"
challenge_period="$(word_n "$(ecall "$oracle" "$S_CHALLENGE_PERIOD")" 0)"; min_proposal="$(word_n "$(ecall "$oracle" "$S_MIN_PROPOSAL")" 0)"
weth_delay="$(word_n "$(ecall "$WETH" "$S_DELAY")" 0)"
args1_dec="$(decode_args "$args1")"; argsN_dec="$(decode_args "$argsN")"

# the K2 records: prestate and kona-host for this chain (the newest record of each)
prestate_rec="$(find "$FINCHAIN_ROOT/manifests/evidence" -maxdepth 1 -name "prestate-$L2_CHAIN_ID-*.json" 2>/dev/null | sort | tail -1 || true)"
konahost_rec="$(find "$FINCHAIN_ROOT/manifests/evidence" -maxdepth 1 -name "kona-host-$L2_CHAIN_ID-*.json" 2>/dev/null | sort | tail -1 || true)"
[ -n "$prestate_rec" ] || die "no prestate record for chain $L2_CHAIN_ID in manifests/evidence (K2a first)"
prestate_hash="$(jq -r '.prestate.hash' "$prestate_rec")"; prestate_file="$(jq -r '.prestate.file' "$prestate_rec")"; prestate_proof="$(jq -r '.prestate.proof' "$prestate_rec")"
prestate_tag="$(jq -r '.source.tag' "$prestate_rec")"; prestate_state_type="$(jq -r '.source.stateType' "$prestate_rec")"
prestate_present=false; prestate_sha=""
if [ -f "$FINCHAIN_ROOT/$prestate_file" ]; then prestate_present=true; prestate_sha="$(sha256_of "$FINCHAIN_ROOT/$prestate_file")"; fi
proof_present=false; [ ! -f "$FINCHAIN_ROOT/$prestate_proof" ] || proof_present=true
konahost_file=""; konahost_sha=""; konahost_present=false; konahost_match=false; konahost_sha_now=""
if [ -n "$konahost_rec" ]; then
  konahost_file="$(jq -r '.binary.file' "$konahost_rec")"; konahost_sha="$(jq -r '.binary.sha256' "$konahost_rec")"
  if [ -f "$FINCHAIN_ROOT/$konahost_file" ]; then konahost_present=true; konahost_sha_now="$(sha256_of "$FINCHAIN_ROOT/$konahost_file")"; [ "$konahost_sha_now" != "$konahost_sha" ] || konahost_match=true; fi
fi
# the executable copy node-b/docker-compose.kona.yml mounts (make kona-host writes it; the repository copy is not executable on the hosts)
wrapper_present=false; [ ! -x "$FINCHAIN_ROOT/drill/out/bin/kona-host-wrapper.sh" ] || wrapper_present=true

# the installation: packed arguments and the two owner transactions
args_new="$(printf '%s%s%s%s%s' "$(printf '%s' "$prestate_hash" | sed 's/^0x//')" "$(printf '%s' "$MIPS" | sed 's/^0x//')" "$(printf '%s' "$ASR" | sed 's/^0x//')" "$(printf '%s' "$WETH" | sed 's/^0x//')" "$(pad_u "$L2_CHAIN_ID")" | tr '[:upper:]' '[:lower:]')"
[ "${#args_new}" -eq 248 ] || die "packed arguments have ${#args_new} hex characters, expected 248 (124 bytes)"
# setImplementation(uint32,address,bytes): type, impl, offset 0x60, length 124, data padded to 128 bytes
calldata_impl="${S_SET_IMPL}$(pad_u "$GAME_TYPE")$(pad_a "$IMPL")$(pad_u 96)$(pad_u 124)${args_new}00000000"
calldata_bond="${S_SET_INIT_BOND}$(pad_u "$GAME_TYPE")$(pad_u "$INIT_BOND_WEI")"
installed=false; args_match=false
[ "$(lower "$implN")" = "0x0000000000000000000000000000000000000000" ] || installed=true
[ "$(lower "$argsN")" != "$args_new" ] || args_match=true
anchor_moved=true; [ "$(lower "$anchor_root")" != "$DEAD_ROOT" ] || anchor_moved=false

# the challenger host, when this runs on it
benv="$(host_env b)"; on_b=false; chall_l1=""; chall_l1_label=""; raw_header=unknown; raw_receipts=unknown; l2_proof=unknown; trace_types="[]"; proof_window=""; update_interval=""; game_window=""
if [ -f "$benv" ]; then
  on_b=true
  chall_l1="$(envval "$benv" CHALLENGER_L1_RPC_URL)"; [ -n "$chall_l1" ] || chall_l1="$(envval "$benv" L1_RPC_URL)"
  chall_l1_label="$(rpc_label "$chall_l1")"
  probe() { local r; r="$(rpc "$chall_l1" "$1" "$2" 2>/dev/null || true)"; if jq -e '.result != null' <<<"$r" >/dev/null 2>&1; then echo served; else jq -r '.error.message // "no answer"' <<<"$r" 2>/dev/null | cut -c1-80; fi; }
  raw_header="$(probe debug_getRawHeader '["latest"]')"
  raw_receipts="$(probe debug_getRawReceipts '["latest"]')"
  bind_ip="$(envval "$benv" B_BIND_IP)"; rpc_port="$(envval "$benv" B_RPC_PORT)"
  l2_url="http://${bind_ip:-127.0.0.1}:${rpc_port:-8545}"
  head_hex="$(rpc "$l2_url" eth_blockNumber '[]' 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
  if [ -n "$head_hex" ]; then
    old=$(( head_hex - 50000 )); [ "$old" -gt 0 ] || old=1
    pr="$(rpc "$l2_url" eth_getProof "[\"$DGF\",[],\"$(printf '0x%x' "$old")\"]" 2>/dev/null || true)"
    if jq -e '.result != null' <<<"$pr" >/dev/null 2>&1; then l2_proof="served at block $old"; else l2_proof="$(jq -r '.error.message // "no answer"' <<<"$pr" 2>/dev/null | cut -c1-80) (block $old)"; fi
  else
    l2_proof="op-reth not reachable at $l2_url from here"
  fi
  # the trace types, update interval and game window of this chain's running challenger (its container arguments; the
  # stack's name keeps a second chain's challenger apart), else of the compose files (the defaults there; .env may
  # override the last two)
  trace_types=""; cargs=""
  if command -v docker >/dev/null 2>&1; then
    cname="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^$STACK-b-op-challenger-" | head -1 || true)"
    [ -z "$cname" ] || cargs="$(docker inspect "$cname" --format '{{join .Args "\n"}}' 2>/dev/null || true)"
    [ -z "$cargs" ] || trace_types="$(grep -o -- '--trace-type=[a-z,-]*' <<<"$cargs" | sed 's/--trace-type=//' | tr ',' '\n' | jq -R . | jq -cs . || true)"
  fi
  [ -n "$trace_types" ] && [ "$trace_types" != "[]" ] || trace_types="$(grep -ho -- '--trace-type=[a-z,-]*' "$FINCHAIN_ROOT/node-b/docker-compose.yml" | sed 's/--trace-type=//' | tr ',' '\n' | jq -R . | jq -cs .)"
  update_interval="$(grep -o -- '--min-update-interval=[0-9a-z]*' <<<"$cargs" | sed 's/.*=//' | head -1 || true)"
  game_window="$(grep -o -- '--game-window=[0-9a-z]*' <<<"$cargs" | sed 's/.*=//' | head -1 || true)"
  [ -n "$update_interval" ] || update_interval="$(grep -ho -- '--min-update-interval=[^}]*:-[0-9a-z]*}' "$FINCHAIN_ROOT/node-b/docker-compose.yml" | sed 's/.*:-//; s/}//' | head -1 || true)"
  [ -n "$game_window" ] || game_window="$(grep -ho -- '--game-window=[^}]*:-[0-9a-z]*}' "$FINCHAIN_ROOT/node-b/docker-compose.yml" | sed 's/.*:-//; s/}//' | head -1 || true)"
  [ -n "$update_interval" ] || update_interval="upstream default (every L1 block)"
  [ -n "$game_window" ] || game_window="upstream default (672h)"
  proof_window="$(grep -ho -- '--rpc.eth-proof-window=[0-9]*' "$FINCHAIN_ROOT/node-b/docker-compose.yml" | sed 's/.*=//' | head -1)"
fi
# room for the K2 builds on this host (the prestate build needs about 15 GB free, the kona-host build about 10 GB)
free_gb="$(df -Pk "$FINCHAIN_ROOT" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }' || echo "")"
cores="$(nproc 2>/dev/null || echo "")"; mem_gb="$(awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null || echo "")"

# the verdict
items="$(jq -cn \
  --argjson anchor "$anchor_moved" --argjson installed "$installed" --argjson argsmatch "$args_match" --argjson sv "$state_version" \
  --argjson pre "$prestate_present" --argjson kh "$konahost_present" --argjson khm "$konahost_match" --argjson onb "$on_b" \
  --arg rawh "$raw_header" --arg rawr "$raw_receipts" --arg l2p "$l2_proof" --argjson tt "$trace_types" --argjson wrapper "$wrapper_present" '
  [ {item: "anchor root off the placeholder (a Type 8 game is playable only then)", status: (if $anchor then "ready" else "pending" end)},
    {item: "MIPS64 state version 8 (Cannon64, the kona prestate format)", status: (if $sv == 8 then "ready" else "missing" end)},
    {item: "game type installed with the Finchain-embedding prestate", status: (if $installed and $argsmatch then "ready" elif $installed then "installed with other arguments" else "pending: owner transaction (owner-console.html)" end)},
    {item: "prestate file on this host", status: (if $pre then "ready" else "missing (make prestate reproduces it)" end)},
    {item: "embedded kona-host on this host", status: (if $kh and $khm then "ready" elif $kh then "present, digest differs from the K2 record" else "missing (make kona-host reproduces it)" end)},
    {item: "executable kona-host wrapper beside it (drill/out/bin/kona-host-wrapper.sh)", status: (if $wrapper then "ready" else "missing (make kona-host writes it)" end)} ]
  + (if $onb then
      [ {item: "challenger L1 endpoint serves debug_getRawHeader", status: (if $rawh == "served" then "ready" else ("missing: " + $rawh) end)},
        {item: "challenger L1 endpoint serves debug_getRawReceipts", status: (if $rawr == "served" then "ready" else ("missing: " + $rawr) end)},
        {item: "op-reth answers eth_getProof at an old block", status: (if ($l2p | startswith("served")) then "ready" else ("missing: " + $l2p) end)},
        {item: "challenger trace types include cannon-kona", status: (if ($tt | index("cannon-kona")) then "ready" else "pending: KONA=1 (node-b/docker-compose.kona.yml)" end)} ]
     else [] end)')"
summary="$(jq -r '[.[] | select(.status != "ready")] | length' <<<"$items")"

out="$FINCHAIN_ROOT/manifests/evidence/k4-readiness-$(date -u +%Y%m%dT%H%M%SZ).json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg l1 "$L1_LABEL" --argjson cid "$L2_CHAIN_ID" --arg host "$(hostname)" --argjson onb "$on_b" --arg env "$ENVIRONMENT" \
  --arg dgf "$DGF" --arg dgfv "$dgf_version" --arg owner "$owner" --argjson count "$count" --argjson gt "$GAME_TYPE" \
  --arg impl1 "$impl1" --arg implN "$implN" --argjson args1 "$args1_dec" --argjson argsN "$argsN_dec" --arg args1raw "$args1" --arg argsNraw "$argsN" --arg bond1 "$bond1" --arg bondN "$bondN" \
  --arg asr "$ASR" --arg asrv "$asr_version" --argjson rasr "$respected_asr" --argjson rportal "$respected_portal" --arg aroot "$anchor_root" --argjson ablock "$anchor_block" --argjson amoved "$anchor_moved" \
  --argjson finality "$finality" --argjson maturity "$proof_maturity" --arg portal "$PORTAL" \
  --arg impl "$IMPL" --arg implv "$impl_version" --arg pimpl "$PIMPL" --arg pimplv "$pimpl_version" --argjson maxd "$max_depth" --argjson splitd "$split_depth" --argjson ext "$clock_ext" --argjson maxc "$max_clock" \
  --arg mips "$MIPS" --arg mipsv "$mips_version" --argjson sv "$state_version" --arg oracle "$oracle" --arg oraclev "$oracle_version" --argjson cp "$challenge_period" --argjson minp "$min_proposal" \
  --arg weth "$WETH" --argjson delay "$weth_delay" \
  --arg prerec "${prestate_rec#"$FINCHAIN_ROOT"/}" --arg prehash "$prestate_hash" --arg prefile "$prestate_file" --arg preproof "$prestate_proof" --arg pretag "$prestate_tag" --arg prest "$prestate_state_type" \
  --argjson prepresent "$prestate_present" --arg presha "$prestate_sha" --argjson proofpresent "$proof_present" \
  --arg khrec "${konahost_rec#"$FINCHAIN_ROOT"/}" --arg khfile "$konahost_file" --arg khsha "$konahost_sha" --argjson khpresent "$konahost_present" --arg khnow "$konahost_sha_now" --argjson khmatch "$konahost_match" --argjson wrapper "$wrapper_present" \
  --arg argsnew "$args_new" --arg cimpl "$calldata_impl" --arg cbond "$calldata_bond" --arg bondwei "$INIT_BOND_WEI" --argjson installed "$installed" --argjson argsmatch "$args_match" \
  --arg challl1 "$chall_l1_label" --arg rawh "$raw_header" --arg rawr "$raw_receipts" --arg l2p "$l2_proof" --argjson tt "$trace_types" --arg pw "$proof_window" --arg ui "$update_interval" --arg gw "$game_window" \
  --arg freegb "$free_gb" --arg cores "$cores" --arg memgb "$mem_gb" \
  --argjson items "$items" --argjson open "$summary" '
  def num: if . == "" then null else tonumber end;
  {schema: "finchain.k4-readiness/1",
   acceptance: "M4 K4: minimal integration check against the public chain - what a Type 8 (CANNON_KONA) implementation needs there, read back from the chain and the challenger host; the respected game type unchanged (docs/acceptance.md M4; docs/proof-plan.md K4)",
   environment: $env, chainId: $cid, recordedAt: $at, l1Rpc: $l1, host: {name: $host, challengerHost: $onb, cores: ($cores | num), memoryGb: ($memgb | num), freeDiskGb: ($freegb | num)},
   factory: {address: $dgf, version: $dgfv, owner: $owner, gameCount: $count,
             gameType1: {implementation: $impl1, initBondWei: $bond1, args: $args1, argsHex: ("0x" + $args1raw)},
             gameTypeTarget: {gameType: $gt, implementation: $implN, initBondWei: $bondN, args: $argsN, argsHex: (if $argsNraw == "" then null else "0x" + $argsNraw end), installed: $installed, argsMatchPlan: $argsmatch}},
   anchorStateRegistry: {address: $asr, version: $asrv, respectedGameType: $rasr, respectedGameTypeAtPortal: $rportal, anchorRoot: $aroot, anchorL2Block: $ablock, leftPlaceholder: $amoved, disputeGameFinalityDelaySeconds: $finality},
   portal: {address: $portal, proofMaturityDelaySeconds: $maturity},
   implementation: {address: $impl, version: $implv, maxGameDepth: $maxd, splitDepth: $splitd, clockExtension: $ext, maxClockDuration: $maxc, permissionedImplementation: {address: $pimpl, version: $pimplv},
                    note: "the shared FaultDisputeGame implementation; a game type is this implementation plus the arguments the factory stores for it"},
   vm: {address: $mips, version: $mipsv, stateVersion: $sv, preimageOracle: {address: $oracle, version: $oraclev, challengePeriod: $cp, minProposalSize: $minp}},
   weth: {address: $weth, delaySeconds: $delay},
   prestate: {record: $prerec, hash: $prehash, tag: $pretag, stateType: $prest, file: $prefile, proof: $preproof, presentOnThisHost: $prepresent, fileSha256: (if $presha == "" then null else $presha end), proofPresentOnThisHost: $proofpresent},
   konaHost: {record: (if $khrec == "" then null else $khrec end), file: (if $khfile == "" then null else $khfile end), recordSha256: (if $khsha == "" then null else $khsha end), presentOnThisHost: $khpresent, sha256OnThisHost: (if $khnow == "" then null else $khnow end), matchesRecord: $khmatch, wrapperPresent: $wrapper},
   install: {gameType: $gt, implementation: $impl, argsHex: ("0x" + $argsnew), argsLayout: "absolutePrestate(32) vm(20) anchorStateRegistry(20) weth(20) l2ChainId(32) - op-challenger gameargs.PackPermissionless, 124 bytes",
             transactions: [{call: ("setImplementation(" + ($gt|tostring) + ", " + $impl + ", args)"), to: $dgf, value: "0", calldata: $cimpl},
                            {call: ("setInitBond(" + ($gt|tostring) + ", " + $bondwei + ")"), to: $dgf, value: "0", calldata: $cbond}],
             sender: "the factory owner, signed in the browser wallet (owner-console.html); the respected game type is not touched",
             initBondWei: $bondwei},
   challengerHostChecks: (if $onb then {challengerL1Rpc: $challl1, debugGetRawHeader: $rawh, debugGetRawReceipts: $rawr, ethGetProofOldBlock: $l2p, traceTypesConfigured: $tt, minUpdateInterval: $ui, gameWindow: $gw, rethProofWindow: ($pw | num)} else null end),
   verdict: {items: $items, open: $open, summary: (if $open == 0 then "ready" else (($open|tostring) + " item(s) not ready") end)}}' > "$out"

echo "K4 readiness for chain $L2_CHAIN_ID through $L1_LABEL (record $out)"
echo "  factory $DGF v$dgf_version, owner $owner, $count games; respected type $respected_asr (ASR) / $respected_portal (portal)"
echo "  anchor root $anchor_root at L2 block $anchor_block $([ "$anchor_moved" = true ] && echo '(off the placeholder)' || echo '(op-deployer placeholder: a Type 8 game is not playable yet)')"
echo "  implementation $IMPL v$impl_version (depths $max_depth/$split_depth, clocks $clock_ext/$max_clock); MIPS $MIPS v$mips_version state version $state_version; oracle $oracle v$oracle_version (challenge $challenge_period s, min proposal $min_proposal B); WETH delay $weth_delay s"
echo "  type $GAME_TYPE: implementation $implN$([ "$installed" = true ] && echo " (installed$([ "$args_match" = true ] && echo ', arguments as planned' || echo ', OTHER arguments'))" || echo ' (not installed)'), init bond $bondN wei"
echo "  prestate $prestate_hash: file $([ "$prestate_present" = true ] && echo present || echo MISSING) on this host; kona-host $([ "$konahost_present" = true ] && echo "present$([ "$konahost_match" = true ] && echo ', digest matches the record' || echo ', DIGEST DIFFERS')" || echo MISSING)"
if [ "$on_b" = true ]; then echo "  challenger host: L1 $chall_l1_label debug_getRawHeader: $raw_header; debug_getRawReceipts: $raw_receipts; eth_getProof: $l2_proof; trace types $trace_types; update interval $update_interval; game window $game_window"; fi
echo "  verdict: $(jq -r '.verdict.summary' "$out")"
jq -r '.verdict.items[] | "    - \(.item): \(.status)"' "$out"
