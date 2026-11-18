#!/usr/bin/env bash
# M4 K4 (host A): one game of the Type 8 (CANNON_KONA) implementation on Finchain Sepolia, with an honest root, created the
# way op-proposer creates the respected type's games - the output root of a finalized L2 block from op-node's
# optimism_outputAtBlock, DisputeGameFactory.create(gameType, rootClaim, abi.encode(l2BlockNumber)) with the type's initial
# bond, sent by the proposer account. op-challenger's own `create-game` subcommand does the sending (it reads the bond from
# the factory). The game is not of the respected type: it moves no anchor and settles no withdrawal; what it shows is host
# B's cannon-kona challenger accepting the installed arguments (prestate, starting root) and resolving it after the
# clock (docs/proof-plan.md, "K4"). Precondition, checked here: the type is installed with the K2 prestate and the anchor
# root has left op-deployer's placeholder (make k4-readiness).
#
# Usage: scripts/k4-create-game.sh            (make k4-create-game; on host A, where the proposer key is)
#   GAME_TYPE (default 8), L2_BLOCK (default: op-node's finalized L2 block), DRY_RUN=1 (print, do not send).
#   The proposer key stays in node-a/secrets/op-proposer.env; it is handed to the CLI container as an environment variable
#   and never printed. Writes manifests/evidence/k4-game-<date>.json.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl docker
load_standard_env
GAME_TYPE="${GAME_TYPE:-8}"
AENV="$(host_env a)"; [ -f "$AENV" ] || die "node-a/.env$ENV_SUFFIX not found: this runs on host A"
envval() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
L1="$(envval "$AENV" L1_RPC_URL)"; [ -n "$L1" ] || L1="${L1_RPC_URL:?}"
L1_LABEL="$(rpc_label "$L1")"
bind_ip="$(envval "$AENV" A_BIND_IP)"; node_port="$(envval "$AENV" A_NODE_RPC_PORT)"
NODE="http://${bind_ip:-127.0.0.1}:${node_port:-8547}"
SECRETS="$(secrets_dir a)/op-proposer.env"; [ -s "$SECRETS" ] || die "proposer key file not found: $SECRETS"
ADDRS="$CHAIN_DIR/out/l1-addresses.json"; DGF="$(jq -r .DisputeGameFactoryProxy "$ADDRS")"; ASR="$(jq -r .AnchorStateRegistryProxy "$ADDRS")"
L2_CHAIN_ID="$(jq -r .chainId "$CHAIN_DIR/out/chain-record.json")"
DEAD_ROOT=0xdead000000000000000000000000000000000000000000000000000000000000

