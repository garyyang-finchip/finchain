#!/usr/bin/env bash
# M4 K2: a reproducible Cannon prestate of the fault-proof client with Finchain's chain configuration embedded
# (docs/acceptance.md M4; docs/proof-plan.md K2). The client that runs inside the VM looks the L2 chain up by the
# chain id the dispute game contract hands it; a chain that is neither in its registry nor embedded in it cannot be
# proven, and a configuration handed in through the preimage oracle is not a proof of anything. This script embeds
# Finchain with the repository's own reproducible build and no other change:
#
# PROVER=kona (default): kona-client, the client the cannon-kona game type (8, CANNON_KONA) runs.
#   1. drill/kona-configs.sh writes the chain in the registry format kona-client embeds (K1),
#   2. the monorepo is cloned at TAG (default kona-client/v1.9.0, shallow) into drill/work/,
#   3. `just reproducible-prestate-kona` runs with KONA_CUSTOM_CONFIGS_DIR pointing at those files - the recipe the
#      release prestates are built with (rust/kona/docker/fpvm-prestates/cannon-repro.dockerfile, Cannon state
#      multithreaded64-5 for the MIPS64 VM in service),
#   4. the artifacts are kept as drill/out/prestates/<hash>.bin.gz and <hash>.json (the names op-challenger expects
#      at a prestates URL), the VM memory image is searched for the embedded text, and
#      manifests/evidence/prestate-<chainId>-<date>.json is written.
#   UPSTREAM_CHECK=1 first runs the same recipe without the custom files and compares the hash with the published
#   kona prestate of TAG (superchain-registry standard-prestates, type cannon64-kona): the pipeline must reproduce
#   the official image bit for bit before its Finchain variant is trusted.
#   KONA_BUILD_JOBS (default 1) is written as `jobs` under [build] in rust/.cargo/config.toml of the checkout, which the
#   Dockerfile copies into the build image: it bounds memory on a small host and does not change the output (the
#   upstream check is the proof). 0 leaves the file alone.
#
# PROVER=op-program: the Go client, kept for the record of the first attempt (docs/proof-plan.md: it cannot follow the
#   current Sepolia L1 and was removed upstream). TAG default op-program/v1.9.0; the files land under
#   op-program/chainconfig/configs/ and the build is op-program/Dockerfile.repro, target current.
#
# Usage: drill/prestate.sh [TAG] [ROLLUP] [GENESIS]
#   defaults: TAG by PROVER, <chain dir>/out/rollup.json and genesis.json (CHAIN=sepolia: chain/out; CHAIN=<name>: chain/<name>/out)
# Host: Linux with docker (BuildKit with buildx), git, jq, gzip, just (PROVER=kona); 8 GB of memory with swap, 40 GB of
# disk for the caches and images; hours for the first kona build on two cores, minutes for a rebuild from the caches.
# No key, no chain access.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd docker git jq gzip

PROVER="${PROVER:-kona}"
case "$PROVER" in
  kona) default_tag=kona-client/v1.9.0 ;;
  op-program) default_tag=op-program/v1.9.0 ;;
  *) die "PROVER must be kona or op-program" ;;
esac
TAG="${1:-${TAG:-$default_tag}}"
ROLLUP="${2:-${ROLLUP:-$CHAIN_DIR/out/rollup.json}}"
GENESIS="${3:-${GENESIS:-$CHAIN_DIR/out/genesis.json}}"
WORK="$FINCHAIN_ROOT/drill/work"; OUT="$FINCHAIN_ROOT/drill/out/prestates"; LOGS="$FINCHAIN_ROOT/drill/out/logs"
mkdir -p "$WORK" "$OUT" "$LOGS" "$FINCHAIN_ROOT/manifests/evidence"

# published prestates per tag (superchain-registry validation/standard/standard-prestates.toml)
upstream_hash() {
  case "$1" in
    kona-client/v1.9.0) echo 0x03f872c2161174453f8841a1ebd1d22bca443a5045d53e662dd835f24e1b6b0b ;;   # cannon64-kona "1.9.0"
    op-program/v1.9.0) echo 0x033c000916b4a88cfffeceddd6cf0f4be3897a89195941e5a7c3f8209b4dbb6e ;;    # cannon64 "1.9.0"
    op-program/v1.8.0) echo 0x03caa1871bb9fe7f9b11217c245c16e4ded33367df5b3ccb2c6d0a847a217d1b ;;    # cannon64 "1.8.0"
    *) echo "" ;;
  esac
}
upstream_hash_interop() {
  case "$1" in
    kona-client/v1.9.0) echo 0x03e5a54835d39c1d83b198314473e1f111c3539c04f65c3e8a9b8ccebe3737c9 ;;   # cannon64-kona-interop "1.9.0"
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
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ev="$FINCHAIN_ROOT/manifests/evidence/prestate-$chain_id-$stamp.json"

