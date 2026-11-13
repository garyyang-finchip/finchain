#!/usr/bin/env bash
# M4: an ETH withdrawal from Finchain to Sepolia through the fault-proof path, one step at a time, with a
# record that grows as the steps complete (docs/acceptance.md M4, "deposit -> proof -> withdrawal end to end
# with the actual waiting periods recorded"; docs/handbook.md 3.5).
#
#   initiate  L2: L2ToL1MessagePasser.initiateWithdrawal(target, gasLimit, "") with the amount; the MessagePassed
#             event gives the withdrawal (nonce, sender, target, value, gasLimit, data) and its hash, recomputed here.
#   status    L1: the portal's delays and respected game type, the earliest game of that type whose L2 block covers
#             the withdrawal, whether the withdrawal is proven or finalized, and what the portal says stands in the way.
#   prove     L1: OptimismPortal2.proveWithdrawalTransaction against that game. The output root proof is built from
#             the public L2 RPC alone (the block's state root and hash, the message passer's storage root and the
#             storage proof of sentMessages[hash] by eth_getProof at the game's L2 block) and must hash to the game's
#             root claim before anything is sent. The L2 node needs --rpc.eth-proof-window (node-b/docker-compose.yml).
#   finalize  L1: after the proof maturity delay and the game's resolution plus finality delay,
#             OptimismPortal2.finalizeWithdrawalTransaction; the target's L1 balance before and after.
#
# Usage: scripts/withdraw.sh initiate <amount-eth> [to-address=<the key's address>] [key-role=deployer]
#        scripts/withdraw.sh status   <record.json>
#        scripts/withdraw.sh prove    <record.json> [game-index] [key-role=deployer]
#        scripts/withdraw.sh finalize <record.json> [key-role=deployer]
# Environment: L2_RPC (default https://rpc.finchain.one), YES=1 skips the prompts, DEPOSIT_TX=<l1 tx hash> records
# the deposit that funded this cycle (initiate). The record lands in manifests/evidence/withdrawal-<date>.json.
# Exit 2 when a step is not possible yet (no covering game, not matured, not resolved); exit 3 on a mismatch.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk
load_standard_env
[ -n "${CAST_BIN:-}" ] || require_cmd docker

CMD="${1:-}"; shift || true
L2_RPC="${L2_RPC:-https://rpc.finchain.one}"
REC="$FINCHAIN_ROOT/chain/out/chain-record.json"
PORTAL="$(jq -r '.l1.OptimismPortalProxy // empty' "$REC")"
DGF="$(jq -r '.l1.DisputeGameFactoryProxy // empty' "$REC")"
[ -n "$PORTAL" ] && [ -n "$DGF" ] || die "OptimismPortalProxy / DisputeGameFactoryProxy missing in $REC"
PASSER=0x4200000000000000000000000000000000000016
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
WITHDRAWAL_GAS_LIMIT=100000

usage() { die "usage: scripts/withdraw.sh initiate <amount-eth> [to] [role] | status <record> | prove <record> [game-index] [role] | finalize <record> [role]"; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
l1call() { cast call --rpc-url "$L1_RPC_URL" "$@"; }
first_word() { awk '{ print $1 }'; }           # cast prints large numbers as "1794414672 [1.794e9]"
lower() { tr '[:upper:]' '[:lower:]'; }
hex_block() { printf '0x%x' "$1"; }
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
l2_block_timestamp() { rpc "$L2_RPC" eth_getBlockByNumber "[\"$(hex_block "$1")\",false]" | jq -r '.result.timestamp' | xargs printf '%d'; }
l1_block_timestamp() { rpc "$L1_RPC_URL" eth_getBlockByNumber "[\"$(hex_block "$1")\",false]" | jq -r '.result.timestamp' | xargs printf '%d'; }
record_set() { # record_set <file> <jq filter> [--arg/--argjson ...]
  local f="$1" filter="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  jq "$@" "$filter" "$f" > "$tmp" && mv "$tmp" "$f"
}
# the withdrawal hash as the contracts compute it: keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))
withdrawal_hash() { cast keccak "$(cast abi-encode "f(uint256,address,address,uint256,uint256,bytes)" "$1" "$2" "$3" "$4" "$5" "$6")"; }
game_l2_block() { # the L2 block a fault dispute game claims (its extraData is abi.encode(l2BlockNumber))
  local x; x="$(l1call "$1" "extraData()(bytes)")"
  printf '%d' "0x${x:2:64}"
}
game_status_name() { case "$1" in 0) echo IN_PROGRESS ;; 1) echo CHALLENGER_WINS ;; 2) echo DEFENDER_WINS ;; *) echo "unknown($1)" ;; esac; }

