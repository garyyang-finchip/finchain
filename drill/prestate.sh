#!/usr/bin/env bash
# M4: a reproducible Cannon prestate of op-program with Finchain's chain configuration embedded (docs/acceptance.md
# M4, "prestate embeds Finchain configuration"; docs/proof-plan.md). The op-program client that runs inside the VM
# looks the L2 chain up by the chain id the dispute game contract hands it; a chain that is neither in the superchain
# registry nor embedded in the client cannot be proven. This script embeds Finchain:
#   1. clones the monorepo at TAG (shallow) into drill/work/,
#   2. places <chainId>-rollup.json and <chainId>-genesis-l2.json under op-program/chainconfig/configs/,
#   3. runs the repository's own reproducible Docker build (op-program/Dockerfile.repro, exactly the arguments of
#      `make reproducible-prestate` at TAG, target "current": the Cannon64 prestate for the MIPS64 VM in service),
#   4. keeps drill/out/prestates/<hash>.bin.gz and <hash>.json (the file names op-challenger expects at a prestates URL),
#   5. checks that the VM memory image carries the two files (their text is searched after decompression),
#   6. writes manifests/evidence/prestate-<chainId>-<date>.json.
# UPSTREAM_CHECK=1 builds once more without the two files and compares the hash with the published prestate of TAG:
# the same pipeline must reproduce the official image bit for bit before its Finchain variant is trusted.
#
# Usage: drill/prestate.sh [TAG] [ROLLUP] [GENESIS]
#   defaults: op-program/v1.9.0, <chain dir>/out/rollup.json and genesis.json (CHAIN=sepolia: chain/out; CHAIN=<name>: chain/<name>/out)
# Host: Linux with docker (BuildKit with buildx, for --output), git, jq, gzip; about 4 GB of memory and 20 GB of disk
# for the module cache and images; 30-60 minutes on two cores. No key, no chain access.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd docker git jq gzip

TAG="${1:-${TAG:-op-program/v1.9.0}}"
ROLLUP="${2:-${ROLLUP:-$CHAIN_DIR/out/rollup.json}}"
GENESIS="${3:-${GENESIS:-$CHAIN_DIR/out/genesis.json}}"
WORK="$FINCHAIN_ROOT/drill/work"; OUT="$FINCHAIN_ROOT/drill/out/prestates"; LOGS="$FINCHAIN_ROOT/drill/out/logs"
mkdir -p "$WORK" "$OUT" "$LOGS" "$FINCHAIN_ROOT/manifests/evidence"

# published prestates per op-program tag (superchain-registry validation/standard/standard-prestates.toml, type cannon64)
upstream_hash() {
  case "$1" in
    op-program/v1.9.0) echo 0x033c000916b4a88cfffeceddd6cf0f4be3897a89195941e5a7c3f8209b4dbb6e ;;
    op-program/v1.8.0) echo 0x03caa1871bb9fe7f9b11217c245c16e4ded33367df5b3ccb2c6d0a847a217d1b ;;
    *) echo "" ;;
  esac
}

docker buildx version >/dev/null 2>&1 || die "docker buildx is missing; the reproducible build exports its files through BuildKit (drill/README.md says how to install the plugin)"
[ -f "$ROLLUP" ] || die "rollup config not found: $ROLLUP"
[ -f "$GENESIS" ] || die "L2 genesis not found: $GENESIS"
chain_id="$(jq -r '.l2_chain_id' "$ROLLUP")"
[ "$(jq -r '.config.chainId' "$GENESIS")" = "$chain_id" ] || die "chain id differs between $ROLLUP ($chain_id) and $GENESIS"
l2_genesis_hash="$(jq -r '.genesis.l2.hash' "$ROLLUP")"; l1_genesis_hash="$(jq -r '.genesis.l1.hash' "$ROLLUP")"

repo="$WORK/optimism-$(printf '%s' "$TAG" | tr '/' '-')"
if [ ! -d "$repo/.git" ]; then
  log "cloning the monorepo at $TAG (shallow) into $repo"
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ethereum-optimism/optimism.git "$repo"
fi
commit="$(git -C "$repo" rev-parse HEAD)"
go_version="$(grep -oE 'GO_VERSION=[0-9][^ ]*' "$repo/op-program/Makefile" | head -1 | cut -d= -f2)"
[ -n "$go_version" ] || die "GO_VERSION not found in $repo/op-program/Makefile; the build arguments of this tag differ from what this script knows"
cfgdir="$repo/op-program/chainconfig/configs"; mkdir -p "$cfgdir"

# build <label> -> the prestate hash; the files land in $repo/op-program/bin
build() {
  local label="$1" logf
  logf="$LOGS/prestate-$label-$(date -u +%Y%m%dT%H%M%SZ).log"
  log "building $label (docker, Dockerfile.repro, target current, go $go_version) - this takes a while; log: $logf"
  ( cd "$repo/op-program" && rm -rf bin && mkdir -p bin && \
    docker build --build-arg "GO_VERSION=$go_version" --build-arg EXPORT_TARGET=current --output ./bin/ --progress plain -f Dockerfile.repro ../ ) >"$logf" 2>&1 \
    || die "build failed; the last lines of $logf: $(tail -n 5 "$logf" | tr '\n' ' ')"
  jq -r .pre "$repo/op-program/bin/prestate-proof-mt64.json"
}

