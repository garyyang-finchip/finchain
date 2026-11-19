#!/usr/bin/env bash
# Look up the OP Contracts Manager (OPCM) address for the locked contracts release in the
# superchain-registry standard-versions file of the chain's L1: Sepolia (L1 chain id 11155111) or
# Ethereum mainnet (L1 chain id 1), from L1_CHAIN_ID of the chain's .env (CHAIN=<name> selects it;
# default Sepolia). Prints the address or exits non-zero.
#
# Usage: scripts/lookup-opcm.sh [op-contracts/vX.Y.Z]

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd curl awk
load_env "$FINCHAIN_ROOT/versions.lock"
[ ! -f "$FINCHAIN_ROOT/.env$ENV_SUFFIX" ] || load_env "$FINCHAIN_ROOT/.env$ENV_SUFFIX"

tag="${1:-${OP_CONTRACTS_TAG:?}}"
case "${L1_CHAIN_ID:-11155111}" in
  1) l1_name=mainnet ;;
  11155111) l1_name=sepolia ;;
  *) die "no standard-versions file is known for L1 chain id $L1_CHAIN_ID; set OPCM_ADDRESS in .env$ENV_SUFFIX" ;;
esac
url="https://raw.githubusercontent.com/ethereum-optimism/superchain-registry/main/validation/standard/standard-versions-$l1_name.toml"

toml="$(curl -fsSL "$url")" || die "could not fetch $url"

# Section headers look like: ["op-contracts/v7.0.0"]   (older files: [releases."op-contracts/v7.0.0"])
# The entry looks like:      op_contracts_manager = { version = "...", address = "0x..." }
addr="$(printf '%s\n' "$toml" | awk -v tag="$tag" '
  /^\[/ { inrel = (index($0, "\"" tag "\"") > 0); next }
  inrel && /^[[:space:]]*op_contracts_manager[[:space:]]*=/ {
    if (match($0, /0x[0-9a-fA-F]+/)) { print substr($0, RSTART, RLENGTH); exit }
  }')"

[ -n "$addr" ] || die "no op_contracts_manager entry found for $tag in $url (set OPCM_ADDRESS in .env manually)"
echo "$addr"