# The earliest game of the respected type whose L2 block is at or above the withdrawal's block: scans the factory
# from the newest game backwards until the games fall below that block. Prints "index proxy l2block createdAt".
covering_game() {
  local wblock="$1" respected="$2" count i type ts proxy l2b best="" scanned=0
  count="$(l1call "$DGF" "gameCount()(uint256)" | first_word)"
  i=$((count - 1))
  while [ "$i" -ge 0 ] && [ "$scanned" -lt 400 ]; do
    { read -r type; read -r ts; read -r proxy; } < <(l1call "$DGF" "gameAtIndex(uint256)(uint32,uint64,address)" "$i")
    type="$(first_word <<<"$type")"; ts="$(first_word <<<"$ts")"
    if [ "$type" = "$respected" ]; then
      l2b="$(game_l2_block "$proxy")"
      if [ "$l2b" -ge "$wblock" ]; then best="$i $proxy $l2b $ts"; else break; fi
    fi
    i=$((i - 1)); scanned=$((scanned + 1))
  done
  [ -n "$best" ] && echo "$best"
}

case "$CMD" in
# ---------------------------------------------------------------------------------------------------------------
initiate)
  AMOUNT="${1:?amount in ETH}"; ROLE="${3:-deployer}"
  from="$(key_field "$ROLE" address)"; pk="$(key_field "$ROLE" private_key)"
  TO="${2:-$from}"
  case "$TO" in 0x[0-9a-fA-F]*) [ "${#TO}" = "42" ] || die "bad address: $TO" ;; *) die "bad address: $TO" ;; esac
  awk -v a="$AMOUNT" 'BEGIN { exit !(a > 0 && a < 10) }' || die "amount must be between 0 and 10 ETH: $AMOUNT"
  chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
  [ "$((chain_hex))" = "${CHAIN_ID:?}" ] || die "L2 RPC $L2_RPC reports chain id $((chain_hex)), .env says $CHAIN_ID"
  l1_chain_hex="$(rpc "$L1_RPC_URL" eth_chainId | jq -r .result)"
  echo "L2 RPC: $L2_RPC (chain id $((chain_hex))); L1 chain id $((l1_chain_hex)); portal $PORTAL"
  echo "from:   $from ($ROLE)  L2 $(hex_to_eth "$(rpc "$L2_RPC" eth_getBalance "[\"$from\",\"latest\"]" | jq -r .result)") ETH"
  echo "to:     $TO on L1  $(hex_to_eth "$(rpc "$L1_RPC_URL" eth_getBalance "[\"$TO\",\"latest\"]" | jq -r .result)") ETH"
  echo "amount: $AMOUNT ETH; gas limit for the L1 call $WITHDRAWAL_GAS_LIMIT"
  if [ "${YES:-0}" != "1" ]; then
    read -r -p "Initiate the withdrawal now? [yes/NO] " answer
    [ "$answer" = "yes" ] || die "aborted; nothing was sent"
  fi
  r="$(cast send --rpc-url "$L2_RPC" --private-key "$pk" --value "${AMOUNT}ether" --json "$PASSER" "initiateWithdrawal(address,uint256,bytes)" "$TO" "$WITHDRAWAL_GAS_LIMIT" 0x)" || die "initiateWithdrawal failed"
  [ "$(jq -r .status <<<"$r")" = "0x1" ] || die "initiateWithdrawal reverted: $(jq -r .transactionHash <<<"$r")"
  tx="$(jq -r .transactionHash <<<"$r")"; block=$(( $(jq -r .blockNumber <<<"$r") ))
  topic0="$(cast keccak "MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)")"
  logj="$(jq -c --arg t "$topic0" --arg a "$PASSER" '[.logs[] | select((.topics[0] | ascii_downcase) == ($t | ascii_downcase) and (.address | ascii_downcase) == ($a | ascii_downcase))] | first' <<<"$r")"
  [ -n "$logj" ] && [ "$logj" != "null" ] || die "no MessagePassed event in the receipt of $tx"
  nonce="$(jq -r '.topics[1]' <<<"$logj")"
  sender="0x$(jq -r '.topics[2]' <<<"$logj" | cut -c27-66)"
  target="0x$(jq -r '.topics[3]' <<<"$logj" | cut -c27-66)"
  { read -r value; read -r gas_limit; read -r data; read -r ev_hash; } < <(cast abi-decode "f()(uint256,uint256,bytes,bytes32)" "$(jq -r .data <<<"$logj")")
  value="$(first_word <<<"$value")"; gas_limit="$(first_word <<<"$gas_limit")"
  computed="$(withdrawal_hash "$nonce" "$sender" "$target" "$value" "$gas_limit" "$data")"
  [ "$(lower <<<"$computed")" = "$(lower <<<"$ev_hash")" ] || { echo "withdrawal hash mismatch: event $ev_hash, recomputed $computed"; exit 3; }
  ts="$(l2_block_timestamp "$block")"
  out="$FINCHAIN_ROOT/manifests/evidence/withdrawal-$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$out")"
  deposit=null
  if [ -n "${DEPOSIT_TX:-}" ]; then
    drc="$(rpc "$L1_RPC_URL" eth_getTransactionReceipt "[\"$DEPOSIT_TX\"]" | jq -c '.result')"
    if [ -n "$drc" ] && [ "$drc" != "null" ]; then
      dblock=$(( $(jq -r .blockNumber <<<"$drc") ))
      deposit="$(jq -cn --arg tx "$DEPOSIT_TX" --argjson b "$dblock" --arg at "$(iso_of "$(l1_block_timestamp "$dblock")")" --arg to "$(jq -r .to <<<"$drc")" --arg st "$(jq -r .status <<<"$drc")" '{tx: $tx, l1Block: $b, at: $at, to: $to, status: $st, note: "the deposit that funded this cycle (scripts/deposit.sh): ETH sent to the OptimismPortal, credited on L2 by derivation"}')"
    else
      warn "DEPOSIT_TX $DEPOSIT_TX has no receipt on L1; recorded as given"
      deposit="$(jq -cn --arg tx "$DEPOSIT_TX" '{tx: $tx}')"
    fi
  fi
  jq -n --argjson chainId "$CHAIN_ID" --argjson l1ChainId "$((l1_chain_hex))" --arg l2rpc "$L2_RPC" --arg portal "$PORTAL" --arg dgf "$DGF" --arg passer "$PASSER" \
    --arg nonce "$nonce" --arg sender "$sender" --arg target "$target" --arg value "$value" --arg gas "$gas_limit" --arg data "$data" --arg hash "$ev_hash" \
    --arg tx "$tx" --argjson block "$block" --arg at "$(iso_of "$ts")" --argjson tsn "$ts" --arg amount "$AMOUNT" --arg role "$ROLE" --argjson deposit "$deposit" --arg now "$(now_utc)" '
    {schema: "finchain.withdrawal/1",
     acceptance: "M4: deposit -> proof -> withdrawal end to end with the actual waiting periods (docs/acceptance.md M4; docs/proof-plan.md)",
     environment: "public-testnet", chainId: $chainId, l1ChainId: $l1ChainId, l2Rpc: $l2rpc,
     contracts: {optimismPortal: $portal, disputeGameFactory: $dgf, l2ToL1MessagePasser: $passer},
     path: "L2ToL1MessagePasser.initiateWithdrawal -> an output proposal (a dispute game of the respected type) covering the L2 block -> OptimismPortal2.proveWithdrawalTransaction against that game -> proof maturity delay, the game resolved and past its finality delay -> OptimismPortal2.finalizeWithdrawalTransaction",
     deposit: $deposit,
     withdrawal: {nonce: $nonce, sender: $sender, target: $target, valueWei: $value, valueEth: $amount, gasLimit: ($gas | tonumber), data: $data, hash: $hash, hashRecomputed: true, signer: $role},
     steps: {initiate: {l2Tx: $tx, l2Block: $block, l2BlockTimestamp: $tsn, at: $at, recordedAt: $now}},
     status: "initiated"}' > "$out"
  echo "withdrawal $ev_hash initiated: L2 tx $tx in block $block at $(iso_of "$ts")"
  echo "record $out"
  echo "next: scripts/withdraw.sh status $out  (a game of the respected type covering block $block appears within one proposal interval), then prove"
  ;;
