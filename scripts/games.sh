#!/usr/bin/env bash
# M4: the dispute games of the public testnet as the chain holds them, and what the resident challenger did with them
# (docs/acceptance.md M4, "resident challenger running on host B against the public chain; games resolved and bonds
# claimed"; docs/proof-plan.md, level L1). Reads the DisputeGameFactory and every game of the respected type through
# the L1 RPC - creation, L2 block claimed, root claim, status, resolution and who sent the resolving transaction, the
# credit each party holds, the bonds - and writes manifests/evidence/games-<date>.json. Pair it with the challenger's
# own log on host B (make logs-b SVC=op-challenger, or docker logs) for the service-side view.
#
# Usage: scripts/games.sh [l1-rpc] [last-n=all]
#   The L1 RPC: the argument, else L1_RPC_URL in the environment, else node-b/.env, else .env. This is op-node's
#   endpoint on host B, not the challenger's own (CHALLENGER_L1_RPC_URL), so the reads here do not compete with the
#   service; the report and the terminal name the endpoint by scheme and host only.
#   EXTRA_TYPES=8 (comma-separated) also reads games of other types - the Type 8 (CANNON_KONA) games of K4 - with the
#   fields a permissionless game has: creator, prestate, VM, starting root, status, resolution, credit of creator and
#   challenger. Other types stay listed as "not read".
# Reads the chain only (curl + jq; no key, no docker, no cast): plain eth_call with the selectors below.

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
L1_LABEL="$(rpc_label "$L1")"   # what is printed and recorded: scheme and host, never a provider path or key
# the endpoint must be the chain's L1: a second chain's env is a copy of the example until edited, and an answer of
# "0x" from the wrong L1 is otherwise mistaken for a revert (docs/runbook.md section 9)
l1_want="$(grep -E '^L1_CHAIN_ID=' "$FINCHAIN_ROOT/.env$ENV_SUFFIX" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
if [ -n "$l1_want" ]; then
  l1_got="$(rpc "$L1" eth_chainId '[]' 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
  [ -n "$l1_got" ] || die "$L1_LABEL did not answer eth_chainId"
  [ "$((l1_got))" = "$((l1_want))" ] || die "$L1_LABEL is L1 chain $((l1_got)), but CHAIN=$CHAIN settles on L1 chain $l1_want (.env$ENV_SUFFIX): pass the right endpoint (L1_RPC_URL=...)"
fi
LAST="${2:-all}"
REC="$CHAIN_DIR/out/chain-record.json"; [ -f "$REC" ] || die "chain record not found: $REC (CHAIN=$CHAIN; make export first)"
DGF="$(jq -r '.l1.DisputeGameFactoryProxy // empty' "$REC")"; PORTAL="$(jq -r '.l1.OptimismPortalProxy // empty' "$REC")"
[ -n "$DGF" ] && [ -n "$PORTAL" ] || die "DisputeGameFactoryProxy / OptimismPortalProxy missing in $REC"
DEPLOY_BLOCK="$(jq -r '.l1Anchor.number' "$REC")"

