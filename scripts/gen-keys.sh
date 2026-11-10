#!/usr/bin/env bash
# Generate the Finchain role keys and node secrets into keys/ (git-ignored).
#
# Roles with hot keys (one host each):
#   deployer             pays `op-deployer apply` (host A, can be drained afterwards)
#   unsafe_block_signer  sequencer p2p block signing (host A, op-node)
#   batcher              posts L2 data to L1 (host A)
#   proposer             posts output roots / creates dispute games (host A)
#   challenger           resolves and challenges dispute games (host B)
# Cold roles (external address, no key on any host): owner (l1ProxyAdminOwner,
#   l2ProxyAdminOwner, systemConfigOwner) and treasury (fee vault recipient).
#   They are taken from OWNER_ADDRESS / TREASURY_ADDRESS in .env. If empty, a cold key
#   is generated here with a warning (acceptable for the testnet only).
# Node secrets: Engine API JWT and p2p identity key per host.
#
# Nothing here is ever printed to stdout except addresses. Re-running refuses to
# overwrite existing files unless FORCE=1.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd docker jq openssl
load_standard_env

KEYS="$FINCHAIN_ROOT/keys"
mkdir -p "$KEYS"
chmod 700 "$KEYS"

new_key() {
  # cast wallet new --json -> [{"address":"0x..","private_key":"0x.."}]
  cast wallet new --json | jq -c '.[0]'
}

write_key() {
  local role="$1" f="$KEYS/$1.json"
  if [ -f "$f" ] && [ "${FORCE:-0}" != "1" ]; then
    log "keeping existing key for $role ($(jq -r .address "$f"))"
    return
  fi
  local k
  k="$(new_key)"
  umask 077
  printf '%s\n' "$k" > "$f"
  log "generated $role -> $(jq -r .address "$f")"
}

for role in deployer unsafe_block_signer batcher proposer challenger; do
  write_key "$role"
done

if [ -z "${OWNER_ADDRESS:-}" ]; then
  warn "OWNER_ADDRESS is empty: generating a cold owner key. Keep keys/owner.json offline; for mainnet use a Safe."
  write_key owner
  OWNER_ADDRESS="$(key_field owner address)"
fi
if [ -z "${TREASURY_ADDRESS:-}" ]; then
  log "TREASURY_ADDRESS is empty: fee vaults will pay to the owner address"
  TREASURY_ADDRESS="$OWNER_ADDRESS"
fi

# Node secrets (hex, 32 bytes each)
for host in a b; do
  for name in jwt p2p-node-key; do
    f="$KEYS/node-$host-$name.txt"
    if [ -f "$f" ] && [ "${FORCE:-0}" != "1" ]; then continue; fi
    umask 077
    openssl rand -hex 32 > "$f"
    log "generated node-$host $name"
  done
done

# Address summary used by render-intent.sh and the docs (safe to share).
{
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) - addresses only, no secrets"
  echo "DEPLOYER_ADDRESS=$(key_field deployer address)"
  echo "UNSAFE_BLOCK_SIGNER_ADDRESS=$(key_field unsafe_block_signer address)"
  echo "BATCHER_ADDRESS=$(key_field batcher address)"
  echo "PROPOSER_ADDRESS=$(key_field proposer address)"
  echo "CHALLENGER_ADDRESS=$(key_field challenger address)"
  echo "OWNER_ADDRESS=$OWNER_ADDRESS"
  echo "TREASURY_ADDRESS=$TREASURY_ADDRESS"
} > "$KEYS/addresses.env"
chmod 600 "$KEYS/addresses.env"

echo
echo "Role addresses (fund the hot roles on Sepolia per docs/funding-model.md):"
grep -v '^#' "$KEYS/addresses.env"
echo
echo "Next: make secrets-a (on host A) and make bundle-b (to move host B secrets once), then make intent."
