#!/usr/bin/env bash
# Snapshot the live L1 configuration of Finchain at a fixed L1 block and compare the
# essentials with the deployment record. The on-chain state, not state.json, is the
# acceptance reference (docs/acceptance.md, docs/governance.md).
#
# Usage: scripts/verify-onchain.sh [L1_BLOCK]   (default: latest finalized block)
# Output: manifests/onchain-<block>.json

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq docker curl
load_standard_env

OUT="$FINCHAIN_ROOT/chain/out"
ADDR_FILE="$OUT/chain-record.json"
[ -f "$ADDR_FILE" ] || die "chain/out/chain-record.json missing; run: make export"

if [ -n "${1:-}" ]; then
  BLOCK="$1"
else
  BLOCK=$(( $(rpc "$L1_RPC_URL" eth_getBlockByNumber '["finalized",false]' | jq -r .result.number) ))
fi
log "reading L1 state at block $BLOCK via $L1_RPC_URL"

addr() { jq -r ".l1.$1 // empty" "$ADDR_FILE"; }
SYSCFG="$(addr SystemConfigProxy)"; PORTAL="$(addr OptimismPortalProxy)"; DGF="$(addr DisputeGameFactoryProxy)"; ASR="$(addr AnchorStateRegistryProxy)"

# call <address> <signature> [args...] -> value or "n/a"
call() {
  local a="$1" sig="$2"; shift 2
  [ -n "$a" ] || { echo "n/a"; return; }
  local v
  if v="$(cast call "$a" "$sig" "$@" --block "$BLOCK" --rpc-url "$L1_RPC_URL" 2>/dev/null)"; then
    echo "$v" | tr -d '\r' | head -1
  else
    echo "n/a"
  fi
}

respected="$(call "$PORTAL" 'respectedGameType()(uint32)')"
[ "$respected" = "n/a" ] && respected="$(call "$ASR" 'respectedGameType()(uint32)')"
if [ -z "$ASR" ] || [ "$ASR" = "n/a" ]; then ASR="$(call "$PORTAL" 'anchorStateRegistry()(address)')"; fi

