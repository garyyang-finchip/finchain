#!/usr/bin/env bash
# K2b: kona-host with Finchain in its registry - the host side of the cannon-kona path (docs/proof-plan.md, K2).
#
# The kona-host shipped in the op-challenger image knows only the registry chains. Asked to serve a chain it does
# not know, op-challenger gives it --rollup-config-path, kona-host hands the client chain id 0, and the client falls
# back to the oracle-supplied rollup configuration instead of the one embedded in the prestate - not the path the
# game contract puts it on (drill/kona-host-wrapper.sh explains). So the host is built from the same monorepo
# checkout as the prestate, with the same KONA_CUSTOM_CONFIGS_DIR files (K1), natively for this machine's
# architecture, and `drill/kona-host-wrapper.sh` runs it with --l2-chain-id. The build is the image's own recipe
# (ops/docker/op-stack-go/Dockerfile: rust:<workspace version>, `cargo build --locked --bin kona-host`,
# target-cpu=generic) with the release profile instead of release-perf: the host is off-chain tooling, its
# optimisation level proves nothing.
#
# Usage: drill/kona-host-build.sh
#   KONA_TAG      monorepo tag (default kona-client/v1.9.0; the checkout drill/prestate.sh made)
#   CARGO_MODE    auto | native | docker (default auto: a native cargo at the workspace's Rust version, else rust:<version>)
#   BUILD_JOBS    cargo jobs (default: the machine's cores; the checkout's jobs = 1 is for the prestate build only)
# Output: drill/out/bin/kona-host-finchain-<tag slug> and manifests/evidence/kona-host-<chainId>-<date>.json.
# Host: git, jq, docker (the binary is checked inside the op-challenger image, the environment it runs in);
# 20-40 minutes and about 6 GB of disk for the first build on two cores.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd git jq docker
load_env "$FINCHAIN_ROOT/versions.lock"

ROLLUP="${ROLLUP:-$CHAIN_DIR/out/rollup.json}"; GENESIS="${GENESIS:-$CHAIN_DIR/out/genesis.json}"
KONA_TAG="${KONA_TAG:-kona-client/v1.9.0}"
[ -f "$ROLLUP" ] || die "rollup config not found: $ROLLUP"
chain_id="$(jq -r '.l2_chain_id' "$ROLLUP")"
WORK="$FINCHAIN_ROOT/drill/work"; LOGS="$FINCHAIN_ROOT/drill/out/logs"; BIN="$FINCHAIN_ROOT/drill/out/bin"
CONFIGS_DIR="${CONFIGS_DIR:-$WORK/kona-configs-$chain_id}"
mkdir -p "$WORK" "$LOGS" "$BIN" "$FINCHAIN_ROOT/manifests/evidence"
bash "$FINCHAIN_ROOT/drill/kona-configs.sh" "$ROLLUP" "$GENESIS" "$CONFIGS_DIR" >&2

tagslug="$(printf '%s' "$KONA_TAG" | tr '/' '-')"
repo="$WORK/optimism-$tagslug"
if [ ! -d "$repo/.git" ]; then
  log "cloning the monorepo at $KONA_TAG (shallow) into $repo"
  git clone --quiet --depth 1 --branch "$KONA_TAG" https://github.com/ethereum-optimism/optimism.git "$repo"
fi
commit="$(git -C "$repo" rev-parse HEAD)"
[ -f "$repo/rust/kona/bin/host/Cargo.toml" ] || die "no kona-host crate under $repo/rust/kona/bin/host; the layout of $KONA_TAG differs from what this script knows"
host_version="$(grep -m1 -E '^version' "$repo/rust/kona/bin/host/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
rust_version="$(grep -m1 -E '^channel' "$repo/rust/rust-toolchain.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
jobs="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 2)}"
out="$BIN/kona-host-finchain-$tagslug"
target="$WORK/kona-host-target-$tagslug"; mkdir -p "$target"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"; logf="$LOGS/kona-host-build-$stamp.log"

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
mode="${CARGO_MODE:-auto}"
if [ "$mode" = auto ]; then
  if command -v cargo >/dev/null 2>&1 && ver_ge "$(rustc --version | awk '{print $2}')" "$rust_version"; then mode=native; else mode=docker; fi
fi
log "building kona-host $host_version from $KONA_TAG ($commit) with chain $chain_id embedded: $mode cargo, $jobs jobs; log $logf"
case "$mode" in
  native)
    toolchain="$(rustc --version)"
    # the checkout's rust-toolchain.toml would make rustup fetch the pinned channel: build with the toolchain that is here
    active="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}' || true)"
    ( cd "$repo/rust" && export KONA_CUSTOM_CONFIGS=true KONA_CUSTOM_CONFIGS_DIR="$CONFIGS_DIR" CARGO_TARGET_DIR="$target" CARGO_BUILD_JOBS="$jobs" RUSTFLAGS="-C target-cpu=generic" \
        && { [ -z "$active" ] || export RUSTUP_TOOLCHAIN="$active"; } && cargo build --locked --release --bin kona-host ) >"$logf" 2>&1 \
      || die "build failed; the last lines of $logf: $(tail -n 8 "$logf" | tr '\n' ' ')"
    cp "$target/release/kona-host" "$out" ;;
  docker)
    image="rust:$rust_version"
    exact="$(docker run --rm "$image" rustc --version 2>/dev/null | awk '{print $2}')"; [ -n "$exact" ] || die "cannot run $image"
    toolchain="rustc $exact ($image)"
    docker run --rm -v "$repo:/repo:ro" -v "$CONFIGS_DIR:/configs:ro" -v "$target:/target" -v "$BIN:/out" \
      -v finchain-kona-check-cargo:/usr/local/cargo/registry \
      -e KONA_CUSTOM_CONFIGS=true -e KONA_CUSTOM_CONFIGS_DIR=/configs -e CARGO_TARGET_DIR=/target -e "CARGO_BUILD_JOBS=$jobs" \
      -e "RUSTUP_TOOLCHAIN=$exact" -e "RUSTFLAGS=-C target-cpu=generic" -e "OUT_NAME=$(basename "$out")" -e "OUT_OWNER=$(id -u):$(id -g)" \
      -w /repo/rust "$image" sh -c 'apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends clang pkg-config libssl-dev >/dev/null \
        && cargo build --locked --release --bin kona-host && cp /target/release/kona-host "/out/$OUT_NAME" && chown "$OUT_OWNER" "/out/$OUT_NAME"' \
      >"$logf" 2>&1 || die "build failed; the last lines of $logf: $(tail -n 8 "$logf" | tr '\n' ' ')" ;;
  *) die "CARGO_MODE must be auto, native or docker" ;;
