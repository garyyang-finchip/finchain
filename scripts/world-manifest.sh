#!/usr/bin/env bash
# The manifest's covenantWorld section from a FOGA address book (docs/world.md, section 5.3; docs/acceptance.md M3-C).
# Input: the address book the released FOGA wrote (`foga world deploy ... --out <file>`, schema foga.world/1), kept
# in this repository as chain/world/<name>.json. The chain is read at the completing block (the block of the last
# transaction the World needed: deployments, wiring, the flows bootstrap) and every World contract's raw code hash
# is recorded; the bundle of the same FOGA package, when given, adds the build identity, the role and the
# repository and commit of each covenant; a MATCH report of scripts/verify-world.sh, when given, fills verifiedAt.
# The identity root comes from chain/out/erc8004.json when its IdentityRegistry is the one the address book names.
#
# Usage: scripts/world-manifest.sh <address-book.json> [l2-rpc=https://rpc.finchain.one] [bundle.json] [verify-report.json]
#   out: manifests/covenant-world-<name>.json (the section; merged into the manifest's covenantWorld by hand)
# Reads the chain only (curl + cast keccak); needs no FOGA checkout and no key.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl
load_env "$FINCHAIN_ROOT/versions.lock"
[ -n "${CAST_BIN:-}" ] || require_cmd docker

BOOK="${1:-}"
[ -n "$BOOK" ] || die "usage: scripts/world-manifest.sh <address-book.json> [l2-rpc] [bundle.json] [verify-report.json] (make world-manifest BOOK=chain/world/<name>.json ...)"
L2_RPC="${2:-https://rpc.finchain.one}"
BUNDLE="${3:-}"
REPORT="${4:-}"
[ -f "$BOOK" ] || die "not found: $BOOK"
[ "$(jq -r .schema "$BOOK")" = "foga.world/1" ] || die "$BOOK is not a FOGA address book (schema foga.world/1)"
if [ -n "$BUNDLE" ]; then [ -f "$BUNDLE" ] || die "bundle not found: $BUNDLE"; fi
if [ -n "$REPORT" ]; then [ -f "$REPORT" ] || die "verify report not found: $REPORT"; fi

name="$(jq -r .name "$BOOK")"
chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
[ "$((chain_hex))" = "$(jq -r .chainId "$BOOK")" ] || die "L2 RPC $L2_RPC reports chain id $((chain_hex)), the address book says $(jq -r .chainId "$BOOK")"
if [ -n "$BUNDLE" ]; then
  bh="$(jq -r .hash "$BUNDLE")"; wh="$(jq -r .bundleHash "$BOOK")"
  [ "$bh" = "$wh" ] || die "bundle hash $bh is not the address book's $wh: use the bundle of the package that deployed the World"
fi
echo "address book $BOOK: world $(jq -r .worldId "$BOOK") on chain $((chain_hex)) via $L2_RPC"

log "transactions: receipts of the wiring and flows transactions"
# Every transaction hash the World needed beyond the deployments: steps marked wired, the wiring table, the flows.
receipts="{}"
while read -r tx; do
  [ -n "$tx" ] || continue
  r="$(rpc "$L2_RPC" eth_getTransactionReceipt "[\"$tx\"]" | jq -c '.result // empty')"
  [ -n "$r" ] || die "receipt not found for $tx"
  [ "$(printf '%s' "$r" | jq -r .status)" = "0x1" ] || die "transaction $tx did not succeed"
  receipts="$(printf '%s' "$receipts" | jq -c --arg tx "$tx" --argjson r "$r" '. + {($tx): {block: ($r.blockNumber | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d)), to: ($r.to // "" | ascii_downcase)}}')"
done < <(jq -r '[ (.steps[]? | select(.status == "wired") | .txHash), (.wiring[]? | objects | .txHashes[]?), (.flows.paradigms[]? | .txHash), (.flows.market.txHash) ] | map(select(. != null)) | unique[]' "$BOOK")
echo "  $(printf '%s' "$receipts" | jq 'length') transactions read"