upstream_result=null
if [ "${UPSTREAM_CHECK:-0}" = "1" ]; then
  rm -f "$cfgdir/${chain_id}-rollup.json" "$cfgdir/${chain_id}-genesis-l2.json"
  got="$(build upstream)" || exit 1; want="$(upstream_hash "$TAG")"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    log "upstream check: $TAG reproduces the published Cannon64 prestate $want"
    upstream_result="$(jq -cn --arg got "$got" --arg want "$want" '{built: $got, published: $want, result: "PASS"}')"
  else
    warn "upstream check: built $got, published ${want:-unknown for this tag}"
    upstream_result="$(jq -cn --arg got "$got" --arg want "$want" '{built: $got, published: ($want | select(. != "") // "unknown"), result: (if $want == "" then "UNKNOWN" else "FAIL" end)}')"
    [ -z "$want" ] || die "the pipeline does not reproduce the published prestate; nothing built with Finchain embedded is trustworthy until that is understood"
  fi
fi

cp "$ROLLUP" "$cfgdir/${chain_id}-rollup.json"
jq '.alloc = {}' "$GENESIS" > "$cfgdir/${chain_id}-genesis-l2.json"   # the client reads only .config; alloc is a required field and stays empty
hash="$(build "finchain-$chain_id")" || exit 1
[ -n "$hash" ] || die "no prestate hash in the build output"
cp "$repo/op-program/bin/prestate-mt64.bin.gz" "$OUT/$hash.bin.gz"
cp "$repo/op-program/bin/prestate-proof-mt64.json" "$OUT/$hash.json"
cp "$repo/op-program/bin/meta-mt64.json" "$OUT/$hash.meta-upstream.json" 2>/dev/null || true

# embedding check: the two files are embedded verbatim in the client binary, so their text is in the VM memory image
count_in_image() { local n; n="$(zcat "$OUT/$hash.bin.gz" | grep -a -o -F -- "$1" | wc -l || true)"; printf '%s' "${n:-0}" | tr -d ' '; }
n_l2="$(count_in_image "$l2_genesis_hash")"; n_l1="$(count_in_image "$l1_genesis_hash")"; n_cid="$(count_in_image "\"chainId\": $chain_id")"
embedded=FAIL; [ "$n_l2" -ge 1 ] && [ "$n_l1" -ge 1 ] && [ "$n_cid" -ge 1 ] && embedded=PASS

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ev="$FINCHAIN_ROOT/manifests/evidence/prestate-$chain_id-$stamp.json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$chain_id" --arg tag "$TAG" --arg commit "$commit" --arg go "$go_version" --arg hash "$hash" \
  --arg size "$(wc -c < "$OUT/$hash.bin.gz" | tr -d ' ')" --arg step "$(jq -r '.step // empty' "$OUT/$hash.json")" \
  --arg rsha "$(sha256_of "$cfgdir/${chain_id}-rollup.json")" --arg gsha "$(sha256_of "$cfgdir/${chain_id}-genesis-l2.json")" \
  --arg rsrc "$(sha256_of "$ROLLUP")" --arg gsrc "$(sha256_of "$GENESIS")" \
  --arg l2h "$l2_genesis_hash" --arg l1h "$l1_genesis_hash" --argjson n_l2 "$n_l2" --argjson n_l1 "$n_l1" --argjson n_cid "$n_cid" --arg emb "$embedded" \
  --argjson upstream "$upstream_result" --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)" --arg arch "$(uname -m)" '
  {schema: "finchain.prestate/1",
   acceptance: "M4: prestate embeds Finchain configuration - hash recorded, embedding verified (docs/acceptance.md M4; docs/proof-plan.md)",
   environment: "build", recordedAt: $at, chainId: $cid,
   source: {repository: "https://github.com/ethereum-optimism/optimism", tag: $tag, commit: $commit, dockerfile: "op-program/Dockerfile.repro", target: "current (Cannon64 for the MIPS64 VM)", goImage: ("golang:" + $go)},
   prestate: {hash: $hash, file: ("drill/out/prestates/" + $hash + ".bin.gz"), proof: ("drill/out/prestates/" + $hash + ".json"), bytesGz: ($size | tonumber), proofStep: $step},
   embedded: {rollup: {as: ("op-program/chainconfig/configs/" + ($cid|tostring) + "-rollup.json"), sha256: $rsha, sourceSha256: $rsrc},
              genesisL2: {as: ("op-program/chainconfig/configs/" + ($cid|tostring) + "-genesis-l2.json"), sha256: $gsha, sourceSha256: $gsrc, note: "alloc emptied before embedding; the client reads only config"}},
   embeddingCheck: {method: "the decompressed VM memory image is searched for the embedded text", l2GenesisHash: {value: $l2h, found: $n_l2}, l1GenesisHash: {value: $l1h, found: $n_l1}, chainIdField: {found: $n_cid}, result: $emb},
   upstreamReproduction: $upstream,
   builder: {docker: $docker, arch: $arch},
   use: "run-trace against the public chain with --run cannon/finchain/<hash> and the prestate served from a prestates URL; the isolated-devnet dispute drill; a new game implementation on the public chain (M5)"}' > "$ev"
echo "prestate $hash ($embedded embedding check: l2 genesis hash x$n_l2, l1 genesis hash x$n_l1, chainId field x$n_cid)"
echo "files: $OUT/$hash.bin.gz  $OUT/$hash.json"
echo "record: $ev"
[ "$embedded" = PASS ] || exit 3