# selectors (cast sig): the calls this script makes, decoded by hand from the 32-byte words they return
SEL_GAME_COUNT=0x4d1975b4      # gameCount()
SEL_GAME_AT=0xbb8aa1fc         # gameAtIndex(uint256) -> (GameType, Timestamp, IDisputeGame)
SEL_INIT_BONDS=0x6593dc6e      # initBonds(uint32)
SEL_RESPECTED=0x3c9f397c       # respectedGameType() (portal)
SEL_STATUS=0x200d2ed2          # status() -> 0 IN_PROGRESS, 1 CHALLENGER_WINS, 2 DEFENDER_WINS
SEL_RESOLVED_AT=0x19effeb4     # resolvedAt()
SEL_ROOT_CLAIM=0xbcef3b55      # rootClaim()
SEL_EXTRA_DATA=0x609d3334      # extraData() -> abi.encode(l2BlockNumber)
SEL_CLAIM_LEN=0x8980e0cc       # claimDataLen()
SEL_CREDIT=0xd5d44d80          # credit(address)
SEL_PROPOSER=0xa8e4fb90        # proposer() (permissioned game)
SEL_CHALLENGER=0x534db0e2      # challenger() (permissioned game)
SEL_MAX_CLOCK=0xdabd396d       # maxClockDuration()
SEL_CREATOR=0x37b1b229         # gameCreator()
SEL_PRESTATE=0x8d450a95        # absolutePrestate()
SEL_VM=0x3a768463              # vm()
SEL_STARTING_ROOT=0x25fc2ace   # startingRootHash()
SEL_STARTING_BLOCK=0x70872aa5  # startingBlockNumber()
EXTRA_TYPES="${EXTRA_TYPES:-}"
TOPIC_RESOLVED=0x5e186f09b9c93491f14e277eea7faa5de6a2d4bda75a79af7a3684fbfb42da60   # Resolved(GameStatus indexed)
# the bond's way back (op-contracts v7): resolve() decides the game and records the credit; claimCredit(recipient)
# closes the game first (closeGame: only once the game is finalized under the anchor state registry's rules - resolved
# and past the dispute game finality delay - which also moves the anchor when the game qualifies), and its first call
# unlocks the credit in DelayedWETH; a claimCredit after the WETH delay withdraws it and pays the recipient. Three waits.
SEL_BOND_MODE=0x378dd48c       # bondDistributionMode() -> 0 UNDECIDED (not closed), 1 NORMAL, 2 REFUND
SEL_WETH=0x3fc8cef3            # weth() -> the game's DelayedWETH
SEL_WETH_WITHDRAWALS=0xcd47bde1  # DelayedWETH.withdrawals(game, recipient) -> (amount, timestamp): the unlock, amount 0 once paid
SEL_WETH_DELAY=0x6a42b8f8      # DelayedWETH.delay()
SEL_ANCHOR=0xd83ef267          # AnchorStateRegistry.getAnchorRoot() -> (root, l2BlockNumber)
TOPIC_WITHDRAWAL=0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65  # WETH Withdrawal(address indexed src, uint256 wad): src is the game

