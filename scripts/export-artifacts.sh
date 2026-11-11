#!/usr/bin/env bash
# Export the chain artifacts after `op-deployer apply`:
#   chain/out/genesis.json        L2 genesis (op-reth --chain)
#   chain/out/rollup.json         rollup config (op-node --rollup.config)
#   chain/out/l1-addresses.json   L1 contract addresses for this chain
#   chain/out/chain-record.json   genesis hash, rollup config hash, key addresses
# and fill DISPUTE_GAME_FACTORY into node-a/.env and node-b/.env when present.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq
load_standard_env

WORKDIR="$FINCHAIN_ROOT/chain/deployer"
OUT="$FINCHAIN_ROOT/chain/out"
BIN="$(op_deployer_bin)"
[ -x "$BIN" ] || die "op-deployer binary missing; run: make op-deployer"
[ -f "$WORKDIR/state.json" ] || die "state.json missing; run: make deploy-l1"
mkdir -p "$OUT"

"$BIN" inspect genesis --workdir "$WORKDIR" "$CHAIN_ID" > "$OUT/genesis.json"
"$BIN" inspect rollup  --workdir "$WORKDIR" "$CHAIN_ID" > "$OUT/rollup.json"
log "genesis.json and rollup.json written"

# L1 addresses: prefer `inspect l1` when the release has it, else read state.json.
if "$BIN" inspect l1 --workdir "$WORKDIR" "$CHAIN_ID" > "$OUT/l1-addresses.raw.json" 2>/dev/null; then
  mv "$OUT/l1-addresses.raw.json" "$OUT/l1-addresses.json"
else
  rm -f "$OUT/l1-addresses.raw.json"
  jq '.opChainDeployments[0]' "$WORKDIR/state.json" > "$OUT/l1-addresses.json"
fi

# Field names differ between releases (camelCase with "Address" suffix vs PascalCase).
pick() { # pick <jq expression alternatives...>
  local e
  for e in "$@"; do
    v="$(jq -r "$e // empty" "$OUT/l1-addresses.json" 2>/dev/null || true)"
    if [ -n "$v" ] && [ "$v" != "null" ]; then echo "$v"; return 0; fi
  done
  return 1
}
dgf="$(pick '.disputeGameFactoryProxyAddress' '.DisputeGameFactoryProxy' '.opChainContracts.disputeGameFactoryProxy' '.. | .disputeGameFactoryProxyAddress? // empty')" || warn "DisputeGameFactory address not found automatically; read it from chain/out/l1-addresses.json"
portal="$(pick '.optimismPortalProxyAddress' '.OptimismPortalProxy' '.opChainContracts.optimismPortalProxy')" || true
syscfg="$(pick '.systemConfigProxyAddress' '.SystemConfigProxy' '.opChainContracts.systemConfigProxy')" || true
asr="$(pick '.anchorStateRegistryProxyAddress' '.AnchorStateRegistryProxy' '.opChainContracts.anchorStateRegistryProxy')" || true
bridge="$(pick '.l1StandardBridgeProxyAddress' '.L1StandardBridgeProxy' '.opChainContracts.l1StandardBridgeProxy')" || true
pdg="$(pick '.permissionedDisputeGameAddress' '.PermissionedDisputeGameImpl' '.PermissionedDisputeGame' '.opChainContracts.permissionedDisputeGame')" || true

genesis_hash="$(jq -r '.genesis.l2.hash // empty' "$OUT/rollup.json")"
l1_anchor="$(jq -r '.genesis.l1.hash // empty' "$OUT/rollup.json")"
l1_anchor_num="$(jq -r '.genesis.l1.number // empty' "$OUT/rollup.json")"
rollup_hash="$(jq -cS . "$OUT/rollup.json" | (sha256sum 2>/dev/null || shasum -a 256) | awk '{print $1}')"

jq -n \
  --arg chainId "$CHAIN_ID" --arg name "${CHAIN_NAME:-}" \
  --arg genesisHash "$genesis_hash" --arg l1AnchorHash "$l1_anchor" --arg l1AnchorNumber "$l1_anchor_num" \
  --arg rollupSha256 "$rollup_hash" --arg dgf "${dgf:-}" --arg portal "${portal:-}" \
  --arg syscfg "${syscfg:-}" --arg asr "${asr:-}" --arg bridge "${bridge:-}" --arg pdg "${pdg:-}" \
  '{chainId: ($chainId|tonumber), name: $name,
    l2GenesisHash: $genesisHash, l1Anchor: {hash: $l1AnchorHash, number: ($l1AnchorNumber|tonumber? // null)},
    rollupConfigSha256: $rollupSha256,
    l1: {DisputeGameFactoryProxy: $dgf, OptimismPortalProxy: $portal, SystemConfigProxy: $syscfg,
         AnchorStateRegistryProxy: $asr, L1StandardBridgeProxy: $bridge, PermissionedDisputeGame: $pdg}}' \
  > "$OUT/chain-record.json"

# Fill DISPUTE_GAME_FACTORY into the host env files that exist on this machine.
if [ -n "${dgf:-}" ]; then
  for f in "$FINCHAIN_ROOT/node-a/.env" "$FINCHAIN_ROOT/node-b/.env"; do
    [ -f "$f" ] || continue
    if grep -q '^DISPUTE_GAME_FACTORY=' "$f"; then
      sedi -E "s|^DISPUTE_GAME_FACTORY=.*|DISPUTE_GAME_FACTORY=${dgf}|" "$f"
    else
      echo "DISPUTE_GAME_FACTORY=${dgf}" >> "$f"
    fi
    log "DISPUTE_GAME_FACTORY set in $(basename "$(dirname "$f")")/.env"
  done
fi

echo
cat "$OUT/chain-record.json"
echo
echo "Commit chain/deployer/intent.toml, chain/deployer/state.json and chain/out/* as the chain record."
echo "Next: make verify-onchain (reads the live L1 configuration at a fixed block)."