# ---------------------------------------------------------------------------------------------------------------
status|prove|finalize)
  RECORD="${1:?record.json}"; [ -f "$RECORD" ] || die "not found: $RECORD"
  whash="$(jq -r .withdrawal.hash "$RECORD")"; wblock="$(jq -r .steps.initiate.l2Block "$RECORD")"
  nonce="$(jq -r .withdrawal.nonce "$RECORD")"; sender="$(jq -r .withdrawal.sender "$RECORD")"; target="$(jq -r .withdrawal.target "$RECORD")"
  value="$(jq -r .withdrawal.valueWei "$RECORD")"; gas_limit="$(jq -r .withdrawal.gasLimit "$RECORD")"; data="$(jq -r .withdrawal.data "$RECORD")"
  wtx="($nonce,$sender,$target,$value,$gas_limit,$data)"
  respected="$(l1call "$PORTAL" "respectedGameType()(uint32)" | first_word)"
  maturity="$(l1call "$PORTAL" "proofMaturityDelaySeconds()(uint256)" | first_word)"
  finality="$(l1call "$PORTAL" "disputeGameFinalityDelaySeconds()(uint256)" | first_word)"
  echo "withdrawal $whash: $(hex_to_eth "$(printf '0x%x' "$value")") ETH from $sender (L2 block $wblock) to $target; portal $PORTAL"
  echo "portal: respected game type $respected, proof maturity $maturity s ($((maturity / 3600)) h), game finality delay $finality s ($((finality / 3600)) h)"
  ;;&
