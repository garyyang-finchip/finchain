#!/usr/bin/env bash
# M4 K3: the dishonest side of the devnet dispute, and the record of what the honest side did about it
# (docs/proof-plan.md, "K3: isolated environment"; drill/devnet/README.md).
#
# The honest op-proposer posts correct roots as type-8 games; the resident op-challenger (cannon-kona, the devnet
# prestate) defends them. This script plays the attacker with op-challenger's own `move` subcommand: it attacks the
# root claim of one game with an arbitrary value and then answers every claim the honest challenger posts in reply,
# all the way down the tree. The contract verifies nothing about intermediate claims; the attacker only pays the
# bond of each depth. At the max game depth the attacker's leaf claim can only be answered by `step()`: the honest
# challenger executes one MIPS instruction on chain from the agreed pre-state and shows the leaf wrong - the
# transaction this drill exists to produce. The honest side never steps in a game whose root is dishonest: with the
# standard odd max depth the dishonest leaf sits at the max depth only when the root is honest, so the scenario
# here is the one that forces the real step (and the realistic one for a chain with an honest proposer).
#
# Two attack strategies (ATTACK_STRATEGY):
#   left    attack every honest claim (the first run, 2026-11-16): the leaf is trace index 0 of the first block
#           after the anchor, and the step executes the first instruction of kona-client from the absolute prestate.
#   inside  attack or defend at random while the position stays inside the chain and the trace: at the output level
#           a honest claim equal to the root's output root marks a position past the claimed block (op-challenger
#           clamps there), so the attacker attacks it; below the split depth the honest claim's VM status byte says
#           whether the trace is still running there (0x03) or has exited (0x00), and the attacker defends only an
#           unfinished one. The root claim and the claim at the split depth are always attacked (the contract allows
#           no defence of a sub-game root, and the first execution claim must carry the INVALID or PANIC status
#           byte). The leaf then sits at an arbitrary instruction of a random block's trace; the honest challenger's
#           step proves that instruction, with whatever preimage uploads it needs first. ATTACK_SEED seeds the
#           choices (recorded) so that a run can be repeated.
#
# Usage: drill/devnet/adversary.sh dispute | resolve   (devnet.sh dispute / resolve; make devnet-dispute / devnet-resolve)
#   dispute  pick the newest untouched type-8 game (GAME=0x... to choose), play until the honest step lands,
#            write manifests/evidence/devnet-dispute-<chainId>-<date>.json (resolution pending)
#   resolve  wait for the game to resolve after the clocks, read the outcome back, complete the record
# Environment: GAME, ATTACK_STRATEGY (left | inside, default left), ATTACK_SEED (default: the start time),
#              DISPUTE_TIMEOUT (default 4h), RESOLVE_TIMEOUT (default max clock duration + 1h), POLL (default 6s)

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
require_cmd docker jq curl openssl
DEVNET_DIR="$FINCHAIN_ROOT/drill/devnet"; OUT="$DEVNET_DIR/out"
load_env "$FINCHAIN_ROOT/versions.lock" "$DEVNET_DIR/devnet.env"
GEN="$OUT/generated.env"
L1_URL="http://127.0.0.1:$DEVNET_L1_PORT"; NETWORK=finchain-devnet_default
STEP_SELECTOR=0xd8cc1a3c       # step(uint256,bool,bytes,bytes)
RESOLVE_SELECTOR=0x2810e1d6    # resolve()
ADD_LOCAL_DATA_SELECTOR=0xf8f43ff6   # FaultDisputeGame.addLocalData(uint256,uint256,uint256): a local preimage, loaded through the game
DEAD_ROOT=0xdead000000000000000000000000000000000000000000000000000000000000   # op-deployer's placeholder anchor (devnet.sh anchor)
POLL="${POLL:-6}"
IMAGE="${OP_CHALLENGER_IMAGE:?}"
STRATEGY="${ATTACK_STRATEGY:-left}"
case "$STRATEGY" in left|inside) ;; *) die "ATTACK_STRATEGY must be left or inside, not '$STRATEGY'" ;; esac
SEED="${ATTACK_SEED:-$(date +%s)}"
case "$SEED" in ''|*[!0-9]*) die "ATTACK_SEED must be a decimal number" ;; esac
RANDOM="$SEED"
DGF=""; ADVERSARY=""; HONEST=""; PROPOSER=""; ORACLE=""
# what a running devnet has written into out/generated.env
require_devnet() {
  [ -f "$GEN" ] || die "no devnet yet (out/generated.env missing): devnet.sh keys, l1, deploy, build, install-game, l2, proof first"
  load_env "$GEN"
  DGF="${DEVNET_DGF:?no factory address in generated.env (devnet.sh deploy)}"
  ADVERSARY="$(printf '%s' "${DEVNET_ADDR_ADVERSARY:?}" | tr '[:upper:]' '[:lower:]')"
  HONEST="$(printf '%s' "${DEVNET_ADDR_CHALLENGER:?}" | tr '[:upper:]' '[:lower:]')"
  PROPOSER="$(printf '%s' "${DEVNET_ADDR_PROPOSER:?}" | tr '[:upper:]' '[:lower:]')"
  DEVNET_ASR="$(jq -r .AnchorStateRegistryProxy "$OUT/chain/l1-addresses.json")"; export DEVNET_ASR
  # the PreimageOracle the installed VM uses (devnet.sh install-game read it back from the MIPS contract)
  ORACLE="$(jq -r '.preimageOracle.address // empty' "$OUT/chain/game-type-$DEVNET_GAME_TYPE.json" 2>/dev/null || true)"
  [ -n "$ORACLE" ] || ORACLE="$(jq -r '.PreimageOracleImpl // empty' "$OUT/chain/l1-addresses.json")"
  ORACLE="$(lower "$ORACLE")"
}