# count_in_image <file.bin.gz> <text> -> occurrences of the text in the decompressed VM memory image
count_in_image() { local n; n="$(zcat "$1" | grep -a -o -F -- "$2" | wc -l || true)"; printf '%s' "${n:-0}" | tr -d ' '; }

###############################################################################################################
if [ "$PROVER" = kona ]; then
  require_cmd just
  cfgdir="$WORK/kona-configs-$chain_id"
  "$FINCHAIN_ROOT/drill/kona-configs.sh" "$ROLLUP" "$GENESIS" "$cfgdir" >&2
  identifier="$(jq -r '.[0].identifier' "$cfgdir/chainList.json")"
  artifacts="$repo/rust/kona/prestate-artifacts-cannon"; artifacts_int="$repo/rust/kona/prestate-artifacts-cannon-interop"
  [ -f "$repo/rust/kona/docker/fpvm-prestates/cannon-repro.dockerfile" ] || die "no cannon-repro.dockerfile in $repo; the layout of $TAG differs from what this script knows"

  # parallelism of the cargo build inside the image: rust/.cargo/config.toml is copied into the build stage
  jobs="${KONA_BUILD_JOBS:-1}"
  cargo_cfg="$repo/rust/.cargo/config.toml"
  if [ "$jobs" != 0 ]; then
    if grep -qE '^jobs *= *[0-9]+' "$cargo_cfg"; then sedi -E "s/^jobs *= *[0-9]+/jobs = $jobs/" "$cargo_cfg"
    else printf '\n[build]\njobs = %s\n' "$jobs" >> "$cargo_cfg"; fi
  fi
  jobs_effective="$(grep -oE '^jobs *= *[0-9]+' "$cargo_cfg" | grep -oE '[0-9]+$' || echo default)"

  # build <label> [configs dir] -> the kona-client prestate hash; artifacts land in rust/kona/prestate-artifacts-*
  build() {
    local label="$1" cfg="${2:-}" logf
    logf="$LOGS/prestate-kona-$label-$(date -u +%Y%m%dT%H%M%SZ).log"
    log "building $label (just reproducible-prestate-kona, cargo jobs $jobs_effective) - hours on a small host for the first build; log: $logf"
    ( cd "$repo" && if [ -n "$cfg" ]; then export KONA_CUSTOM_CONFIGS_DIR="$cfg"; else unset KONA_CUSTOM_CONFIGS_DIR; fi && \
      just reproducible-prestate-kona ) >"$logf" 2>&1 \
      || die "build failed; the last lines of $logf: $(tail -n 5 "$logf" | tr '\n' ' ')"
    [ -s "$artifacts/prestate-proof.json" ] || die "the build left no $artifacts/prestate-proof.json"
    jq -r .pre "$artifacts/prestate-proof.json"
  }

  upstream_result=null
  if [ "${UPSTREAM_CHECK:-0}" = "1" ]; then
    got="$(build upstream)" || exit 1; want="$(upstream_hash "$TAG")"
    got_int="$(jq -r '.pre // empty' "$artifacts_int/prestate-proof.json" 2>/dev/null || true)"; want_int="$(upstream_hash_interop "$TAG")"
    int_result=UNKNOWN; [ -z "$want_int" ] || { [ "$got_int" = "$want_int" ] && int_result=PASS || int_result=FAIL; }
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
      log "upstream check: $TAG reproduces the published cannon64-kona prestate $want (interop variant: $int_result)"
      upstream_result="$(jq -cn --arg got "$got" --arg want "$want" --arg gi "$got_int" --arg wi "$want_int" --arg ir "$int_result" \
        '{built: $got, published: $want, result: "PASS", interop: {built: $gi, published: ($wi | select(. != "") // "unknown"), result: $ir}}')"
    else
      warn "upstream check: built $got, published ${want:-unknown for this tag}"
      upstream_result="$(jq -cn --arg got "$got" --arg want "$want" --arg gi "$got_int" '{built: $got, published: ($want | select(. != "") // "unknown"), result: (if $want == "" then "UNKNOWN" else "FAIL" end), interop: {built: $gi}}')"
      [ -z "$want" ] || die "the pipeline does not reproduce the published prestate; nothing built with Finchain embedded is trustworthy until that is understood"
    fi
  fi

  hash="$(build "finchain-$chain_id" "$cfgdir")" || exit 1
  [ -n "$hash" ] && [ "$hash" != null ] || die "no prestate hash in the build output"
  hash_int="$(jq -r '.pre // empty' "$artifacts_int/prestate-proof.json" 2>/dev/null || true)"
  cp "$artifacts/prestate.bin.gz" "$OUT/$hash.bin.gz"
  cp "$artifacts/prestate-proof.json" "$OUT/$hash.json"
  cp "$artifacts/meta.json" "$OUT/$hash.meta.json" 2>/dev/null || true

  # embedding check: the merged registry files are embedded as text (include_str!), so their content is in the image
  n_l2="$(count_in_image "$OUT/$hash.bin.gz" "$l2_genesis_hash")"; n_l1="$(count_in_image "$OUT/$hash.bin.gz" "$l1_genesis_hash")"
  n_cid="$(count_in_image "$OUT/$hash.bin.gz" "\"l2_chain_id\": $chain_id")"; n_ident="$(count_in_image "$OUT/$hash.bin.gz" "\"identifier\": \"$identifier\"")"
  embedded=FAIL; [ "$n_l2" -ge 1 ] && [ "$n_l1" -ge 1 ] && [ "$n_cid" -ge 1 ] && embedded=PASS

  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$chain_id" --arg tag "$TAG" --arg commit "$commit" --arg jobs "$jobs_effective" \
    --arg hash "$hash" --arg hash_int "$hash_int" --arg size "$(wc -c < "$OUT/$hash.bin.gz" | tr -d ' ')" --arg step "$(jq -r '.step // empty' "$OUT/$hash.json")" \
    --arg ident "$identifier" --arg cfgdir "$cfgdir" \
    --arg clsha "$(sha256_of "$cfgdir/chainList.json")" --arg cfsha "$(sha256_of "$cfgdir/configs.json")" --arg dssha "$(sha256_of "$cfgdir/depsets.json")" \
    --arg rsrc "$(sha256_of "$ROLLUP")" --arg gsrc "$(sha256_of "$GENESIS")" \
    --arg l2h "$l2_genesis_hash" --arg l1h "$l1_genesis_hash" --argjson n_l2 "$n_l2" --argjson n_l1 "$n_l1" --argjson n_cid "$n_cid" --argjson n_ident "$n_ident" --arg emb "$embedded" \
    --argjson upstream "$upstream_result" --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)" \
    --arg just "$(just --version 2>/dev/null | awk '{print $2}')" --arg arch "$(uname -m)" '
    {schema: "finchain.prestate/2",
     acceptance: "M4 K2: kona-client prestate embeds Finchain configuration - hash recorded, embedding verified (docs/acceptance.md M4; docs/proof-plan.md K2)",
     environment: "build", recordedAt: $at, chainId: $cid, prover: "kona",
     source: {repository: "https://github.com/ethereum-optimism/optimism", tag: $tag, commit: $commit,
              recipe: "just reproducible-prestate-kona", dockerfile: "rust/kona/docker/fpvm-prestates/cannon-repro.dockerfile",
              stateType: "multithreaded64-5 (Cannon64 for the MIPS64 VM)", cargoBuildJobs: $jobs},
     prestate: {variant: "kona-client (prestate-artifacts-cannon)", hash: $hash, file: ("drill/out/prestates/" + $hash + ".bin.gz"),
                proof: ("drill/out/prestates/" + $hash + ".json"), bytesGz: ($size | tonumber), proofStep: $step},
     interopVariant: {name: "kona-client-int (prestate-artifacts-cannon-interop)", hash: $hash_int, note: "built by the same recipe; not used by Finchain"},
     embedded: {method: "KONA_CUSTOM_CONFIGS_DIR merged into the kona-registry crate at build time (drill/kona-configs.sh, K1)",
                identifier: $ident, directory: $cfgdir,
                chainList: {sha256: $clsha}, configs: {sha256: $cfsha}, depsets: {sha256: $dssha},
                rollupSha256: $rsrc, genesisSha256: $gsrc},
     embeddingCheck: {method: "the decompressed VM memory image is searched for the embedded registry text",
                      l2GenesisHash: {value: $l2h, found: $n_l2}, l1GenesisHash: {value: $l1h, found: $n_l1},
                      chainIdField: {found: $n_cid}, identifierField: {found: $n_ident}, result: $emb},
     upstreamReproduction: $upstream,
     builder: {docker: $docker, just: $just, arch: $arch},
     use: "run-trace with --trace-type cannon-kona and --run cannon-kona/finchain/file:<prestate> (K2); the CANNON_KONA (8) game implementation of the devnet drill (K3); the public chain only after K4 and a separate decision"}' > "$ev"