status)
  found="$(covering_game "$wblock" "$respected" || true)"
  if [ -z "$found" ]; then echo "no game of type $respected covers block $wblock yet (the proposer's interval decides; try again later)"; else
    read -r gi gproxy gl2 gts <<<"$found"
    gstatus="$(l1call "$gproxy" "status()(uint8)" | first_word)"; gresolved="$(l1call "$gproxy" "resolvedAt()(uint64)" | first_word)"
    echo "covering game: index $gi at $gproxy, L2 block $gl2, created $(iso_of "$gts"), status $(game_status_name "$gstatus")$([ "$gresolved" != "0" ] && echo ", resolved $(iso_of "$gresolved")")"
  fi
  for submitter in $(jq -r '[.steps.prove.proofSubmitter // empty, .withdrawal.sender] | unique | .[]' "$RECORD"); do
    { read -r pgame; read -r pts; } < <(l1call "$PORTAL" "provenWithdrawals(bytes32,address)(address,uint64)" "$whash" "$submitter")
    pts="$(first_word <<<"$pts")"
    if [ "$pts" != "0" ]; then
      echo "proven by $submitter at $(iso_of "$pts") against game $pgame; matures at $(iso_of $((pts + maturity)))"
      if reason="$(l1call "$PORTAL" "checkWithdrawal(bytes32,address)" "$whash" "$submitter" 2>&1)"; then echo "finalize: the portal accepts it now"; else echo "finalize: not yet - $(grep -o 'OptimismPortal[^,"]*' <<<"$reason" | head -1 || tail -1 <<<"$reason")"; fi
    else
      echo "not proven by $submitter"
    fi
  done
  [ "$(l1call "$PORTAL" "finalizedWithdrawals(bytes32)(bool)" "$whash")" = "true" ] && echo "finalized: yes" || echo "finalized: no"
  echo "record status: $(jq -r .status "$RECORD")"
  ;;