esac
chmod +x "$out"
[ -s "$out" ] || die "no binary at $out"

# the binary must run where it will serve, inside the op-challenger image (this host's glibc may be older than the
# build image's, so a native run is tried only as a bonus)
IMAGE="${OP_CHALLENGER_IMAGE:?OP_CHALLENGER_IMAGE missing in versions.lock}"
runs_in="$IMAGE"
reported="$(docker run --rm -v "$out:/usr/local/bin/kona-host-finchain-bin:ro" --entrypoint /usr/local/bin/kona-host-finchain-bin "$IMAGE" --version 2>/dev/null | head -1 || true)"
case "$reported" in
  kona-host*) ;;
  *) reported="$("$out" --version 2>/dev/null | head -1 || true)"; runs_in="this host (the image could not be run here)"
     case "$reported" in kona-host*) warn "could not run the binary inside $IMAGE here; it ran natively" ;; *) die "the binary runs neither inside $IMAGE nor natively" ;; esac ;;
esac
# the merged registry is embedded as text (include_str!), so the chain's identifier and id are in the binary
identifier="$(jq -r '.[0].identifier' "$CONFIGS_DIR/chainList.json")"
n_ident="$(grep -a -o -F -- "\"identifier\": \"$identifier\"" "$out" | wc -l | tr -d ' ')"
n_cid="$(grep -a -o -F -- "\"l2_chain_id\": $chain_id" "$out" | wc -l | tr -d ' ')"
embedded=FAIL; [ "$n_ident" -ge 1 ] && [ "$n_cid" -ge 1 ] && embedded=PASS

ev="$FINCHAIN_ROOT/manifests/evidence/kona-host-$chain_id-$stamp.json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$chain_id" --arg tag "$KONA_TAG" --arg commit "$commit" --arg ver "$host_version" \
  --arg reported "$reported" --arg toolchain "$toolchain" --arg mode "$mode" --argjson jobs "$jobs" --arg image "$runs_in" \
  --arg bin "drill/out/bin/$(basename "$out")" --arg sha "$(sha256_of "$out")" --arg size "$(wc -c < "$out" | tr -d ' ')" --arg arch "$(uname -m)" \
  --arg ident "$identifier" --argjson n_ident "$n_ident" --argjson n_cid "$n_cid" --arg emb "$embedded" \
  --arg clsha "$(sha256_of "$CONFIGS_DIR/chainList.json")" --arg cfsha "$(sha256_of "$CONFIGS_DIR/configs.json")" --arg dssha "$(sha256_of "$CONFIGS_DIR/depsets.json")" '
  {schema: "finchain.kona-host/1",
   acceptance: "M4 K2: kona-host built with the chain in its registry, the host side of the cannon-kona path (docs/proof-plan.md K2; drill/kona-host-wrapper.sh)",
   environment: "build", recordedAt: $at, chainId: $cid,
   source: {repository: "https://github.com/ethereum-optimism/optimism", tag: $tag, commit: $commit, crate: ("kona-host " + $ver),
            recipe: "cargo build --locked --release --bin kona-host, RUSTFLAGS=-C target-cpu=generic, KONA_CUSTOM_CONFIGS_DIR of K1 (the image builds the same binary with --profile release-perf)",
            toolchain: $toolchain, cargo: $mode, jobs: $jobs},
   binary: {file: $bin, sha256: $sha, bytes: ($size | tonumber), arch: $arch, reportsVersion: $reported, runsIn: $image},
   embedded: {identifier: $ident, chainList: {sha256: $clsha}, configs: {sha256: $cfsha}, depsets: {sha256: $dssha},
              check: {method: "the binary is searched for the embedded registry text", identifierField: {found: $n_ident}, chainIdField: {found: $n_cid}, result: $emb}},
   use: "mounted into the op-challenger container by drill/run-trace.sh behind drill/kona-host-wrapper.sh (--l2-chain-id instead of --rollup-config-path); the same pair is what a cannon-kona challenger for this chain needs"}' > "$ev"
echo "kona-host $reported with chain $chain_id embedded ($embedded: identifier x$n_ident, chain id field x$n_cid): $out"
echo "sha256: $(sha256_of "$out")"
echo "record: $ev"
[ "$embedded" = PASS ] || exit 3