l1_rpc() { rpc "$L1_URL" "$@"; }
hexdec() { printf '%d' "$1"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
to_seconds() { case "$1" in *h) echo $(( ${1%h} * 3600 )) ;; *m) echo $(( ${1%m} * 60 )) ;; *s) echo "${1%s}" ;; *) echo "$1" ;; esac; }
cli() { docker run --rm --network "$NETWORK" --entrypoint op-challenger "$IMAGE" "$@"; }
cli_signed() { docker run --rm --network "$NETWORK" --env-file "$OUT/secrets/adversary.env" --entrypoint op-challenger "$IMAGE" "$@"; }
list_games() { cli list-games --l1-eth-rpc http://anvil:8545 --game-factory-address "$DGF" --format json 2>/dev/null; }
list_claims() { cli list-claims --l1-eth-rpc http://anvil:8545 --game-address "$1" --format json 2>/dev/null; }
game_status() { cast call "$1" 'status()(uint8)' --rpc-url "$L1_URL" | awk '{print $1}'; }   # 0 IN_PROGRESS, 1 CHALLENGER_WINS, 2 DEFENDER_WINS
status_name() { case "$1" in 0) echo IN_PROGRESS ;; 1) echo CHALLENGER_WINS ;; 2) echo DEFENDER_WINS ;; *) echo "status $1" ;; esac; }
# "<root> <l2 block>"; cast annotates numbers of five or more digits with a scientific-notation hint in brackets, dropped here
anchor_root() { cast call "${DEVNET_ASR:?}" 'getAnchorRoot()(bytes32,uint256)' --rpc-url "$L1_URL" | tr '\n' ' ' | sed -E 's/ *\[[^]]*\]//g; s/ *$//'; }

# find_tx <to> <selector> <from block> -> JSON of the first transaction to <to> whose input starts with <selector>, with its receipt
find_tx() {
  local to sel from head n blk tx rcpt
  to="$(lower "$1")"; sel="$2"; from="$3"
  head="$(hexdec "$(l1_rpc eth_blockNumber | jq -r .result)")"
  for n in $(seq "$from" "$head"); do
    blk="$(l1_rpc eth_getBlockByNumber "[\"$(printf '0x%x' "$n")\",true]")"
    tx="$(jq -c --arg to "$to" --arg sel "$sel" '.result.transactions[] | select((.to // "" | ascii_downcase) == $to and (.input | startswith($sel)))' <<<"$blk" | head -1)"
    if [ -n "$tx" ]; then
      rcpt="$(l1_rpc eth_getTransactionReceipt "[$(jq -c .hash <<<"$tx")]" | jq -c .result)"
      jq -cn --argjson tx "$tx" --argjson r "$rcpt" '{hash: $tx.hash, block: ($tx.blockNumber | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d)),
        from: $tx.from, to: $tx.to, inputBytes: ((($tx.input | length) - 2) / 2), status: $r.status, gasUsed: ($r.gasUsed | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d))}'
      return 0
    fi
  done
  return 1
}