# ---------------------------------------------------------------------------------------------------------------
prove)
  ROLE="${3:-deployer}"; from="$(key_field "$ROLE" address)"; pk="$(key_field "$ROLE" private_key)"
  if [ -n "${2:-}" ]; then
    gi="$2"
    { read -r type; read -r gts; read -r gproxy; } < <(l1call "$DGF" "gameAtIndex(uint256)(uint32,uint64,address)" "$gi")
    [ "$(first_word <<<"$type")" = "$respected" ] || die "game $gi is of type $(first_word <<<"$type"), not the respected type $respected"
    gts="$(first_word <<<"$gts")"; gl2="$(game_l2_block "$gproxy")"
    [ "$gl2" -ge "$wblock" ] || die "game $gi claims L2 block $gl2, below the withdrawal's block $wblock"
  else
    found="$(covering_game "$wblock" "$respected" || true)"
    [ -n "$found" ] || { echo "NOT YET: no game of type $respected covers block $wblock; try again after the next proposal"; exit 2; }
    read -r gi gproxy gl2 gts <<<"$found"
  fi
  root_claim="$(l1call "$gproxy" "rootClaim()(bytes32)")"
  echo "game $gi at $gproxy: L2 block $gl2, created $(iso_of "$gts"), root claim $root_claim"
  # the output root proof from the L2 chain itself, at the game's block
  blk="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$(hex_block "$gl2")\",false]" | jq -c .result)"
  [ -n "$blk" ] && [ "$blk" != "null" ] || die "L2 block $gl2 not found on $L2_RPC"
  state_root="$(jq -r .stateRoot <<<"$blk")"; block_hash="$(jq -r .hash <<<"$blk")"
  slot="$(cast keccak "$(cast abi-encode "f(bytes32,uint256)" "$whash" 0)")"
  proofr="$(rpc "$L2_RPC" eth_getProof "[\"$PASSER\",[\"$slot\"],\"$(hex_block "$gl2")\"]")"
  if [ "$(jq -r '.error // empty' <<<"$proofr")" != "" ]; then
    die "eth_getProof at block $gl2 failed: $(jq -r .error.message <<<"$proofr"). The L2 node must allow historical proofs (op-reth --rpc.eth-proof-window; node-b/docker-compose.yml) and hold that block's state."
  fi
  storage_root="$(jq -r .result.storageHash <<<"$proofr")"
  sent="$(jq -r '.result.storageProof[0].value' <<<"$proofr")"
  [ "$((sent))" = "1" ] || { echo "sentMessages[$whash] is $sent at block $gl2: the withdrawal is not in that state (wrong block or wrong hash)"; exit 3; }
  proof_arg="[$(jq -r '.result.storageProof[0].proof | join(",")' <<<"$proofr")]"
  output_root="$(cast keccak "$(cast concat-hex "$ZERO32" "$state_root" "$storage_root" "$block_hash")")"
  if [ "$(lower <<<"$output_root")" != "$(lower <<<"$root_claim")" ]; then
    echo "MISMATCH: the output root computed from $L2_RPC at block $gl2 is $output_root; the game's root claim is $root_claim. Nothing sent."
    exit 3
  fi
  echo "output root $output_root equals the game's root claim; storage proof with $(jq -r '.result.storageProof[0].proof | length' <<<"$proofr") nodes"
  if [ "${YES:-0}" != "1" ]; then
    read -r -p "Prove the withdrawal on Sepolia now (signer $from)? [yes/NO] " answer
    [ "$answer" = "yes" ] || die "aborted; nothing was sent"
  fi
  r="$(cast send --rpc-url "$L1_RPC_URL" --private-key "$pk" --json "$PORTAL" \
        "proveWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes),uint256,(bytes32,bytes32,bytes32,bytes32),bytes[])" \
        "$wtx" "$gi" "($ZERO32,$state_root,$storage_root,$block_hash)" "$proof_arg")" || die "proveWithdrawalTransaction failed"
  [ "$(jq -r .status <<<"$r")" = "0x1" ] || die "proveWithdrawalTransaction reverted: $(jq -r .transactionHash <<<"$r")"
  tx="$(jq -r .transactionHash <<<"$r")"; l1b=$(( $(jq -r .blockNumber <<<"$r") ))
  { read -r pgame; read -r pts; } < <(l1call "$PORTAL" "provenWithdrawals(bytes32,address)(address,uint64)" "$whash" "$from")
  pts="$(first_word <<<"$pts")"
  # shellcheck disable=SC2016  # a jq filter: $p is jq's, not the shell's
  record_set "$RECORD" '.steps.prove = $p | .status = "proven"' --argjson p "$(jq -cn \
    --argjson gi "$gi" --arg gproxy "$gproxy" --argjson gl2 "$gl2" --argjson gts "$gts" --arg gcreated "$(iso_of "$gts")" --argjson gtype "$respected" --arg root "$root_claim" \
    --arg sr "$state_root" --arg mr "$storage_root" --arg bh "$block_hash" --arg or "$output_root" --argjson nodes "$(jq -r '.result.storageProof[0].proof | length' <<<"$proofr")" --arg slot "$slot" \
    --arg tx "$tx" --argjson l1b "$l1b" --arg at "$(iso_of "$pts")" --argjson pts "$pts" --arg submitter "$from" --arg matures "$(iso_of $((pts + maturity)))" --argjson maturity "$maturity" --argjson finality "$finality" --arg now "$(now_utc)" \
    '{game: {index: $gi, address: $gproxy, type: $gtype, l2Block: $gl2, createdAt: $gts, created: $gcreated, rootClaim: $root},
      outputRootProof: {version: "0x0000000000000000000000000000000000000000000000000000000000000000", stateRoot: $sr, messagePasserStorageRoot: $mr, latestBlockhash: $bh, outputRoot: $or, storageSlot: $slot, storageProofNodes: $nodes, source: "the public L2 RPC: eth_getBlockByNumber and eth_getProof at the game L2 block; the output root recomputed and compared with the game root claim before sending"},
      l1Tx: $tx, l1Block: $l1b, provenAt: $pts, at: $at, proofSubmitter: $submitter, proofMaturityDelaySeconds: $maturity, disputeGameFinalityDelaySeconds: $finality, maturesAt: $matures, recordedAt: $now}')"
  echo "proven: L1 tx $tx in block $l1b at $(iso_of "$pts") against game $gi; the proof matures at $(iso_of $((pts + maturity)))"
  echo "the game must also resolve (DEFENDER_WINS) and pass $finality s of finality delay; scripts/withdraw.sh status $RECORD shows both clocks"
  ;;