# ecall <to> <data> -> the raw hex result. A public endpoint drops or rate-limits a burst of requests, so an error or an
# empty answer is asked again (six attempts in all, with a growing pause) before the script gives up on the call.
ecall() {
  local attempt raw r
  for attempt in 1 2 3 4 5 6; do
    raw="$(rpc "$L1" eth_call "[{\"to\":\"$1\",\"data\":\"$2\"},\"latest\"]" 2>/dev/null || true)"
    r="$(jq -r '.result // empty' <<<"$raw" 2>/dev/null || true)"
    if [ -n "$r" ] && [ "$r" != "0x" ]; then echo "$r"; return 0; fi
    sleep $((attempt * 2))
  done
  die "eth_call to $1 (${2:0:10}) answered nothing six times (a revert, or the endpoint $L1_LABEL is refusing the burst; last answer: $(printf '%s' "$raw" | cut -c1-200))"
}
# rpcq <method> <params> -> the result as JSON, asked again on an error or an empty answer like ecall
rpcq() {
  local attempt raw r
  for attempt in 1 2 3 4 5 6; do
    raw="$(rpc "$L1" "$1" "$2" 2>/dev/null || true)"
    r="$(jq -c 'if .error then empty else .result end' <<<"$raw" 2>/dev/null || true)"
    if [ -n "$r" ] && [ "$r" != "null" ]; then echo "$r"; return 0; fi
    sleep $((attempt * 2))
  done
  die "$1 answered nothing six times on $L1_LABEL (last answer: $(printf '%s' "$raw" | cut -c1-200))"
}
# rpc_try <attempts> <method> <params> -> the result as JSON, or a non-zero status after <attempts> (never dies)
rpc_try() {
  local attempts="$1" method="$2" params="$3" attempt raw r
  for attempt in $(seq 1 "$attempts"); do
    raw="$(rpc "$L1" "$method" "$params" 2>/dev/null || true)"
    r="$(jq -c 'if .error then empty else .result end' <<<"$raw" 2>/dev/null || true)"
    if [ -n "$r" ] && [ "$r" != "null" ]; then echo "$r"; return 0; fi
    sleep "$attempt"
  done
  return 1
}
word_n() { printf '%d' "0x$(printf '%s' "$1" | cut -c$((3 + 64 * $2))-$((2 + 64 * ($2 + 1))))"; }   # word_n <hex> <i> -> integer (fits 64 bits)
word_addr() { echo "0x$(printf '%s' "$1" | cut -c$((27 + 64 * $2))-$((2 + 64 * ($2 + 1))))"; }
word_hex() { echo "0x$(printf '%s' "$1" | cut -c$((3 + 64 * $2))-$((2 + 64 * ($2 + 1))))"; }
pad_u() { printf '%064x' "$1"; }
pad_a() { printf '%064s' "$(printf '%s' "$1" | sed 's/^0x//')" | tr ' ' 0; }
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
status_name() { case "$1" in 0) echo IN_PROGRESS ;; 1) echo CHALLENGER_WINS ;; 2) echo DEFENDER_WINS ;; *) echo "unknown($1)" ;; esac; }
lower() { tr '[:upper:]' '[:lower:]'; }
sender_role() { # which role an L1 sender is: challenger, proposer or other
  local a; a="$(printf '%s' "$1" | lower)"
  if [ "$a" = "$(printf '%s' "$challenger_addr" | lower)" ]; then echo challenger
  elif [ "$a" = "$(printf '%s' "$proposer_addr" | lower)" ]; then echo proposer
  else echo other; fi
}
block_ts() { rpcq eth_getBlockByNumber "[\"$(printf '0x%x' "$1")\",false]" | jq -r '.timestamp' | xargs printf '%d'; }
# block_at_ts <timestamp> -> the first L1 block whose timestamp is not below it (a binary search over block headers,
# about 15 header reads between the deployment block and the head); the game's resolvedAt is the timestamp of the
# block that carried the resolving transaction, so that block is found exactly, missed slots or not.
block_at_ts() {
  local ts="$1" lo="$DEPLOY_BLOCK" hi="$latest" mid mts
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi) / 2)); mts="$(block_ts "$mid" 2>/dev/null || true)"
    [ -n "$mts" ] || return 1
    if [ "$mts" -lt "$ts" ]; then lo=$((mid + 1)); else hi="$mid"; fi
  done
  echo "$lo"
}
# resolved_log <proxy> <resolvedAt> -> the game's Resolved log: first in the two blocks around the block found for the
# resolution timestamp, then - should a header read fail - in a window estimated at 12 s per slot around that time,
# padded for missed slots and widened once. A public endpoint refuses or prunes wide eth_getLogs ranges ("pruned history
# unavailable"), so the windows stay narrow; empty when not found.
resolved_log() {
  local proxy="$1" at="$2" est dist pad from to lg exact
  if exact="$(block_at_ts "$at")"; then
    from=$((exact - 1)); [ "$from" -lt "$DEPLOY_BLOCK" ] && from="$DEPLOY_BLOCK"
    to=$((exact + 1)); [ "$to" -gt "$latest" ] && to="$latest"
    lg="$(rpc_try 3 eth_getLogs "[{\"address\":\"$proxy\",\"topics\":[\"$TOPIC_RESOLVED\"],\"fromBlock\":\"$(printf '0x%x' "$from")\",\"toBlock\":\"$(printf '0x%x' "$to")\"}]" | jq -c '.[0] // empty' || true)"
    if [ -n "$lg" ]; then echo "$lg"; return 0; fi
  fi
  est=$((latest - (latest_ts - at) / 12)); [ "$est" -lt "$DEPLOY_BLOCK" ] && est="$DEPLOY_BLOCK"
  dist=$((latest - est))
  for pad in $((300 + dist / 30)) $((1200 + dist / 8)); do
    from=$((est - pad)); [ "$from" -lt "$DEPLOY_BLOCK" ] && from="$DEPLOY_BLOCK"
    to=$((est + pad)); [ "$to" -gt "$latest" ] && to="$latest"
    lg="$(rpc_try 3 eth_getLogs "[{\"address\":\"$proxy\",\"topics\":[\"$TOPIC_RESOLVED\"],\"fromBlock\":\"$(printf '0x%x' "$from")\",\"toBlock\":\"$(printf '0x%x' "$to")\"}]" | jq -c '.[0] // empty' || true)"
    if [ -n "$lg" ]; then echo "$lg"; return 0; fi
  done
  return 1
}

# logs_first <address> <topics (JSON array)> <from> <to> -> the first log in [from, to], read in windows a public endpoint accepts
logs_first() {
  local addr="$1" topics="$2" a="$3" to="$4" b lg
  while [ "$a" -le "$to" ]; do
    b=$((a + 3999)); [ "$b" -gt "$to" ] && b="$to"
    lg="$(rpc_try 3 eth_getLogs "[{\"address\":\"$addr\",\"topics\":$topics,\"fromBlock\":\"$(printf '0x%x' "$a")\",\"toBlock\":\"$(printf '0x%x' "$b")\"}]" | jq -c '.[0] // empty' || true)"
    if [ -n "$lg" ]; then echo "$lg"; return 0; fi
    a=$((b + 1))
  done
  return 1
}
# bond_cycle <proxy> <recipient> <status> -> JSON: whether the game is closed (bondDistributionMode set), the DelayedWETH
# unlock of the recipient's credit (amount left, unlock time) and, once paid, the paying transaction (the WETH Withdrawal
# log of this game, searched from the end of the WETH delay); null fields while the game is in progress
weth_delay=""
bond_cycle() {
  local proxy="$1" who="$2" st="$3" mode closed weth wd amount uts claim=null from_b lg ctx cblock cfrom
  if [ "$st" = "0" ]; then echo '{"closed": false, "bondDistributionMode": 0, "wethUnlock": null, "claim": null}'; return; fi
  mode="$(word_n "$(ecall "$proxy" "$SEL_BOND_MODE")" 0)"; closed=false; [ "$mode" = "0" ] || closed=true
  weth="$(word_addr "$(ecall "$proxy" "$SEL_WETH")" 0)"
  [ -n "$weth_delay" ] || weth_delay="$(word_n "$(ecall "$weth" "$SEL_WETH_DELAY")" 0)"
  wd="$(ecall "$weth" "${SEL_WETH_WITHDRAWALS}$(pad_a "$proxy")$(pad_a "$who")")"; amount="$(word_n "$wd" 0)"; uts="$(word_n "$wd" 1)"
  if [ "$closed" = true ] && [ "$amount" = "0" ] && [ "$uts" != "0" ]; then
    from_b="$(block_at_ts "$((uts + weth_delay))" 2>/dev/null || echo "$DEPLOY_BLOCK")"; from_b=$((from_b - 5)); [ "$from_b" -lt "$DEPLOY_BLOCK" ] && from_b="$DEPLOY_BLOCK"
    if lg="$(logs_first "$weth" "[\"$TOPIC_WITHDRAWAL\",\"0x$(pad_a "$proxy")\"]" "$from_b" "$latest")"; then
      ctx="$(jq -r .transactionHash <<<"$lg")"; cblock=$(( $(jq -r .blockNumber <<<"$lg") ))
      cfrom="$(rpcq eth_getTransactionByHash "[\"$ctx\"]" | jq -r '.from // ""')"
      claim="$(jq -cn --arg tx "$ctx" --argjson b "$cblock" --arg from "$cfrom" --arg who "$(sender_role "$cfrom")" --arg at "$(iso_of "$(block_ts "$cblock")")" --arg wad "$(word_n "$(jq -r .data <<<"$lg")" 0)" \
        '{tx: $tx, l1Block: $b, from: $from, sender: $who, at: $at, paidWei: $wad}')"
    fi
  fi
  jq -cn --argjson closed "$closed" --argjson mode "$mode" --arg amount "$amount" --argjson uts "$uts" --argjson claim "$claim" \
    '{closed: $closed, bondDistributionMode: $mode, wethUnlock: (if $uts == 0 then null else {amountLeftWei: $amount, unlockedAt: $uts, unlocked: ($uts | todate)} end), claim: $claim}'
}
bond_marks() { # bond_marks <bond JSON> -> the markers of the table line
  local m=""; [ "$(jq -r .closed <<<"$1")" != "true" ] || m=" closed"
  [ "$(jq -r '.claim.tx // empty' <<<"$1")" = "" ] || m="$m paid $(jq -r '.claim.tx' <<<"$1" | cut -c1-10)... by $(jq -r '.claim.sender' <<<"$1")"
  printf '%s' "$m"
}

count="$(word_n "$(ecall "$DGF" "$SEL_GAME_COUNT")" 0)"
respected="$(word_n "$(ecall "$PORTAL" "$SEL_RESPECTED")" 0)"
ASR="$(jq -r '.l1.AnchorStateRegistryProxy // empty' "$REC")"
anchor_root=""; anchor_block=""
if [ -n "$ASR" ]; then ar="$(ecall "$ASR" "$SEL_ANCHOR")"; anchor_root="$(word_hex "$ar" 0)"; anchor_block="$(word_n "$ar" 1)"; fi
init_bond="$(word_n "$(ecall "$DGF" "${SEL_INIT_BONDS}$(pad_u "$respected")")" 0)"
now="$(date +%s)"
latest=$(( $(rpcq eth_blockNumber '[]' | jq -r .) )); latest_ts="$(block_ts "$latest")"
echo "factory $DGF: $count games; respected game type $respected (portal $PORTAL); init bond $(hex_to_eth "$(printf '0x%x' "$init_bond")") ETH; L1 $L1_LABEL"
first=0
if [ "$LAST" != "all" ]; then first=$((count - LAST)); [ "$first" -lt 0 ] && first=0; fi

games="[]"
resolved=0; by_challenger=0; in_progress=0; other_type=0; challenger_addr=""; proposer_addr=""; max_clock=""
i="$first"
while [ "$i" -lt "$count" ]; do
  r="$(ecall "$DGF" "${SEL_GAME_AT}$(pad_u "$i")")"
  type="$(word_n "$r" 0)"; created="$(word_n "$r" 1)"; proxy="$(word_addr "$r" 2)"
  if [ "$type" != "$respected" ]; then
    other_type=$((other_type + 1))
    if printf ',%s,' "$EXTRA_TYPES" | grep -q ",$type,"; then
      # a game of another type (K4: the Type 8 implementation) read with the fields a permissionless game has
      xstatus="$(word_n "$(ecall "$proxy" "$SEL_STATUS")" 0)"; xresolved_at="$(word_n "$(ecall "$proxy" "$SEL_RESOLVED_AT")" 0)"
      xroot="$(word_hex "$(ecall "$proxy" "$SEL_ROOT_CLAIM")" 0)"; xl2b="$(word_n "$(ecall "$proxy" "$SEL_EXTRA_DATA")" 2)"
      xclaims="$(word_n "$(ecall "$proxy" "$SEL_CLAIM_LEN")" 0)"; xcreator="$(word_addr "$(ecall "$proxy" "$SEL_CREATOR")" 0)"
      xpre="$(word_hex "$(ecall "$proxy" "$SEL_PRESTATE")" 0)"; xvm="$(word_addr "$(ecall "$proxy" "$SEL_VM")" 0)"
      xsroot="$(word_hex "$(ecall "$proxy" "$SEL_STARTING_ROOT")" 0)"; xsblock="$(word_n "$(ecall "$proxy" "$SEL_STARTING_BLOCK")" 0)"
      xmax_clock="$(word_n "$(ecall "$proxy" "$SEL_MAX_CLOCK")" 0)"
      xcredit_cr="$(word_n "$(ecall "$proxy" "${SEL_CREDIT}$(pad_a "$xcreator")")" 0)"
      xcredit_c=""; [ -z "$challenger_addr" ] || xcredit_c="$(word_n "$(ecall "$proxy" "${SEL_CREDIT}$(pad_a "$challenger_addr")")" 0)"
      xbond="$(bond_cycle "$proxy" "$xcreator" "$xstatus")"
      xres=null
      if [ "$xstatus" != "0" ]; then
        resolved=$((resolved + 1))
        xlg="$(resolved_log "$proxy" "$xresolved_at" || true)"
        if [ -n "$xlg" ]; then
          xrtx="$(jq -r .transactionHash <<<"$xlg")"; xrblock=$(( $(jq -r .blockNumber <<<"$xlg") ))
          xrfrom="$(rpcq eth_getTransactionByHash "[\"$xrtx\"]" | jq -r '.from // ""')"
          [ "$(sender_role "$xrfrom")" = "challenger" ] && by_challenger=$((by_challenger + 1))
          xres="$(jq -cn --arg tx "$xrtx" --argjson b "$xrblock" --arg from "$xrfrom" --arg at "$(iso_of "$(block_ts "$xrblock")")" --arg who "$(sender_role "$xrfrom")" '{tx: $tx, l1Block: $b, from: $from, sender: $who, at: $at}')"
        fi
      else
        in_progress=$((in_progress + 1))
      fi
      printf '  #%-3s %s  type %s  L2 %-7s created %s  %-15s claims %s  creator %s  prestate %s...  credit creator %s%s\n' "$i" "$proxy" "$type" "$xl2b" "$(iso_of "$created")" "$(status_name "$xstatus")" "$xclaims" "$xcreator" "${xpre:0:18}" "$(hex_to_eth "$(printf '0x%x' "$xcredit_cr")")" "$(bond_marks "$xbond")"
      games="$(jq -cn --argjson g "$games" --argjson i "$i" --argjson t "$type" --arg p "$proxy" --argjson c "$created" --arg cs "$(iso_of "$created")" --argjson l2 "$xl2b" --arg root "$xroot" \
        --argjson st "$xstatus" --arg stn "$(status_name "$xstatus")" --argjson ra "$xresolved_at" --argjson claims "$xclaims" --argjson res "$xres" --arg creator "$xcreator" --arg pre "$xpre" --arg vm "$xvm" \
        --arg sroot "$xsroot" --argjson sblock "$xsblock" --argjson ce "$((created + xmax_clock))" --arg ccr "$xcredit_cr" --arg cc "$xcredit_c" --argjson bond "$xbond" \
        '$g + [{index: $i, type: $t, proxy: $p, createdAt: $c, created: $cs, l2Block: $l2, rootClaim: $root, startingRootHash: $sroot, startingBlockNumber: $sblock, creator: $creator, absolutePrestate: $pre, vm: $vm,
                status: $st, statusName: $stn, resolvedAt: $ra, claims: $claims, moves: ($claims - 1), clockEndsAt: $ce, resolution: $res, creditWei: {creator: $ccr, challenger: (if $cc == "" then null else $cc end)}, bond: $bond}]')"
      i=$((i + 1)); sleep 0.3; continue
    fi
    games="$(jq -cn --argjson g "$games" --argjson i "$i" --argjson t "$type" --arg p "$proxy" --argjson c "$created" '$g + [{index: $i, type: $t, proxy: $p, createdAt: $c, note: "not the respected type; not read"}]')"
    i=$((i + 1)); continue
  fi
  status="$(word_n "$(ecall "$proxy" "$SEL_STATUS")" 0)"
  resolved_at="$(word_n "$(ecall "$proxy" "$SEL_RESOLVED_AT")" 0)"
  root="$(word_hex "$(ecall "$proxy" "$SEL_ROOT_CLAIM")" 0)"
  l2b="$(word_n "$(ecall "$proxy" "$SEL_EXTRA_DATA")" 2)"
  claims="$(word_n "$(ecall "$proxy" "$SEL_CLAIM_LEN")" 0)"
  if [ -z "$challenger_addr" ]; then
    challenger_addr="$(word_addr "$(ecall "$proxy" "$SEL_CHALLENGER")" 0)"
    proposer_addr="$(word_addr "$(ecall "$proxy" "$SEL_PROPOSER")" 0)"
    max_clock="$(word_n "$(ecall "$proxy" "$SEL_MAX_CLOCK")" 0)"
  fi
  credit_p="$(word_n "$(ecall "$proxy" "${SEL_CREDIT}$(pad_a "$proposer_addr")")" 0)"
  credit_c="$(word_n "$(ecall "$proxy" "${SEL_CREDIT}$(pad_a "$challenger_addr")")" 0)"
  bond="$(bond_cycle "$proxy" "$proposer_addr" "$status")"
  resolution=null
  if [ "$status" != "0" ]; then
    resolved=$((resolved + 1))
    lg="$(resolved_log "$proxy" "$resolved_at" || true)"
    [ -n "$lg" ] || warn "game #$i: Resolved log not found near $(iso_of "$resolved_at"); recorded without the resolving transaction"
    if [ -n "$lg" ]; then
      rtx="$(jq -r .transactionHash <<<"$lg")"; rblock=$(( $(jq -r .blockNumber <<<"$lg") ))
      rfrom="$(rpcq eth_getTransactionByHash "[\"$rtx\"]" | jq -r '.from // ""')"
      [ "$(sender_role "$rfrom")" = "challenger" ] && by_challenger=$((by_challenger + 1))
      resolution="$(jq -cn --arg tx "$rtx" --argjson b "$rblock" --arg from "$rfrom" --arg at "$(iso_of "$(block_ts "$rblock")")" --arg who "$(sender_role "$rfrom")" '{tx: $tx, l1Block: $b, from: $from, sender: $who, at: $at}')"
    fi
  else
    in_progress=$((in_progress + 1))
  fi
  moves=$((claims - 1))   # every move appends a claim; the root claim is claim 0 (no log query: a public endpoint rations eth_getLogs)
  clock_ends=$((created + max_clock))
  printf '  #%-3s %s  L2 %-7s created %s  %-15s claims %s moves %s%s  credit P %s C %s%s\n' "$i" "$proxy" "$l2b" "$(iso_of "$created")" "$(status_name "$status")" "$claims" "$moves" \
    "$([ "$status" != "0" ] && echo "  resolved $(iso_of "$resolved_at") by $(jq -r '.sender // "?"' <<<"$resolution")" || echo "  clock ends $(iso_of "$clock_ends")$([ "$now" -gt "$clock_ends" ] && echo ' (resolvable)')")" \
    "$(hex_to_eth "$(printf '0x%x' "$credit_p")")" "$(hex_to_eth "$(printf '0x%x' "$credit_c")")" "$(bond_marks "$bond")"
  games="$(jq -cn --argjson g "$games" --argjson i "$i" --argjson t "$type" --arg p "$proxy" --argjson c "$created" --arg cs "$(iso_of "$created")" --argjson l2 "$l2b" --arg root "$root" \
    --argjson st "$status" --arg stn "$(status_name "$status")" --argjson ra "$resolved_at" --argjson claims "$claims" --argjson moves "$moves" --argjson res "$resolution" \
    --arg cp "$credit_p" --arg cc "$credit_c" --argjson ce "$clock_ends" --argjson bond "$bond" \
    '$g + [{index: $i, type: $t, proxy: $p, createdAt: $c, created: $cs, l2Block: $l2, rootClaim: $root, status: $st, statusName: $stn, resolvedAt: $ra, claims: $claims, moves: $moves, clockEndsAt: $ce, resolution: $res, creditWei: {proposer: $cp, challenger: $cc}, bond: $bond}]')"
  i=$((i + 1)); sleep 0.3
done

# the DelayedWETH delay (read inside bond_cycle's subshell, so once more here for the record), the anchor (which game's
# root it is, among the games read) and the hot roles' L1 balances at the head block
if [ -n "${proxy:-}" ] && [ -z "$weth_delay" ]; then
  weth_a="$(word_addr "$(ecall "$proxy" "$SEL_WETH" 2>/dev/null || echo 0x)" 0)"
  [ "$weth_a" = "0x" ] || [ "${#weth_a}" -ne 42 ] || weth_delay="$(word_n "$(ecall "$weth_a" "$SEL_WETH_DELAY")" 0)"
fi
anchor=null
if [ -n "$anchor_root" ]; then
  anchor_game="$(jq -r --arg r "$anchor_root" '[.[] | select(.rootClaim == $r) | .index] | first // empty' <<<"$games")"
  anchor="$(jq -cn --arg r "$anchor_root" --argjson b "$anchor_block" --arg g "$anchor_game" '{root: $r, l2Block: $b, gameIndex: (if $g == "" then null else ($g | tonumber) end), placeholder: ($r | startswith("0xdead0000"))}')"
  echo "anchor: root $anchor_root at L2 block $anchor_block$([ -n "$anchor_game" ] && echo " (game #$anchor_game)")$(jq -r 'if .placeholder then " - still op-deployer'"'"'s placeholder" else "" end' <<<"$anchor")"
fi
balances=null
if [ -n "$proposer_addr" ]; then
  bal_p="$(rpcq eth_getBalance "[\"$proposer_addr\",\"$(printf '0x%x' "$latest")\"]" | jq -r .)"; bal_c="$(rpcq eth_getBalance "[\"$challenger_addr\",\"$(printf '0x%x' "$latest")\"]" | jq -r .)"
  balances="$(jq -cn --argjson b "$latest" --arg p "$bal_p" --arg pe "$(hex_to_eth "$bal_p")" --arg c "$bal_c" --arg ce "$(hex_to_eth "$bal_c")" '{l1Block: $b, proposerWeiHex: $p, proposerEth: $pe, challengerWeiHex: $c, challengerEth: $ce}')"
  echo "balances at L1 block $latest: proposer $(hex_to_eth "$bal_p") ETH, challenger $(hex_to_eth "$bal_c") ETH"
fi

out="$FINCHAIN_ROOT/manifests/evidence/games-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p "$(dirname "$out")"
jq -n --arg l1 "$L1_LABEL" --arg dgf "$DGF" --arg portal "$PORTAL" --argjson count "$count" --argjson first "$first" --argjson respected "$respected" --arg bond "$init_bond" --arg env "$ENVIRONMENT" \
  --arg challenger "$challenger_addr" --arg proposer "$proposer_addr" --argjson maxClock "${max_clock:-0}" --argjson games "$games" --argjson anchor "$anchor" --argjson balances "$balances" --arg wdelay "${weth_delay:-}" \
  --argjson resolved "$resolved" --argjson byc "$by_challenger" --argjson inprog "$in_progress" --argjson other "$other_type" --arg extra "$EXTRA_TYPES" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {schema: "finchain.games/2", acceptance: "M4: resident challenger on host B against the public chain - games resolved and bonds claimed (docs/acceptance.md M4; docs/proof-plan.md level L1)",
   environment: $env, recordedAt: $at, l1Rpc: $l1, disputeGameFactory: $dgf, optimismPortal: $portal, respectedGameType: $respected, initBondWei: $bond,
   roles: {proposer: $proposer, challenger: $challenger, maxClockDurationSeconds: $maxClock},
   anchor: $anchor, balances: $balances, delayedWethDelaySeconds: (if $wdelay == "" then null else ($wdelay | tonumber) end),
   gameCount: $count, gamesRead: {from: $first, to: ($count - 1), extraTypes: (if $extra == "" then [] else ($extra | split(",") | map(tonumber)) end)},
   summary: {resolved: $resolved, resolvedByChallenger: $byc, inProgress: $inprog, notRespectedType: $other,
             note: "a game of the permissioned type with one claim and no moves resolves in favour of the root after maxClockDuration; the sender of the resolving transaction says who runs the resolver. Credit is what a party may claim after resolution (the proposer bond returns to the proposer; the challenger holds credit only where it moved). The bond block of each game says whether the game is closed (bondDistributionMode set by closeGame, which also moves the anchor when the game qualifies), what DelayedWETH still holds for the recipient and when it was unlocked, and - once paid - the transaction that paid it (claimCredit by the challenger service: its first call after the game finality delay closes the game and unlocks the credit, a call after the DelayedWETH delay pays it)."},
   games: $games}' > "$out"
echo "summary: $resolved resolved ($by_challenger by the challenger $challenger_addr), $in_progress in progress, $other_type of another type; report $out"