completion=$(jq -r --argjson r "$receipts" '[ (.contracts[]? | .block // 0), ($r[] | .block) ] | max' "$BOOK")
[ "$completion" != "0" ] && [ "$completion" != "null" ] || die "no block numbers in the address book"
completion_hash="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$(printf '0x%x' "$completion")\",false]" | jq -r '.result.hash // empty')"
[ -n "$completion_hash" ] || die "block $completion not found on $L2_RPC"
completion_hex="$(printf '0x%x' "$completion")"
echo "  completing block $completion $completion_hash"

log "code: keccak256 of every World contract's runtime code at block $completion"
codes="{}"; n=0
while IFS=$'\t' read -r cname addr; do
  [ -n "$cname" ] || continue
  code="$(rpc "$L2_RPC" eth_getCode "[\"$addr\",\"$completion_hex\"]" | jq -r '.result // "0x"')"
  [ "$code" != "0x" ] || die "no code at $addr ($cname) at block $completion"
  h="$(cast keccak "$code")"
  codes="$(printf '%s' "$codes" | jq -c --arg k "$cname" --arg v "$h" '. + {($k): $v}')"
  n=$((n + 1))
done < <(jq -r '.contracts | to_entries[] | select(.key != "identity8004") | [.key, .value.address] | @tsv' "$BOOK")
echo "  $n contracts hashed"

# The identity root: chain/out/erc8004.json when it is the registry the address book names.
root="null"
rec="$FINCHAIN_ROOT/chain/out/erc8004.json"
book_id="$(jq -r '.identity8004.address | ascii_downcase' "$BOOK")"
if [ -f "$rec" ] && [ "$(jq -r '.contracts.IdentityRegistry.proxy | ascii_downcase' "$rec")" = "$book_id" ]; then
  root="$(jq -c '
    def entry($n; $c): [
      { name: $n, address: $c.proxy, implementation: $c.implementation, codeHash: $c.runtimeCodeKeccak.proxy, deploymentTx: $c.transactions.proxy.tx,
        initializationTxs: ([$c.transactions.upgradeToAndCall.tx, $c.transactions.transferOwnership.tx] | map(select(. != null))) },
      { name: ($n + ".implementation"), address: $c.implementation, codeHash: $c.runtimeCodeKeccak.implementation, deploymentTx: $c.transactions.implementation.tx } ];
    { erc: 8004, repository: .upstream.repository, commit: .upstream.commit, record: "chain/out/erc8004.json", owner: .owner,
      contracts: ((entry("IdentityRegistry"; .contracts.IdentityRegistry)) + (if .contracts.ReputationRegistry then entry("ReputationRegistry"; .contracts.ReputationRegistry) else [] end)) }' "$rec")"
  echo "  identity root: chain/out/erc8004.json (IdentityRegistry $book_id)"
else
  idcode="$(rpc "$L2_RPC" eth_getCode "[\"$book_id\",\"$completion_hex\"]" | jq -r '.result // "0x"')"
  [ "$idcode" != "0x" ] || die "the identity registry $book_id has no code at block $completion"
  root="$(jq -cn --arg a "$book_id" --arg h "$(cast keccak "$idcode")" '{ erc: 8004, record: "none: the address book names a registry chain/out/erc8004.json does not describe", contracts: [{ name: "IdentityRegistry", address: $a, codeHash: $h }] }')"
  echo "  identity root: $book_id (not the registry of chain/out/erc8004.json; code hash recorded, provenance unknown)"
fi