ecall() { rpc "$L1" eth_call "[{\"to\":\"$1\",\"data\":\"$2\"},\"latest\"]" | jq -r '.result // empty'; }
word_n() { printf '%d' "0x$(printf '%s' "$1" | cut -c$((3 + 64 * $2))-$((2 + 64 * ($2 + 1))))"; }
word_addr() { echo "0x$(printf '%s' "$1" | cut -c$((27 + 64 * $2))-$((2 + 64 * ($2 + 1))))"; }
word_hex() { echo "0x$(printf '%s' "$1" | cut -c$((3 + 64 * $2))-$((2 + 64 * ($2 + 1))))"; }
pad_u() { printf '%064x' "$1"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# preconditions: the type is installed with the K2 prestate, the anchor has moved
impl="$(word_addr "$(ecall "$DGF" "0x1b685b9e$(pad_u "$GAME_TYPE")")" 0)"
[ "$(lower "$impl")" != "0x0000000000000000000000000000000000000000" ] || die "game type $GAME_TYPE has no implementation on the factory yet (owner-console.html, setImplementation)"
args_raw="$(ecall "$DGF" "0x74cc86ac$(pad_u "$GAME_TYPE")")"; args_len="$(word_n "$args_raw" 1)"
installed_prestate="0x$(printf '%s' "$args_raw" | cut -c131-194)"
prestate_rec="$(find "$FINCHAIN_ROOT/manifests/evidence" -maxdepth 1 -name "prestate-$L2_CHAIN_ID-*.json" | sort | tail -1)"
k2_prestate="$(jq -r .prestate.hash "$prestate_rec")"
[ "$(lower "$installed_prestate")" = "$(lower "$k2_prestate")" ] || die "game type $GAME_TYPE carries prestate $installed_prestate, not the K2 prestate $k2_prestate"
anchor_raw="$(ecall "$ASR" "0xd83ef267")"; anchor_root="$(word_hex "$anchor_raw" 0)"; anchor_block="$(word_n "$anchor_raw" 1)"
[ "$(lower "$anchor_root")" != "$DEAD_ROOT" ] || die "the anchor root is still op-deployer's placeholder: a Type $GAME_TYPE game would start from it and the honest challenger would refuse it (drill/devnet/README.md)"
bond="$(word_n "$(ecall "$DGF" "0x6593dc6e$(pad_u "$GAME_TYPE")")" 0)"

# the honest root: op-node's output at the finalized L2 block (or L2_BLOCK), the way op-proposer proposes
sync="$(rpc "$NODE" optimism_syncStatus | jq -c .result)" || die "op-node at $NODE did not answer optimism_syncStatus"
finalized="$(jq -r '.finalized_l2.number' <<<"$sync")"
L2_BLOCK="${L2_BLOCK:-$finalized}"
[ "$L2_BLOCK" -gt "$anchor_block" ] || die "L2 block $L2_BLOCK is not after the anchor block $anchor_block"
out="$(rpc "$NODE" optimism_outputAtBlock "[\"$(printf '0x%x' "$L2_BLOCK")\"]" | jq -c .result)"
root="$(jq -r .outputRoot <<<"$out")"; [ -n "$root" ] && [ "$root" != null ] || die "op-node gave no output root for block $L2_BLOCK"
echo "Type $GAME_TYPE game on Finchain Sepolia through $L1_LABEL"
echo "  implementation $impl ($args_len bytes of arguments, prestate $installed_prestate); anchor $anchor_root at L2 block $anchor_block"
echo "  root claim: output root $root of L2 block $L2_BLOCK (op-node finalized $finalized); initial bond $bond wei"
if [ "${DRY_RUN:-0}" = 1 ]; then echo "  DRY_RUN=1: nothing sent"; exit 0; fi

# send with op-challenger's create-game, the proposer key as the CLI's key (environment only, never printed)
key="$(envval "$SECRETS" OP_PROPOSER_PRIVATE_KEY)"; [ -n "$key" ] || die "OP_PROPOSER_PRIVATE_KEY missing in $SECRETS"
log "creating the game (op-challenger create-game, proposer account)"
cli_out="$(docker run --rm --network host -e "OP_CHALLENGER_PRIVATE_KEY=$key" --entrypoint op-challenger "${OP_CHALLENGER_IMAGE:?}" \
  create-game --l1-eth-rpc "$L1" --game-factory-address "$DGF" --game-type "$GAME_TYPE" --output-root "$root" --l2-block-num "$L2_BLOCK" 2>&1)" || { printf '%s\n' "$cli_out" | sed "s#$L1#$L1_LABEL#g" | tail -n 20; die "create-game failed"; }
game="$(printf '%s' "$cli_out" | sed -nE 's/.*Fetched Game Address: (0x[0-9a-fA-F]{40}).*/\1/p' | tail -1)"
tx="$(printf '%s' "$cli_out" | sed -nE 's/.*(hash: |tx=)(0x[0-9a-fA-F]{64}).*/\2/p' | tail -1)"
[ -n "$game" ] || { printf '%s\n' "$cli_out" | sed "s#$L1#$L1_LABEL#g" | tail -n 20; die "no game address in the CLI output"; }
count="$(word_n "$(ecall "$DGF" "0x4d1975b4")" 0)"
rec="$FINCHAIN_ROOT/manifests/evidence/k4-game-$(date -u +%Y%m%dT%H%M%SZ).json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg l1 "$L1_LABEL" --argjson cid "$L2_CHAIN_ID" --arg dgf "$DGF" --argjson gt "$GAME_TYPE" --arg impl "$impl" --arg pre "$installed_prestate" \
  --arg game "$game" --arg tx "$tx" --argjson idx "$((count - 1))" --argjson l2 "$L2_BLOCK" --arg root "$root" --argjson fin "$finalized" --arg aroot "$anchor_root" --argjson ablock "$anchor_block" --arg bond "$bond" '
  {schema: "finchain.k4-game/1",
   acceptance: "M4 K4: one game of the Type 8 (CANNON_KONA) implementation on the public testnet, an honest root created by the proposer account, for host B'"'"'s cannon-kona challenger to track and resolve (docs/acceptance.md M4; docs/proof-plan.md K4)",
   environment: "public-testnet", chainId: $cid, createdAt: $at, l1Rpc: $l1, disputeGameFactory: $dgf,
   game: {gameType: $gt, implementation: $impl, absolutePrestate: $pre, address: $game, index: $idx, creationTx: (if $tx == "" then null else $tx end), l2BlockNumber: $l2, rootClaim: $root, opNodeFinalizedAtCreation: $fin, initBondWei: $bond},
   anchorAtCreation: {root: $aroot, l2Block: $ablock},
   note: "not the respected game type: it moves no anchor and settles no withdrawal; make games EXTRA_TYPES=8 reads it back; the honest challenger on host B resolves it after maxClockDuration"}' > "$rec"
echo "game $game (index $((count - 1))) created; tx ${tx:-?}; record $rec"
echo "next: make games EXTRA_TYPES=8 (reads it back), make logs-b KONA=1 SVC=op-challenger on host B (the challenger tracking it)"