game_block() { # <type>
  local t="$1" impl args hex prestate vm asr_a weth l2id proposer challenger src
  impl="$(call "$DGF" 'gameImpls(uint32)(address)' "$t")"
  if [ "$impl" = "n/a" ] || [ "$impl" = "0x0000000000000000000000000000000000000000" ]; then
    jq -n --arg t "$t" '{gameType: ($t|tonumber), implementation: "0x0000000000000000000000000000000000000000"}'
    return
  fi
  # Since op-contracts v7 the game implementation is shared by all chains and the per-chain
  # parameters live in the factory's game args, packed as
  #   absolutePrestate(32) | vm(20) | anchorStateRegistry(20) | delayedWETH(20) | l2ChainId(32)
  #   [| proposer(20) | challenger(20)]   (the last two for permissioned games)
  # Reading absolutePrestate() on the implementation itself returns zero on such releases.
  args="$(call "$DGF" 'gameArgs(uint32)(bytes)' "$t")"
  hex="${args#0x}"
  if [ "$args" != "n/a" ] && [ "${#hex}" -ge 248 ]; then
    src="factory gameArgs"
    prestate="0x${hex:0:64}"; vm="0x${hex:64:40}"; asr_a="0x${hex:104:40}"; weth="0x${hex:144:40}"
    l2id="${hex:184:64}"; l2id="$(printf '%s' "$l2id" | sed 's/^0*//')"; l2id=$(( 16#${l2id:-0} ))
    proposer=""; challenger=""
    if [ "${#hex}" -ge 328 ]; then proposer="0x${hex:248:40}"; challenger="0x${hex:288:40}"; fi
  else
    src="implementation getters"
    prestate="$(call "$impl" 'absolutePrestate()(bytes32)')"; vm="$(call "$impl" 'vm()(address)')"
    asr_a="$(call "$impl" 'anchorStateRegistry()(address)')"; weth="$(call "$impl" 'weth()(address)')"
    l2id="$(call "$impl" 'l2ChainId()(uint256)')"
    proposer="$(call "$impl" 'proposer()(address)')"; challenger="$(call "$impl" 'challenger()(address)')"
  fi
  jq -n --arg t "$t" --arg impl "$impl" --arg src "$src" \
    --arg bond "$(call "$DGF" 'initBonds(uint32)(uint256)' "$t")" \
    --arg prestate "$prestate" --arg vm "$vm" --arg asr "$asr_a" \
    --arg maxDepth "$(call "$impl" 'maxGameDepth()(uint256)')" \
    --arg splitDepth "$(call "$impl" 'splitDepth()(uint256)')" \
    --arg clockExt "$(call "$impl" 'clockExtension()(uint64)')" \
    --arg maxClock "$(call "$impl" 'maxClockDuration()(uint64)')" \
    --arg l2ChainId "$l2id" \
    --arg proposer "$proposer" --arg challenger "$challenger" \
    --arg weth "$weth" --arg wethDelay "$(call "$weth" 'delay()(uint256)')" \
    --arg version "$(call "$impl" 'version()(string)')" \
    '{gameType: ($t|tonumber), implementation: $impl, parametersFrom: $src, initBondWei: $bond,
      absolutePrestate: $prestate, vm: $vm, anchorStateRegistry: $asr,
      maxGameDepth: $maxDepth, splitDepth: $splitDepth, clockExtensionSeconds: $clockExt,
      maxClockDurationSeconds: $maxClock, l2ChainId: $l2ChainId,
      permissioned: {proposer: $proposer, challenger: $challenger},
      delayedWeth: {address: $weth, delaySeconds: $wethDelay}, version: $version}'
}

superchain="$(call "$PORTAL" 'superchainConfig()(address)')"
[ "$superchain" = "n/a" ] && superchain="$(call "$SYSCFG" 'superchainConfig()(address)')"

mkdir -p "$FINCHAIN_ROOT/manifests"
OUTFILE="$FINCHAIN_ROOT/manifests/onchain-${BLOCK}.json"

jq -n \
  --argjson block "$BLOCK" --arg rpc "$L1_RPC_URL" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg chainId "$CHAIN_ID" \
  --arg syscfg "$SYSCFG" --arg portal "$PORTAL" --arg dgf "$DGF" --arg asr "$ASR" --arg superchain "$superchain" \
  --arg owner "$(call "$SYSCFG" 'owner()(address)')" \
  --arg signer "$(call "$SYSCFG" 'unsafeBlockSigner()(address)')" \
  --arg batcherHash "$(call "$SYSCFG" 'batcherHash()(bytes32)')" \
  --arg syscfgVersion "$(call "$SYSCFG" 'version()(string)')" \
  --arg portalVersion "$(call "$PORTAL" 'version()(string)')" \
  --arg respected "$respected" \
  --arg proofMaturity "$(call "$PORTAL" 'proofMaturityDelaySeconds()(uint256)')" \
  --arg gameFinality "$(call "$PORTAL" 'disputeGameFinalityDelaySeconds()(uint256)')" \
  --arg portalGuardian "$(call "$PORTAL" 'guardian()(address)')" \
  --arg portalPaused "$(call "$PORTAL" 'paused()(bool)')" \
  --arg dgfOwner "$(call "$DGF" 'owner()(address)')" \
  --arg gameCount "$(call "$DGF" 'gameCount()(uint256)')" \
  --arg asrRespected "$(call "$ASR" 'respectedGameType()(uint32)')" \
  --arg asrRetirement "$(call "$ASR" 'retirementTimestamp()(uint64)')" \
  --arg scGuardian "$(call "$superchain" 'guardian()(address)')" \
  --arg scPaused "$(call "$superchain" 'paused()(bool)')" \
  --argjson game0 "$(game_block 0)" --argjson game1 "$(game_block 1)" \
  '{snapshot: {l1Block: $block, l1Rpc: $rpc, takenAt: $at, l2ChainId: ($chainId|tonumber)},
    systemConfig: {address: $syscfg, version: $syscfgVersion, owner: $owner, unsafeBlockSigner: $signer, batcherHash: $batcherHash},
    optimismPortal: {address: $portal, version: $portalVersion, respectedGameType: $respected,
                     proofMaturityDelaySeconds: $proofMaturity, disputeGameFinalityDelaySeconds: $gameFinality,
                     guardian: $portalGuardian, paused: $portalPaused},
    anchorStateRegistry: {address: $asr, respectedGameType: $asrRespected, retirementTimestamp: $asrRetirement},
    disputeGameFactory: {address: $dgf, owner: $dgfOwner, gameCount: $gameCount, games: [$game0, $game1]},
    superchainConfig: {address: $superchain, guardian: $scGuardian, paused: $scPaused,
                       note: "shared with other chains under standard-overrides; guardian and pause authority are not Finchain roles"}}' \
  > "$OUTFILE"

