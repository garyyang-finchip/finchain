#!/usr/bin/env bash
# Rebuild the ERC-8004 contracts from chain/contracts/erc8004/standard-input.json with solc 0.8.24 and
# compare every contract's creation and runtime bytecode hash with chain/contracts/erc8004/build.json.
# Proves the committed build is reproducible from the pinned sources; sends nothing.
#
# Usage: scripts/build-8004.sh
#   env: SOLC_BIN=/path/to/solc-0.8.24 uses a native binary; otherwise the ethereum/solc:0.8.24 image
#        runs through Docker (the standard JSON input carries every source, so no network is needed).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq
load_env "$FINCHAIN_ROOT/versions.lock"
DIR="$FINCHAIN_ROOT/chain/contracts/erc8004"
[ -f "$DIR/standard-input.json" ] && [ -f "$DIR/build.json" ] || die "chain/contracts/erc8004/ is incomplete"
[ -n "${CAST_BIN:-}" ] || require_cmd docker

solc_json() {
  if [ -n "${SOLC_BIN:-}" ]; then "$SOLC_BIN" --standard-json; else docker run --rm -i ethereum/solc:0.8.24 --standard-json; fi
}
out="$(solc_json < "$DIR/standard-input.json")" || die "solc failed"
errors="$(printf '%s' "$out" | jq '[.errors[]? | select(.severity == "error")] | length')"
[ "$errors" = "0" ] || { printf '%s' "$out" | jq -r '.errors[] | select(.severity == "error") | .formattedMessage' >&2; die "compilation errors"; }

failed=0
for name in HardhatMinimalUUPS IdentityRegistryUpgradeable ReputationRegistryUpgradeable ERC1967Proxy; do
  src="$(jq -r ".contracts.$name.source" "$DIR/build.json")"
  creation="0x$(printf '%s' "$out" | jq -r --arg s "$src" --arg n "$name" '.contracts[$s][$n].evm.bytecode.object')"
  runtime="0x$(printf '%s' "$out" | jq -r --arg s "$src" --arg n "$name" '.contracts[$s][$n].evm.deployedBytecode.object')"
  ck="$(cast keccak "$creation")"; rk="$(cast keccak "$runtime")"
  eck="$(jq -r ".contracts.$name.creationBytecodeKeccak" "$DIR/build.json")"; erk="$(jq -r ".contracts.$name.runtimeBytecodeKeccak" "$DIR/build.json")"
  if [ "$ck" = "$eck" ] && [ "$rk" = "$erk" ]; then echo "ok   $name  runtime $rk"; else echo "FAIL $name  creation $ck (recorded $eck)  runtime $rk (recorded $erk)"; failed=1; fi
done
if [ "$failed" = "0" ]; then
  echo "RESULT: REPRODUCED (solc $(printf '%s' "$out" | jq -r '.contracts["contracts/IdentityRegistryUpgradeable.sol"].IdentityRegistryUpgradeable.metadata | fromjson | .compiler.version'))"
else
  die "RESULT: DIFFERS from build.json"
fi
