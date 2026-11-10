#!/usr/bin/env bash
# Testnet cost control: set the DisputeGameFactory initial bond for a game type.
# Only the DGF owner (the owner role) can call setInitBond(uint32,uint256).
# This changes ONLY the bond paid when a game is created. Bonds for later moves inside a
# dispute come from getRequiredBond(position) in the game contract and are not affected
# (docs/funding-model.md).
#
# Usage: scripts/set-init-bond.sh <game-type> <bond-wei>
#   With OWNER_PRIVATE_KEY in the environment the transaction is sent from here;
#   otherwise the calldata is printed for signing in a wallet (e.g. via the explorer).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq docker
load_standard_env

TYPE="${1:?game type (uint32)}"
BOND="${2:?bond in wei}"
DGF="$(jq -r '.l1.DisputeGameFactoryProxy // empty' "$FINCHAIN_ROOT/chain/out/chain-record.json")"
[ -n "$DGF" ] || die "DisputeGameFactoryProxy missing in chain/out/chain-record.json"

current="$(cast call "$DGF" 'initBonds(uint32)(uint256)' "$TYPE" --rpc-url "$L1_RPC_URL")"
owner="$(cast call "$DGF" 'owner()(address)' --rpc-url "$L1_RPC_URL")"
echo "DisputeGameFactory: $DGF"
echo "owner:              $owner"
echo "initBonds($TYPE):   $current  ->  $BOND"

calldata="$(cast calldata 'setInitBond(uint32,uint256)' "$TYPE" "$BOND")"
if [ -n "${OWNER_PRIVATE_KEY:-}" ]; then
  cast send "$DGF" "$calldata" --private-key "$OWNER_PRIVATE_KEY" --rpc-url "$L1_RPC_URL" --json | jq -c '{transactionHash, status}'
  echo "now: $(cast call "$DGF" 'initBonds(uint32)(uint256)' "$TYPE" --rpc-url "$L1_RPC_URL")"
else
  echo
  echo "No OWNER_PRIVATE_KEY in the environment. Send this from the owner address:"
  echo "  to:       $DGF"
  echo "  value:    0"
  echo "  calldata: $calldata"
fi
