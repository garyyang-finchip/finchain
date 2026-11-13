#!/usr/bin/env bash
# M4: the dispute games of the public testnet as the chain holds them, and what the resident challenger did with them
# (docs/acceptance.md M4, "resident challenger running on host B against the public chain; games resolved and bonds
# claimed"; docs/proof-plan.md, level L1). Reads the DisputeGameFactory and every game of the respected type through
# the L1 RPC - creation, L2 block claimed, root claim, status, resolution and who sent the resolving transaction, the
# credit each party holds, the bonds - and writes manifests/evidence/games-<date>.json. Pair it with the challenger's
# own log on host B (make logs-b SVC=op-challenger, or docker logs) for the service-side view.
#
# Usage: scripts/games.sh [l1-rpc] [last-n=all]
#   The L1 RPC: the argument, else L1_RPC_URL in the environment, else node-b/.env, else .env.
# Reads the chain only (curl + jq; no key, no docker, no cast): plain eth_call with the selectors below.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk

L1="${1:-${L1_RPC_URL:-}}"
if [ -z "$L1" ]; then
  for f in "$FINCHAIN_ROOT/node-b/.env" "$FINCHAIN_ROOT/.env"; do
    [ -f "$f" ] && L1="$(grep -E '^L1_RPC_URL=' "$f" | tail -1 | cut -d= -f2- | tr -d '"')" && [ -n "$L1" ] && break
  done
fi
[ -n "$L1" ] || die "no L1 RPC: pass it as the first argument or set L1_RPC_URL"
LAST="${2:-all}"
REC="$FINCHAIN_ROOT/chain/out/chain-record.json"
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
TOPIC_RESOLVED=0x5e186f09b9c93491f14e277eea7faa5de6a2d4bda75a79af7a3684fbfb42da60   # Resolved(GameStatus indexed)

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
  die "eth_call to $1 (${2:0:10}) answered nothing six times (a revert, or the endpoint $L1 is refusing the burst; last answer: $(printf '%s' "$raw" | cut -c1-200))"
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
  die "$1 answered nothing six times on $L1 (last answer: $(printf '%s' "$raw" | cut -c1-200))"
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

count="$(word_n "$(ecall "$DGF" "$SEL_GAME_COUNT")" 0)"
respected="$(word_n "$(ecall "$PORTAL" "$SEL_RESPECTED")" 0)"
init_bond="$(word_n "$(ecall "$DGF" "${SEL_INIT_BONDS}$(pad_u "$respected")")" 0)"
now="$(date +%s)"
echo "factory $DGF: $count games; respected game type $respected (portal $PORTAL); init bond $(hex_to_eth "$(printf '0x%x' "$init_bond")") ETH; L1 $L1"
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
  resolution=null
  if [ "$status" != "0" ]; then
    resolved=$((resolved + 1))
    lg="$(rpcq eth_getLogs "[{\"address\":\"$proxy\",\"topics\":[\"$TOPIC_RESOLVED\"],\"fromBlock\":\"$(printf '0x%x' "$DEPLOY_BLOCK")\",\"toBlock\":\"latest\"}]" | jq -c '.[0] // empty')"
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
  printf '  #%-3s %s  L2 %-7s created %s  %-15s claims %s moves %s%s  credit P %s C %s\n' "$i" "$proxy" "$l2b" "$(iso_of "$created")" "$(status_name "$status")" "$claims" "$moves" \
    "$([ "$status" != "0" ] && echo "  resolved $(iso_of "$resolved_at") by $(jq -r '.sender // "?"' <<<"$resolution")" || echo "  clock ends $(iso_of "$clock_ends")$([ "$now" -gt "$clock_ends" ] && echo ' (resolvable)')")" \
    "$(hex_to_eth "$(printf '0x%x' "$credit_p")")" "$(hex_to_eth "$(printf '0x%x' "$credit_c")")"
  games="$(jq -cn --argjson g "$games" --argjson i "$i" --argjson t "$type" --arg p "$proxy" --argjson c "$created" --arg cs "$(iso_of "$created")" --argjson l2 "$l2b" --arg root "$root" \
    --argjson st "$status" --arg stn "$(status_name "$status")" --argjson ra "$resolved_at" --argjson claims "$claims" --argjson moves "$moves" --argjson res "$resolution" \
    --arg cp "$credit_p" --arg cc "$credit_c" --argjson ce "$clock_ends" \
    '$g + [{index: $i, type: $t, proxy: $p, createdAt: $c, created: $cs, l2Block: $l2, rootClaim: $root, status: $st, statusName: $stn, resolvedAt: $ra, claims: $claims, moves: $moves, clockEndsAt: $ce, resolution: $res, creditWei: {proposer: $cp, challenger: $cc}}]')"
  i=$((i + 1)); sleep 0.3
done

out="$FINCHAIN_ROOT/manifests/evidence/games-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p "$(dirname "$out")"
jq -n --arg l1 "$L1" --arg dgf "$DGF" --arg portal "$PORTAL" --argjson count "$count" --argjson first "$first" --argjson respected "$respected" --arg bond "$init_bond" \
  --arg challenger "$challenger_addr" --arg proposer "$proposer_addr" --argjson maxClock "${max_clock:-0}" --argjson games "$games" \
  --argjson resolved "$resolved" --argjson byc "$by_challenger" --argjson inprog "$in_progress" --argjson other "$other_type" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {schema: "finchain.games/1", acceptance: "M4: resident challenger on host B against the public chain - games resolved and bonds claimed (docs/acceptance.md M4; docs/proof-plan.md level L1)",
   environment: "public-testnet", recordedAt: $at, l1Rpc: $l1, disputeGameFactory: $dgf, optimismPortal: $portal, respectedGameType: $respected, initBondWei: $bond,
   roles: {proposer: $proposer, challenger: $challenger, maxClockDurationSeconds: $maxClock},
   gameCount: $count, gamesRead: {from: $first, to: ($count - 1)},
   summary: {resolved: $resolved, resolvedByChallenger: $byc, inProgress: $inprog, notRespectedType: $other,
             note: "a game of the permissioned type with one claim and no moves resolves in favour of the root after maxClockDuration; the sender of the resolving transaction says who runs the resolver. Credit is what a party may claim after resolution (the proposer bond returns to the proposer; the challenger holds credit only where it moved); claimCredit calls come from the challenger service and show in its log."},
   games: $games}' > "$out"
echo "summary: $resolved resolved ($by_challenger by the challenger $challenger_addr), $in_progress in progress, $other_type of another type; report $out"