echo "written: $OUTFILE"
echo
echo "Checks:"
expected_signer="$(grep -E '^UNSAFE_BLOCK_SIGNER_ADDRESS=' "$FINCHAIN_ROOT/keys/addresses.env" 2>/dev/null | cut -d= -f2 || true)"
actual_signer="$(jq -r .systemConfig.unsafeBlockSigner "$OUTFILE")"
if [ -n "$expected_signer" ]; then
  if [ "$(echo "$expected_signer" | tr 'A-F' 'a-f')" = "$(echo "$actual_signer" | tr 'A-F' 'a-f')" ]; then
    echo "  unsafeBlockSigner matches keys/addresses.env"
  else
    echo "  MISMATCH: unsafeBlockSigner on chain $actual_signer vs expected $expected_signer"
  fi
fi
echo "  respected game type: $(jq -r .optimismPortal.respectedGameType "$OUTFILE") (set PROPOSER_GAME_TYPE in node-a/.env to this value)"
echo "  game impl for respected type: $(jq -r --arg t "$(jq -r .optimismPortal.respectedGameType "$OUTFILE")" '.disputeGameFactory.games[] | select((.gameType|tostring) == $t) | .implementation' "$OUTFILE")"
rt="$(jq -r .optimismPortal.respectedGameType "$OUTFILE")"
rg() { jq -r --arg t "$rt" ".disputeGameFactory.games[] | select((.gameType|tostring) == \$t) | $1" "$OUTFILE"; }
echo "  absolute prestate (respected type): $(rg .absolutePrestate)  [from $(rg .parametersFrom)]"
echo "  game l2ChainId: $(rg .l2ChainId) (must be $CHAIN_ID)"
for role in proposer challenger; do
  case "$role" in proposer) exp_key=PROPOSER_ADDRESS ;; *) exp_key=CHALLENGER_ADDRESS ;; esac
  exp="$(grep -E "^${exp_key}=" "$FINCHAIN_ROOT/keys/addresses.env" 2>/dev/null | cut -d= -f2 || true)"
  act="$(rg ".permissioned.$role")"
  if [ -n "$exp" ] && [ -n "$act" ]; then
    if [ "$(echo "$exp" | tr 'A-F' 'a-f')" = "$(echo "$act" | tr 'A-F' 'a-f')" ]; then
      echo "  $role matches keys/addresses.env"
    else
      echo "  MISMATCH: $role on chain $act vs expected $exp"
    fi
  fi
done
echo "  init bond (respected type, wei): $(jq -r --arg t "$(jq -r .optimismPortal.respectedGameType "$OUTFILE")" '.disputeGameFactory.games[] | select((.gameType|tostring) == $t) | .initBondWei' "$OUTFILE")"
echo "  DGF owner: $(jq -r .disputeGameFactory.owner "$OUTFILE")  (must be the owner address for set-init-bond)"
