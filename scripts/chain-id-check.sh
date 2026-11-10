#!/usr/bin/env bash
# Chain id uniqueness check (docs/chain-id.md). Absence from the registry is necessary but
# not sufficient: 8338 is absent from ethereum-lists/chains yet has prior network use, which
# is why it was excluded. Finish with the manual checks printed at the end.
#
# Usage: scripts/chain-id-check.sh [chain-id]   (default CHAIN_ID from .env)

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd curl
[ -f "$FINCHAIN_ROOT/.env" ] && load_env "$FINCHAIN_ROOT/.env"
id="${1:-${CHAIN_ID:?}}"

url="https://raw.githubusercontent.com/ethereum-lists/chains/master/_data/chains/eip155-${id}.json"
code="$(curl -s -o /tmp/eip155-"$id".json -w '%{http_code}' "$url")"
case "$code" in
  200) echo "REGISTERED: eip155-$id exists in ethereum-lists/chains:"; cat /tmp/eip155-"$id".json; echo; exit 2 ;;
  404) echo "not in ethereum-lists/chains: $id (necessary, not sufficient)" ;;
  *)   echo "registry check inconclusive (HTTP $code); retry later" ;;
esac
rm -f /tmp/eip155-"$id".json

echo
echo "Manual checks before genesis (record the results in docs/chain-id.md):"
echo "  https://chainlist.org/chain/$id"
echo "  https://thirdweb.com/$id"
echo "  web search for \"chain id $id\" and \"chainId $id\""
echo "  no RPC should answer eth_chainId with 0x$(printf '%x' "$id") on any public endpoint list"