bundle_json="null"; [ -n "$BUNDLE" ] && bundle_json="$(jq -c '{hash, sources, contracts: (.contracts | map_values({runtimeIdentity, role, erc, repo}))}' "$BUNDLE")"
report_json="null"; [ -n "$REPORT" ] && report_json="$(jq -c --arg path "${REPORT#"$FINCHAIN_ROOT/"}" '{result, block, blockHash, checkedAt, path: $path}' "$REPORT")"
if [ -n "$REPORT" ] && [ "$(printf '%s' "$report_json" | jq -r .result)" != "MATCH" ]; then die "the verify report $REPORT is not a MATCH; verifiedAt stays unset"; fi

mkdir -p "$FINCHAIN_ROOT/manifests"
out="$FINCHAIN_ROOT/manifests/covenant-world-$name.json"
jq -n --slurpfile book "$BOOK" --argjson receipts "$receipts" --argjson codes "$codes" --argjson root "$root" --argjson bundle "$bundle_json" --argjson report "$report_json" \
  --argjson completion "$completion" --arg completionHash "$completion_hash" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rpc "$L2_RPC" --arg bookPath "chain/world/$name.json" '
  $book[0] as $b
  | ($b.contracts | to_entries | map(select(.key != "identity8004"))) as $cs
  | ($cs | map({key: (.value.address | ascii_downcase), value: .key}) | from_entries) as $byAddr
  | ($b.identity8004.address | ascii_downcase) as $idAddr
  | ($receipts | to_entries | map(select(.value.to != "")) | group_by(.value.to) | map({key: .[0].value.to, value: (map(.key))}) | from_entries) as $inits
  | ($cs | map(
      .key as $name | .value as $c
      | ($name | split("/")[0] | tonumber) as $erc
      | (($c.args // []) | map(select(type == "string" and test("^0x[0-9a-fA-F]{40}$")) | ascii_downcase) | map(if . == $idAddr then "identity8004" else $byAddr[.] end) | map(select(. != null)) | unique) as $deps
      | (if $bundle != null then ($bundle.contracts[$c.bundleKey] // {}) else {} end) as $art
      | { name: $name, erc: $erc, module: $erc, address: $c.address, codeHash: $codes[$name], deploymentTx: $c.txHash,
          initializationTxs: ($inits[$c.address | ascii_downcase] // []), dependsOn: $deps,
          runtimeIdentity: $art.runtimeIdentity, role: $art.role, bundleKey: $c.bundleKey, deploymentBlock: $c.block,
          status: (if $c.txHash then "deployed" else "attached" end) }
      | with_entries(select(.value != null))
    )) as $contracts
  | ($contracts | map({key: .name, value: .erc}) | from_entries) as $ercOf
  | ($contracts | group_by(.erc) | map(
      .[0].erc as $erc
      | (if $bundle != null then ([$bundle.sources[] | select(.erc == $erc)] | .[0] // {}) else {} end) as $src
      | ([ .[] | .dependsOn[] ] | map(if . == "identity8004" then 8004 else $ercOf[.] end) | map(select(. != null and . != $erc)) | unique) as $deps
      | (if any(.[]; (.bundleKey // "") | startswith("foga:")) then ($deps + ["foga"]) else $deps end) as $deps2
      | { erc: $erc, name: $src.repo, repository: $src.url, commit: $src.commit, contracts: (map(.name)), dependsOn: $deps2, standalone: ($deps2 | length == 0) }
      | with_entries(select(.value != null))
    )) as $modules
  | (if $bundle != null then [$bundle.sources[] | select(.erc | type == "number") | { erc, name: .repo, repository: .url, commit }] else [] end) as $ercs
  | { worldId: $b.worldId, deployer: $b.deployer, bundleHash: $b.bundleHash,
      addressBook: { uri: $bookPath, worldId: $b.worldId },
      identityRoot: $root, ercs: $ercs, modules: $modules,
      completionBlock: { number: $completion, hash: $completionHash },
      contracts: $contracts }
  | (if $report != null then . + { verifiedAt: { number: $report.block, hash: $report.blockHash, at: $report.checkedAt, report: $report.path } } else . end)
  | . + { generatedAt: $at, rpc: $rpc,
          note: "Generated by scripts/world-manifest.sh from the FOGA address book; codeHash is keccak256 of the raw runtime code read at completionBlock; runtimeIdentity (when present) is the bundle build identity; dependsOn lists the World contracts (and the identity root) whose addresses appear in the recorded constructor arguments, initializationTxs the wiring transactions sent to the contract; verifiedAt is filled from a MATCH report of scripts/verify-world.sh at a finalized block" }' > "$out"

echo
echo "section: $out"
echo "  contracts $(jq '.contracts | length' "$out"), modules $(jq '.modules | length' "$out") ($(jq -r '[.modules[] | select(.standalone)] | length' "$out") standalone), completion block $completion"
jq -r '.modules[] | "  \(.erc)  \(.contracts | length) contracts  dependsOn \(.dependsOn | map(tostring) | join(",") | if . == "" then "-" else . end)"' "$out"
if [ -z "$REPORT" ]; then echo "verifiedAt is not set: run scripts/verify-world.sh $out <rpc> finalized on host B and pass its MATCH report as the fourth argument."; fi