###############################################################################################################
else
  warn "PROVER=op-program: this client cannot follow the current Sepolia L1 (docs/proof-plan.md); the build is kept for the record only"
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

  n_l2="$(count_in_image "$OUT/$hash.bin.gz" "$l2_genesis_hash")"; n_l1="$(count_in_image "$OUT/$hash.bin.gz" "$l1_genesis_hash")"; n_cid="$(count_in_image "$OUT/$hash.bin.gz" "\"chainId\": $chain_id")"
  embedded=FAIL; [ "$n_l2" -ge 1 ] && [ "$n_l1" -ge 1 ] && [ "$n_cid" -ge 1 ] && embedded=PASS

  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$chain_id" --arg tag "$TAG" --arg commit "$commit" --arg go "$go_version" --arg hash "$hash" \
    --arg size "$(wc -c < "$OUT/$hash.bin.gz" | tr -d ' ')" --arg step "$(jq -r '.step // empty' "$OUT/$hash.json")" \
    --arg rsha "$(sha256_of "$cfgdir/${chain_id}-rollup.json")" --arg gsha "$(sha256_of "$cfgdir/${chain_id}-genesis-l2.json")" \
    --arg rsrc "$(sha256_of "$ROLLUP")" --arg gsrc "$(sha256_of "$GENESIS")" \
    --arg l2h "$l2_genesis_hash" --arg l1h "$l1_genesis_hash" --argjson n_l2 "$n_l2" --argjson n_l1 "$n_l1" --argjson n_cid "$n_cid" --arg emb "$embedded" \
    --argjson upstream "$upstream_result" --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)" --arg arch "$(uname -m)" '
    {schema: "finchain.prestate/1",
     acceptance: "M4: op-program prestate embeds Finchain configuration - hash recorded, embedding verified (superseded by the kona route, docs/proof-plan.md)",
     environment: "build", recordedAt: $at, chainId: $cid, prover: "op-program",
     source: {repository: "https://github.com/ethereum-optimism/optimism", tag: $tag, commit: $commit, dockerfile: "op-program/Dockerfile.repro", target: "current (Cannon64 for the MIPS64 VM)", goImage: ("golang:" + $go)},
     prestate: {hash: $hash, file: ("drill/out/prestates/" + $hash + ".bin.gz"), proof: ("drill/out/prestates/" + $hash + ".json"), bytesGz: ($size | tonumber), proofStep: $step},
     embedded: {rollup: {as: ("op-program/chainconfig/configs/" + ($cid|tostring) + "-rollup.json"), sha256: $rsha, sourceSha256: $rsrc},
                genesisL2: {as: ("op-program/chainconfig/configs/" + ($cid|tostring) + "-genesis-l2.json"), sha256: $gsha, sourceSha256: $gsrc, note: "alloc emptied before embedding; the client reads only config"}},
     embeddingCheck: {method: "the decompressed VM memory image is searched for the embedded text", l2GenesisHash: {value: $l2h, found: $n_l2}, l1GenesisHash: {value: $l1h, found: $n_l1}, chainIdField: {found: $n_cid}, result: $emb},
     upstreamReproduction: $upstream,
     builder: {docker: $docker, arch: $arch},
     use: "record of the op-program route only; see docs/proof-plan.md"}' > "$ev"
fi

echo "prestate $hash ($PROVER, $embedded embedding check: l2 genesis hash x$n_l2, l1 genesis hash x$n_l1, chain id field x$n_cid)"
echo "files: $OUT/$hash.bin.gz  $OUT/$hash.json"
echo "record: $ev"
[ "$embedded" = PASS ] || exit 3
