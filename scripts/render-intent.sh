#!/usr/bin/env bash
# Create chain/deployer/intent.toml with op-deployer init and apply the Finchain overrides.
#
# Steps:
#   1. op-deployer init (standard-overrides, L1 = Sepolia, L2 = CHAIN_ID)
#   2. set fundDevAccounts = false
#   3. set the seven chain roles and the four fee vault recipients from keys/addresses.env
#   4. fill opcmAddress when init leaves it blank (lookup-opcm.sh or OPCM_ADDRESS)
#   5. optionally append [chains.deployOverrides] from DEPLOY_OVERRIDES_JSON
#   6. check that the contracts locator matches OP_CONTRACTS_TAG in versions.lock
#
# The result is reviewed by hand before `make deploy-l1`. intent.toml holds addresses
# only and is committed after deployment as part of the chain record.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq
load_standard_env
load_env "$FINCHAIN_ROOT/keys/addresses.env"

WORKDIR="$FINCHAIN_ROOT/chain/deployer"
INTENT="$WORKDIR/intent.toml"
BIN="$(op_deployer_bin)"
[ -x "$BIN" ] || die "op-deployer binary missing; run: make op-deployer"
mkdir -p "$WORKDIR"

if [ -f "$INTENT" ] && [ "${FORCE:-0}" != "1" ]; then
  log "intent.toml already exists; re-applying overrides only (FORCE=1 to re-init)"
else
  rm -f "$INTENT" "$WORKDIR/state.json"
  log "op-deployer init: L1 ${L1_CHAIN_ID} -> L2 ${CHAIN_ID} (standard-overrides)"
  "$BIN" init \
    --l1-chain-id "${L1_CHAIN_ID:?}" \
    --l2-chain-ids "${CHAIN_ID:?}" \
    --workdir "$WORKDIR" \
    --intent-type standard-overrides
fi

[ -f "$INTENT" ] || die "init did not produce $INTENT"

# set_kv KEY VALUE  - replaces the first `KEY = ...` line (any indentation) with KEY = VALUE
set_kv() {
  local key="$1" value="$2"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$INTENT"; then
    sedi -E "s|^([[:space:]]*)${key}[[:space:]]*=.*|\1${key} = ${value}|" "$INTENT"
  else
    warn "key '${key}' not present in intent.toml for this op-deployer version; add it by hand if required"
  fi
}
quote() { printf '"%s"' "$1"; }

set_kv fundDevAccounts false
set_kv useInterop false

set_kv l1ProxyAdminOwner      "$(quote "$OWNER_ADDRESS")"
set_kv l2ProxyAdminOwner      "$(quote "$OWNER_ADDRESS")"
set_kv systemConfigOwner      "$(quote "$OWNER_ADDRESS")"
set_kv unsafeBlockSigner      "$(quote "$UNSAFE_BLOCK_SIGNER_ADDRESS")"
set_kv batcher                "$(quote "$BATCHER_ADDRESS")"
set_kv proposer               "$(quote "$PROPOSER_ADDRESS")"
set_kv challenger             "$(quote "$CHALLENGER_ADDRESS")"

set_kv baseFeeVaultRecipient      "$(quote "$TREASURY_ADDRESS")"
set_kv l1FeeVaultRecipient        "$(quote "$TREASURY_ADDRESS")"
set_kv sequencerFeeVaultRecipient "$(quote "$TREASURY_ADDRESS")"
set_kv operatorFeeVaultRecipient  "$(quote "$TREASURY_ADDRESS")"

# OPCM address
current_opcm="$(grep -E '^[[:space:]]*opcmAddress[[:space:]]*=' "$INTENT" | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)"
if [ -z "$current_opcm" ] || [ "$current_opcm" = "0x0000000000000000000000000000000000000000" ]; then
  if [ -n "${OPCM_ADDRESS:-}" ]; then
    set_kv opcmAddress "$(quote "$OPCM_ADDRESS")"
  else
    looked_up="$(bash "$FINCHAIN_ROOT/scripts/lookup-opcm.sh" "$OP_CONTRACTS_TAG")" || die "set OPCM_ADDRESS in .env"
    set_kv opcmAddress "$(quote "$looked_up")"
    log "opcmAddress filled from superchain-registry: $looked_up"
  fi
else
  log "opcmAddress from init kept: $current_opcm (confirm it belongs to $OP_CONTRACTS_TAG)"
fi

# Optional deploy-config overrides (JSON object -> TOML table appended to the single chain)
if [ -n "${DEPLOY_OVERRIDES_JSON:-}" ]; then
  if grep -q '^\[chains.deployOverrides\]' "$INTENT"; then
    warn "intent already has [chains.deployOverrides]; not appending again"
  else
    {
      echo
      echo "[chains.deployOverrides]"
      printf '%s' "$DEPLOY_OVERRIDES_JSON" | jq -r 'to_entries[] | "\(.key) = \(.value | if type == "string" then "\"" + . + "\"" else tostring end)"'
    } >> "$INTENT"
    warn "appended deployOverrides; key names must match op-deployer ${OP_DEPLOYER_VERSION} (see docs/versions.md)"
  fi
fi

# Locator check
if grep -q "tag://${OP_CONTRACTS_TAG}" "$INTENT"; then
  log "contracts locator matches ${OP_CONTRACTS_TAG}"
else
  warn "l1ContractsLocator in intent.toml does not reference ${OP_CONTRACTS_TAG}. Either the op-deployer release targets another contracts version (fix versions.lock) or the locator must be set by hand."
fi

echo
echo "intent.toml written: $INTENT"
echo "Review the roles and vault recipients:"
grep -E '^[[:space:]]*(configType|l1ChainID|fundDevAccounts|opcmAddress|l1ContractsLocator|l2ContractsLocator|id|.*Recipient|l1ProxyAdminOwner|l2ProxyAdminOwner|systemConfigOwner|unsafeBlockSigner|batcher|proposer|challenger)[[:space:]]*=' "$INTENT"