# ---------------------------------------------------------------------------------------------------------------
finalize)
  ROLE="${2:-deployer}"; from="$(key_field "$ROLE" address)"; pk="$(key_field "$ROLE" private_key)"
  submitter="$(jq -r '.steps.prove.proofSubmitter // empty' "$RECORD")"
  [ -n "$submitter" ] || die "the record has no prove step; run prove first"
  [ "$(lower <<<"$submitter")" = "$(lower <<<"$from")" ] || die "the proof was submitted by $submitter; finalize with that key (or add finalizeWithdrawalTransactionExternalProof)"
  if ! reason="$(l1call "$PORTAL" "checkWithdrawal(bytes32,address)" "$whash" "$submitter" 2>&1)"; then
    echo "NOT YET: $(grep -o 'OptimismPortal[^,"]*' <<<"$reason" | head -1 || tail -1 <<<"$reason")"; exit 2
  fi
  gproxy="$(jq -r .steps.prove.game.address "$RECORD")"
  gstatus="$(l1call "$gproxy" "status()(uint8)" | first_word)"; gresolved="$(l1call "$gproxy" "resolvedAt()(uint64)" | first_word)"
  before="$(rpc "$L1_RPC_URL" eth_getBalance "[\"$target\",\"latest\"]" | jq -r .result)"
  echo "game $(jq -r .steps.prove.game.index "$RECORD"): $(game_status_name "$gstatus"), resolved $(iso_of "$gresolved"); target $target holds $(hex_to_eth "$before") ETH on L1"
  if [ "${YES:-0}" != "1" ]; then
    read -r -p "Finalize the withdrawal on Sepolia now (signer $from)? [yes/NO] " answer
    [ "$answer" = "yes" ] || die "aborted; nothing was sent"
  fi
  r="$(cast send --rpc-url "$L1_RPC_URL" --private-key "$pk" --json "$PORTAL" "finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))" "$wtx")" || die "finalizeWithdrawalTransaction failed"
  [ "$(jq -r .status <<<"$r")" = "0x1" ] || die "finalizeWithdrawalTransaction reverted: $(jq -r .transactionHash <<<"$r")"
  tx="$(jq -r .transactionHash <<<"$r")"; l1b=$(( $(jq -r .blockNumber <<<"$r") )); fts="$(l1_block_timestamp "$l1b")"
  [ "$(l1call "$PORTAL" "finalizedWithdrawals(bytes32)(bool)" "$whash")" = "true" ] || { echo "finalizedWithdrawals is still false after $tx"; exit 3; }
  after="$(rpc "$L1_RPC_URL" eth_getBalance "[\"$target\",\"latest\"]" | jq -r .result)"
  its="$(jq -r .steps.initiate.l2BlockTimestamp "$RECORD")"; pts="$(jq -r .steps.prove.provenAt "$RECORD")"; gts="$(jq -r .steps.prove.game.createdAt "$RECORD")"
  # shellcheck disable=SC2016  # a jq filter: $f and $t are jq's, not the shell's
  record_set "$RECORD" '.steps.finalize = $f | .timeline = $t | .status = "finalized"' \
    --argjson f "$(jq -cn --arg tx "$tx" --argjson l1b "$l1b" --argjson fts "$fts" --arg at "$(iso_of "$fts")" --arg before "$before" --arg after "$after" --argjson gstatus "$gstatus" --argjson gresolved "$gresolved" --arg now "$(now_utc)" \
       '{l1Tx: $tx, l1Block: $l1b, finalizedAt: $fts, at: $at, targetBalanceBeforeWei: $before, targetBalanceAfterWei: $after, gameStatus: $gstatus, gameResolvedAt: $gresolved, recordedAt: $now}')" \
    --argjson t "$(jq -cn --argjson i "$its" --argjson g "$gts" --argjson p "$pts" --argjson r "$gresolved" --argjson f "$fts" \
       '{initiatedAt: $i, gameCreatedAt: $g, provenAt: $p, gameResolvedAt: $r, finalizedAt: $f,
         hours: {initiateToGame: (($g - $i) / 3600 * 100 | round / 100), gameToProven: (($p - $g) / 3600 * 100 | round / 100), provenToFinalized: (($f - $p) / 3600 * 100 | round / 100), gameCreatedToResolved: (($r - $g) / 3600 * 100 | round / 100), resolvedToFinalized: (($f - $r) / 3600 * 100 | round / 100), endToEnd: (($f - $i) / 3600 * 100 | round / 100)}}')"
  echo "finalized: L1 tx $tx in block $l1b at $(iso_of "$fts"); target $target now holds $(hex_to_eth "$after") ETH (was $(hex_to_eth "$before"))"
  echo "end to end: $(jq -r .timeline.hours.endToEnd "$RECORD") h from the L2 initiation; record $RECORD"
  ;;
*) usage ;;
esac