# find_txs <from> <to-list (comma-separated)> <from block> <to block> -> JSON array of the transactions sent by <from> to any
# of the addresses in those blocks, each with its selector and receipt (the preimage uploads before a step)
find_txs() {
  local from tos b0 b1 n blk acc='[]' tx hashes h rcpt
  from="$(lower "$1")"; tos="$(lower "$2")"; b0="$3"; b1="$4"
  for n in $(seq "$b0" "$b1"); do
    blk="$(l1_rpc eth_getBlockByNumber "[\"$(printf '0x%x' "$n")\",true]")"
    hashes="$(jq -r --arg from "$from" --arg tos "$tos" '($tos | split(",")) as $t | .result.transactions[] | select((.from | ascii_downcase) == $from and (((.to // "") | ascii_downcase) as $to | $t | index($to) != null)) | .hash' <<<"$blk")"
    for h in $hashes; do
      tx="$(jq -c --arg h "$h" '.result.transactions[] | select(.hash == $h)' <<<"$blk")"
      rcpt="$(l1_rpc eth_getTransactionReceipt "[\"$h\"]" | jq -c .result)"
      acc="$(jq -cn --argjson acc "$acc" --argjson tx "$tx" --argjson r "$rcpt" --argjson n "$n" '$acc + [{hash: $tx.hash, block: $n, from: $tx.from, to: $tx.to, selector: ($tx.input[0:10]),
        inputBytes: ((($tx.input | length) - 2) / 2), status: $r.status, gasUsed: ($r.gasUsed | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d))}]')"
    done
  done
  # the preimage-upload functions of FaultDisputeGame 2.4.2 and PreimageOracle 1.1.5, by selector
  jq -c 'map(. + {function: ({"0xf8f43ff6": "addLocalData", "0x52f0f3ad": "loadLocalData", "0xe1592611": "loadKeccak256PreimagePart",
                             "0x8dc4be11": "loadSha256PreimagePart", "0x9d7e8769": "loadBlobPreimagePart", "0xea713950": "loadPrecompilePreimagePart",
                             "0xfaf37bc7": "initLPP", "0x7917de1d": "addLeavesLPP", "0xa6fce84f": "squeezeLPP"}[.selector] // "other")})' <<<"$acc"
}

###############################################################################################################
cmd_dispute() {
  require_devnet
  [ -s "$OUT/secrets/adversary.env" ] || die "no adversary key: devnet.sh keys"
  docker ps --format '{{.Names}}' | grep -q '^finchain-devnet-op-challenger-' || die "the honest op-challenger is not running: devnet.sh proof"
  local timeout stamp dir games game ginfo claims max_depth split_depth root_claimant status
  timeout="$(to_seconds "${DISPUTE_TIMEOUT:-4h}")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; dir="$OUT/evidence/dispute-$stamp"; mkdir -p "$dir"

  games="$(list_games)" || die "list-games failed (is the L1 up?)"
  local starting
  if [ -n "${GAME:-}" ]; then
    game="$(lower "$GAME")"
    ginfo="$(jq -c --arg g "$game" '.games[] | select((.game | ascii_downcase) == $g)' <<<"$games")"; [ -n "$ginfo" ] || die "game $GAME is not in the factory's list"
    starting="$(cast call "$game" 'startingRootHash()(bytes32)' --rpc-url "$L1_URL" | tr -d '\r\n')"
    [ "$(lower "$starting")" != "$DEAD_ROOT" ] || die "game $GAME starts from the placeholder anchor root; the honest challenger does not play such a game (devnet.sh anchor, then a game created after it)"
  else
    # the newest untouched game whose starting root is a real anchor (games created before the anchor moved keep the
    # placeholder, and the honest challenger declines them); the proposer's next game may be minutes away
    local cand waited=0
    ginfo=""
    while :; do
      for cand in $(jq -r --argjson gt "$DEVNET_GAME_TYPE" '[.games[] | select(.gameType == $gt and .status == "In Progress" and .claimCount == 1)] | sort_by(.index) | reverse | .[].game' <<<"$games"); do
        starting="$(cast call "$cand" 'startingRootHash()(bytes32)' --rpc-url "$L1_URL" | tr -d '\r\n')"
        if [ "$(lower "$starting")" != "$DEAD_ROOT" ]; then ginfo="$(jq -c --arg g "$(lower "$cand")" '.games[] | select((.game | ascii_downcase) == $g)' <<<"$games")"; break; fi
      done
      [ -z "$ginfo" ] || break
      [ "$waited" -lt 900 ] || die "no untouched type-$DEVNET_GAME_TYPE game with a real starting root after 15 minutes: devnet.sh anchor moves the anchor off the placeholder, and the proposer's next game (${DEVNET_PROPOSAL_INTERVAL}) is the first usable one (devnet.sh status lists them)"
      [ "$waited" -gt 0 ] || log "no untouched game with a real starting root yet; waiting for the proposer's next game (every $DEVNET_PROPOSAL_INTERVAL)"
      sleep 20; waited=$(( waited + 20 ))
      games="$(list_games)" || die "list-games failed"
    done
    game="$(lower "$(jq -r .game <<<"$ginfo")")"
  fi
  printf '%s\n' "$ginfo" > "$dir/game.json"
  claims="$(list_claims "$game")" || die "list-claims failed for $game"
  printf '%s\n' "$claims" > "$dir/claims-0000.json"
  max_depth="$(jq -r .maxDepth <<<"$claims")"; split_depth="$(jq -r .splitDepth <<<"$claims")"
  root_claimant="$(lower "$(jq -r '.claims[0].claimant' <<<"$claims")")"
  [ $(( max_depth % 2 )) -eq 1 ] || die "max depth $max_depth is even: the attacker's leaf would not sit at the max depth and the honest side would never step (README)"
  [ "$root_claimant" = "$PROPOSER" ] || die "the root claim of $game is by $root_claimant, not the devnet proposer $PROPOSER: this scenario needs an honest root"
  log "game $game (index $(jq -r .index <<<"$ginfo"), type $(jq -r .gameType <<<"$ginfo"), L2 block $(jq -r .l2BlockNumber <<<"$ginfo"), root $(jq -r .outputRoot <<<"$ginfo") by the proposer)"
  log "max depth $max_depth, split depth $split_depth; attacker $ADVERSARY, honest challenger $HONEST; timeout ${timeout}s; snapshots in $dir"
  log "strategy $STRATEGY (seed $SEED)"
  local anchor_before root_value
  anchor_before="$(anchor_root)"
  root_value="$(lower "$(jq -r '.claims[0].value' <<<"$claims")")"

  local t0 moves=0 snap=0 last_move_at step_block=0 txs=() waiting_since=0 result="" reason="" leaf_idx="" depth_reached=0 defends=0
  t0="$(date +%s)"; last_move_at="$t0"
  while :; do
    claims="$(list_claims "$game")" || { warn "list-claims failed; retrying"; sleep "$POLL"; continue; }
    status="$(jq -r .status <<<"$claims")"
    # the honest step: a leaf claim at the max depth that is countered the moment the step lands (list-claims)
    leaf_idx="$(jq -r --argjson d "$max_depth" '[.claims[] | select(.depth == $d and (.counteredBy // "") != "")] | first // empty | .index' <<<"$claims")"
    if [ -n "$leaf_idx" ]; then result=PASS; reason="the attacker's leaf claim #$leaf_idx at depth $max_depth was countered on chain by $(jq -r --argjson i "$leaf_idx" '.claims[] | select(.index == $i) | .counteredBy' <<<"$claims")"; break; fi
    if [ "$status" != "In Progress" ]; then result=FAIL; reason="the game left In Progress ($status) before a step: $(jq -r .claimCount <<<"$claims") claims"; break; fi
    # targets: claims of the honest side (the proposer's root, the challenger's replies) without an attacker's child yet
    local targets
    targets="$(jq -c --arg me "$ADVERSARY" --argjson d "$max_depth" '
      .claims as $all | [ $all[] | . as $c | select((($c.claimant | ascii_downcase) != $me) and ($c.depth < $d) and (($c.counteredBy // "") == "")
                          and (([$all[] | select(.parentIndex == $c.index and (.claimant | ascii_downcase) == $me)] | length) == 0)) | .index ]' <<<"$claims")"
    if [ "$(jq length <<<"$targets")" -gt 0 ]; then
      local idx value out hash pd pv kind why
      for idx in $(jq -r '.[]' <<<"$targets"); do
        pd="$(jq -r --argjson i "$idx" '.claims[] | select(.index == $i) | .depth' <<<"$claims")"
        pv="$(lower "$(jq -r --argjson i "$idx" '.claims[] | select(.index == $i) | .value' <<<"$claims")")"
        # attack or defend. The root claim cannot be defended (CannotDefendRootClaim), nor can the move at the split
        # depth be anything but an attack here: the first execution-trace claim is the root of that sub-game and the
        # contract checks its status byte - an attacker must claim the VM found the disputed output INVALID (0x01) or
        # PANIC (0x02), anything else reverts with UnexpectedRootClaim (FaultDisputeGame._verifyExecBisectionRoot).
        kind=attack; why=""
        if [ "$STRATEGY" = inside ] && [ "$idx" != 0 ] && [ "$pd" != "$split_depth" ]; then
          local inside=0
          if [ "$pd" -lt "$split_depth" ]; then
            # output bisection: a honest claim equal to the root's output root is a position past the claimed block
            [ "$pv" = "$root_value" ] || inside=1
            why="$([ "$inside" = 1 ] && echo "inside the chain" || echo "past the claimed block")"
          else
            # execution bisection: the VM status byte of the honest claim - 0x03 unfinished (inside the trace), 0x00 exited
            [ "${pv:0:4}" != "0x03" ] || inside=1
            why="$([ "$inside" = 1 ] && echo "VM unfinished there" || echo "VM exited there")"
          fi
          if [ "$inside" = 1 ] && [ $(( RANDOM % 2 )) -eq 1 ]; then kind=defend; fi
        fi
        if [ "$pd" = "$split_depth" ]; then
          value="0x01$(openssl rand -hex 31)"
        else
          value="0x$(openssl rand -hex 32)"
        fi
        local rc=0 landed
        out="$(cli_signed move --l1-eth-rpc http://anvil:8545 --game-address "$game" "--$kind" --parent-index "$idx" --claim "$value" 2>&1)" || rc=$?
        printf '%s\n' "$out" > "$dir/move-$(printf '%04d' $(( moves + 1 ))).log"
        hash="$(printf '%s' "$out" | sed -nE 's/.*hash: (0x[0-9a-fA-F]+).*/\1/p' | tail -1)"
        [ -n "$hash" ] || hash="$(printf '%s' "$out" | sed -nE 's/.*Publishing transaction.* tx=(0x[0-9a-fA-F]+).*/\1/p' | tail -1)"
        if [ "$rc" -ne 0 ]; then
          # the CLI can exit non-zero after the transaction was published (its receipt wait); the chain decides
          sleep 6
          landed="$(list_claims "$game" | jq -r --arg me "$ADVERSARY" --argjson p "$idx" --arg v "$value" '[.claims[] | select(.parentIndex == $p and (.claimant | ascii_downcase) == $me and (.value | ascii_downcase) == ($v | ascii_downcase))] | first // empty | .index')"
          if [ -n "$landed" ]; then
            warn "the move CLI exited $rc after publishing, but claim #$landed is on chain (move-$(printf '%04d' $(( moves + 1 ))).log); continuing"
          else
            result=FAIL; reason="$kind against claim #$idx (depth $pd) failed: $( { printf '%s' "$out" | grep -o 'execution reverted[^"]*' | tail -1; } || printf '%s' "$out" | grep -E 'lvl=(error|crit)|err=' | tail -n 2 | tr '\n' ' ' | cut -c1-400)"; break 2
          fi
        fi
        moves=$(( moves + 1 )); last_move_at="$(date +%s)"; waiting_since=0
        [ "$kind" != defend ] || defends=$(( defends + 1 ))
        txs+=("$(jq -cn --argjson parent "$idx" --argjson pd "$pd" --arg kind "$kind" --arg why "$why" --arg claim "$value" --arg tx "$hash" --argjson n "$moves" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{move: $n, kind: $kind, parent: $parent, depth: ($pd + 1), claim: $claim, tx: $tx, at: $at} + (if $why == "" then {} else {because: $why} end)')")
        depth_reached=$(( pd + 1 ))
        log "move $moves: $kind on claim #$idx (depth $pd${why:+, $why}) -> depth $depth_reached, tx $hash"
      done
      snap=$(( snap + 1 )); list_claims "$game" > "$dir/claims-$(printf '%04d' "$snap").json" 2>/dev/null || true
      step_block="$(hexdec "$(l1_rpc eth_blockNumber | jq -r .result)")"
      continue
    fi
    # nothing to attack: the honest side is computing its answer (below the split depth that is a cannon run)
    local now; now="$(date +%s)"
    if [ "$waiting_since" = 0 ]; then waiting_since="$now"; fi
    if [ $(( now - t0 )) -gt "$timeout" ]; then result=FAIL; reason="no step within ${timeout}s (depth reached $depth_reached, $moves moves)"; break; fi
    if [ $(( (now - waiting_since) % 60 )) -lt "$POLL" ]; then
      log "waiting for the honest challenger's answer at depth $depth_reached ($(( now - last_move_at ))s since the last move; $(( (now - t0) / 60 )) min in)"
    fi
    sleep "$POLL"
  done
  snap=$(( snap + 1 )); printf '%s\n' "$claims" > "$dir/claims-final.json"
  log "$result: $reason"

  # the step transaction, the preimage uploads before it, and the honest challenger's own account of it
  local step_tx honest_log oracle_txs='[]' oracle_min oracle_period disputed_block honest_proof_at
  step_tx=null
  if [ "$result" = PASS ]; then
    step_tx="$(find_tx "$game" "$STEP_SELECTOR" "$(( step_block > 2 ? step_block - 2 : 1 ))" || echo null)"
    if [ "$step_tx" != null ]; then
      # what the honest challenger sent to the game (addLocalData) or to the PreimageOracle between the attacker's leaf and
      # the step: the preimage parts that step needed, if any (a step on an instruction that reads no preimage needs none)
      oracle_txs="$(find_txs "$HONEST" "$game,$ORACLE" "$(( step_block > 2 ? step_block - 2 : 1 ))" "$(jq -r .block <<<"$step_tx")" \
        | jq -c --arg game "$game" --arg sel "$ADD_LOCAL_DATA_SELECTOR" '[.[] | select(((.to | ascii_downcase) != $game) or (.selector == $sel))]')"
    else
      warn "the step transaction was not found by scanning the L1 blocks from $step_block; the claim list still shows the leaf countered"
    fi
  fi
  oracle_min="$(cast call "$ORACLE" 'minProposalSize()(uint256)' --rpc-url "$L1_URL" 2>/dev/null | awk '{print $1}' || true)"
  oracle_period="$(cast call "$ORACLE" 'challengePeriod()(uint256)' --rpc-url "$L1_URL" 2>/dev/null | awk '{print $1}' || true)"
  honest_log="$dir/honest-challenger.log"
  docker logs "$(docker ps --format '{{.Names}}' | grep '^finchain-devnet-op-challenger-' | head -1)" 2>&1 | grep -i -- "$game" | tail -n 400 > "$honest_log" || true
  # the honest side's own account: the L2 block its cannon runs disputed and the trace index its last run proved
  disputed_block="$(grep -o 'claimed-l2-block-number, [0-9]*' "$honest_log" | tail -1 | awk '{print $2}')"
  honest_proof_at="$(grep -o 'proof-at, =[0-9]*' "$honest_log" | tail -1 | sed 's/.*=//')"
  local n_adv n_hon
  n_adv="$(jq -r --arg me "$ADVERSARY" '[.claims[] | select((.claimant | ascii_downcase) == $me)] | length' <<<"$claims")"
  n_hon="$(jq -r --arg me "$HONEST" '[.claims[] | select((.claimant | ascii_downcase) == $me)] | length' <<<"$claims")"
  local ev="$FINCHAIN_ROOT/manifests/evidence/devnet-dispute-$DEVNET_L2_CHAIN_ID-$stamp.json" anchor_rec=null
  [ ! -f "$OUT/chain/anchor.json" ] || anchor_rec="$(jq -c . "$OUT/chain/anchor.json")"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson anchorboot "$anchor_rec" --arg started "$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$DEVNET_L2_CHAIN_ID" --argjson l1cid "$DEVNET_L1_CHAIN_ID" \
    --slurpfile l1 "$OUT/chain/l1.json" --slurpfile rec "$OUT/chain/chain-record.json" --slurpfile g8 "$OUT/chain/game-type-$DEVNET_GAME_TYPE.json" --slurpfile ginfo "$dir/game.json" \
    --arg pre "${DEVNET_PRESTATE_HASH:-}" --arg prerec "${DEVNET_PRESTATE_RECORD:-}" --arg khsha "${DEVNET_KONA_HOST_SHA256:-}" --arg khrec "${DEVNET_KONA_HOST_RECORD:-}" --arg kcrec "${DEVNET_KONA_CONFIGS_RECORD:-}" \
    --arg game "$game" --argjson maxd "$max_depth" --argjson splitd "$split_depth" --arg adv "$ADVERSARY" --arg hon "$HONEST" --arg prop "$PROPOSER" --arg starting "$starting" \
    --argjson moves "$moves" --argjson defends "$defends" --argjson nadv "$n_adv" --argjson nhon "$n_hon" --argjson txs "$(printf '%s\n' "${txs[@]+"${txs[@]}"}" | jq -cs 'map(select(. != null))')" \
    --arg strategy "$STRATEGY" --argjson seed "$SEED" --argjson oracletxs "$oracle_txs" --arg oracle "$ORACLE" --arg omin "$oracle_min" --arg operiod "$oracle_period" \
    --arg dblock "$disputed_block" --arg hproof "$honest_proof_at" \
    --slurpfile final "$dir/claims-final.json" --argjson step "$step_tx" --arg leaf "$leaf_idx" --arg anchor "$anchor_before" --arg dir "drill/devnet/out/evidence/dispute-$stamp" \
    --arg result "$result" --arg reason "$reason" --arg opn "${OP_NODE_IMAGE:?}" --arg opr "${OP_RETH_IMAGE:?}" --arg opb "${OP_BATCHER_IMAGE:?}" --arg opp "${OP_PROPOSER_IMAGE:?}" --arg opc "$IMAGE" '
    def num: if . == "" then null else tonumber end;
    {schema: "finchain.devnet-dispute/2",
     acceptance: "M4 K3: isolated devnet - a CANNON_KONA game on Finchain configuration defended down to a real step() on chain (docs/acceptance.md M4; docs/proof-plan.md K3)",
     environment: "local-devnet", chainId: $cid, l1ChainId: $l1cid, startedAt: $started, recordedAt: $at,
     what: ("the honest op-proposer posted a correct root as a type-8 game; drill/devnet/adversary.sh attacked it and "
            + (if $strategy == "inside" then "answered every honest reply with an arbitrary claim, attacking or defending at random while the position stayed inside the chain and the trace" else "attacked every honest reply with an arbitrary claim" end)
            + "; the resident op-challenger (cannon-kona, the devnet prestate, the embedded kona-host) answered each; at the max depth the leaf of the attacker could only be countered by step(), which the honest challenger executed on chain"),
     devnet: {l1: $l1[0], images: {opNode: $opn, opReth: $opr, opBatcher: $opb, opProposer: $opp, opChallenger: $opc}},
     deployment: $rec[0],
     gameTypeInstall: $g8[0],
     anchorBootstrap: $anchorboot,
     prestate: {hash: $pre, record: $prerec}, konaHost: {sha256: $khsha, record: $khrec}, konaConfigs: {record: (if $kcrec == "" then null else $kcrec end)},
     game: ($ginfo[0] + {address: $game, maxDepth: $maxd, splitDepth: $splitd, startingRootHash: $starting}),
     parties: {proposer: $prop, honestChallenger: $hon, attacker: $adv},
     dispute: {attackerMoves: $moves, attackerDefends: $defends, attackerClaims: $nadv, honestClaims: $nhon, finalClaimCount: $final[0].claimCount, moves: $txs, snapshots: $dir,
               strategy: {name: $strategy, seed: $seed,
                          description: (if $strategy == "inside"
                                        then "attack or defend each honest claim at random with a random value (op-challenger move --attack / --defend), defending only where the position stays inside the chain (the honest output claim differs from the root claim) and inside the trace (the honest claim carries VM status 0x03, unfinished); the root and the split-depth claim are always attacked; intermediate claims are unverified by the contract, only the bond schedule is paid"
                                        else "attack every claim of the honest side with a random value (op-challenger move --attack); intermediate claims are unverified by the contract, only the bond schedule is paid" end)}},
     step: {transaction: $step, leafClaimIndex: ($leaf | num),
            leaf: (if $leaf == "" then null else ($final[0].claims[] | select(.index == ($leaf | tonumber))) end),
            disputedL2Block: ($dblock | num), honestProofAt: ($hproof | num),
            oracle: {address: $oracle, minProposalSize: ($omin | num), challengePeriod: ($operiod | num), uploadsBeforeStep: $oracletxs,
                     note: "the honest challenger loads the preimage parts a step reads before it steps: local data through the game (addLocalData), global preimages into the PreimageOracle (loadKeccak256PreimagePart and the others; a large one through initLPP, addLeavesLPP, squeezeLPP after the challenge period); an instruction that reads no preimage needs no upload"},
            meaning: "step(claimIndex, isAttack, stateData, proof): the MIPS contract executes one instruction of the kona-client trace from the agreed pre-state (the absolute prestate at trace index 0, the honest claim just before the leaf otherwise) with the preimage oracle and finds the leaf claim wrong; counteredBy is the honest challenger"},
     resolution: {status: "IN_PROGRESS", anchorRootBefore: $anchor, note: "the clocks run out after the last move; drill/devnet/adversary.sh resolve completes this record"},
     result: $result, reason: $reason}' > "$ev"
  printf 'DEVNET_DISPUTE_RECORD=%s\nDEVNET_DISPUTE_GAME=%s\nDEVNET_DISPUTE_DIR=%s\n' "manifests/evidence/$(basename "$ev")" "$game" "$dir" >> "$GEN"
  echo "dispute $result: $reason ($moves attacker moves, $n_hon honest claims)"
  [ "$step_tx" = null ] || echo "step tx: $(jq -r '"\(.hash) in block \(.block) from \(.from), status \(.status), gas \(.gasUsed)"' <<<"$step_tx")"
  echo "record: $ev"
  echo "snapshots and the honest challenger's log lines: $dir"
  [ "$result" = PASS ] || exit 3
}

###############################################################################################################
cmd_resolve() {
  require_devnet
  local ev="${DEVNET_DISPUTE_RECORD:-}" game="${DEVNET_DISPUTE_GAME:-}" dir="${DEVNET_DISPUTE_DIR:-}"
  [ -n "$ev" ] && [ -f "$FINCHAIN_ROOT/$ev" ] || die "no dispute record in generated.env: adversary.sh dispute first"
  local timeout t0 st
  timeout="${RESOLVE_TIMEOUT:-$(( DEVNET_GAME_MAX_CLOCK_DURATION + 3600 ))}"; timeout="$(to_seconds "$timeout")"
  t0="$(date +%s)"
  log "waiting for game $game to resolve (clocks of ${DEVNET_GAME_MAX_CLOCK_DURATION}s; the honest challenger resolves claims and the game once they run out); timeout ${timeout}s"
  while :; do
    st="$(game_status "$game")"
    [ "$st" != 0 ] && break
    [ $(( $(date +%s) - t0 )) -lt "$timeout" ] || break
    sleep 30
  done
  local name resolve_tx claims credit_adv credit_hon credit_prop anchor_after resolved_at
  name="$(status_name "$st")"
  resolve_tx="$(find_tx "$game" "$RESOLVE_SELECTOR" "$(jq -r '.step.transaction.block // 1' "$FINCHAIN_ROOT/$ev")" || echo null)"
  claims="$(list_claims "$game" || echo '{}')"; [ -z "$dir" ] || printf '%s\n' "$claims" > "$dir/claims-resolved.json"
  credit_adv="$(cast call "$game" 'credit(address)(uint256)' "$ADVERSARY" --rpc-url "$L1_URL" | awk '{print $1}')"
  credit_hon="$(cast call "$game" 'credit(address)(uint256)' "$HONEST" --rpc-url "$L1_URL" | awk '{print $1}')"
  credit_prop="$(cast call "$game" 'credit(address)(uint256)' "$PROPOSER" --rpc-url "$L1_URL" | awk '{print $1}')"
  resolved_at="$(cast call "$game" 'resolvedAt()(uint64)' --rpc-url "$L1_URL" | awk '{print $1}')"
  anchor_after="$(anchor_root)"
  local result reason
  if [ "$st" = 2 ]; then result=PASS; reason="DEFENDER_WINS: the honest root stood, the attacker's claims lost"; else result=FAIL; reason="game status $name after ${timeout}s"; fi
  local tmp; tmp="$(mktemp)"
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg name "$name" --argjson st "$st" --argjson rtx "$resolve_tx" --arg ca "$credit_adv" --arg ch "$credit_hon" --arg cp "$credit_prop" \
     --arg anchor "$anchor_after" --arg resolved "$resolved_at" --arg result "$result" --arg reason "$reason" --arg claims "$(jq -c '.claims // [] | map({index, depth, claimant, counteredBy: (.counteredBy // ""), resolved})' <<<"$claims")" '
     .resolution = {status: $name, statusCode: $st, resolvedAt: (if $resolved == "" or $resolved == "0" then null else ($resolved | tonumber) end), resolveTransaction: $rtx,
                    creditWei: {attacker: $ca, honestChallenger: $ch, proposer: $cp}, anchorRootBefore: .resolution.anchorRootBefore, anchorRootAfter: $anchor,
                    claims: ($claims | fromjson), recordedAt: $at}
     | .result = (if .result == "PASS" and $result == "PASS" then "PASS" else "FAIL" end)
     | .reason = (.reason + "; resolution: " + $reason)' "$FINCHAIN_ROOT/$ev" > "$tmp" && mv "$tmp" "$FINCHAIN_ROOT/$ev"
  echo "game $game: $name; credit (wei) attacker $credit_adv, honest challenger $credit_hon, proposer $credit_prop"
  echo "anchor root: before $(jq -r .resolution.anchorRootBefore "$FINCHAIN_ROOT/$ev"); after $anchor_after"
  echo "record: $FINCHAIN_ROOT/$ev ($(jq -r .result "$FINCHAIN_ROOT/$ev"))"
  [ "$(jq -r .result "$FINCHAIN_ROOT/$ev")" = PASS ] || exit 3
}

case "${1:-}" in
  dispute) cmd_dispute ;;
  resolve) cmd_resolve ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
