#!/usr/bin/env bash
# K1 validation: the custom chain configuration is merged into the kona-client registry the same way the prestate
# build merges it, and the rollup configuration the client derives from it is compared with op-node's rollup.json
# (docs/proof-plan.md, K1). No VM is built here; this is the check that the configuration is right before the long
# build. It:
#   1. regenerates the three registry files with drill/kona-configs.sh (deterministic from rollup.json and genesis.json),
#   2. clones the monorepo at KONA_TAG (shallow) into drill/work/ when it is not there yet (the prestate build reuses it),
#   3. builds the drill/kona-check probe against that checkout's kona-registry crate - once with the stock registry
#      (the chain must be absent) and once with KONA_CUSTOM_CONFIGS pointing at the generated files (present);
#      the crate's build script performs the merge and its validation, the probe prints the embedded configuration,
#   4. compares the derived rollup configuration with rollup.json field by field,
#   5. writes manifests/evidence/kona-configs-<chainId>-<date>.json with the generated files, both probe results
#      and the comparison.
# cargo: a native cargo whose rustc is at least the workspace's rust-version is used when present; otherwise the
# official rust:<version> image (CARGO_MODE=native|docker forces one). The checkout is never modified.
#
# Usage: drill/kona-check.sh [ROLLUP] [GENESIS]
#   KONA_TAG      monorepo tag (default kona-client/v1.9.0)
#   CONFIGS_DIR   where the registry files go (default drill/work/kona-configs-<chainId>)
# Host: git, jq; cargo >= rust-version or docker; a few GB of disk for the dependency build; no key, no chain access.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd git jq

ROLLUP="${1:-${ROLLUP:-$CHAIN_DIR/out/rollup.json}}"
GENESIS="${2:-${GENESIS:-$CHAIN_DIR/out/genesis.json}}"
KONA_TAG="${KONA_TAG:-kona-client/v1.9.0}"
[ -f "$ROLLUP" ] || die "rollup config not found: $ROLLUP"
chain_id="$(jq -r '.l2_chain_id' "$ROLLUP")"
WORK="$FINCHAIN_ROOT/drill/work"; LOGS="$FINCHAIN_ROOT/drill/out/logs"
CONFIGS_DIR="${CONFIGS_DIR:-$WORK/kona-configs-$chain_id}"
mkdir -p "$WORK" "$LOGS" "$FINCHAIN_ROOT/manifests/evidence"

bash "$FINCHAIN_ROOT/drill/kona-configs.sh" "$ROLLUP" "$GENESIS" "$CONFIGS_DIR"   # through bash: the web upload drops the executable bit

repo="$WORK/optimism-$(printf '%s' "$KONA_TAG" | tr '/' '-')"
if [ ! -d "$repo/.git" ]; then
  log "cloning the monorepo at $KONA_TAG (shallow) into $repo"
  git clone --quiet --depth 1 --branch "$KONA_TAG" https://github.com/ethereum-optimism/optimism.git "$repo"
fi
commit="$(git -C "$repo" rev-parse HEAD)"
registry_rel="rust/kona/crates/protocol/registry"
[ -f "$repo/$registry_rel/Cargo.toml" ] || die "no kona-registry crate at $repo/$registry_rel; the layout of $KONA_TAG differs from what this script knows"
registry_version="$(grep -m1 -E '^version' "$repo/$registry_rel/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
rust_version="$(grep -m1 -E '^channel' "$repo/rust/rust-toolchain.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$rust_version" ] || die "no channel in $repo/rust/rust-toolchain.toml"

# the probe crate: a copy outside the checkout, with the registry path filled in and the checkout's lock file
probe="$WORK/kona-check-$(printf '%s' "$KONA_TAG" | tr '/' '-')"
mkdir -p "$probe/src"
cp "$FINCHAIN_ROOT/drill/kona-check/src/main.rs" "$probe/src/main.rs"
[ -f "$probe/Cargo.lock" ] || cp "$repo/rust/Cargo.lock" "$probe/Cargo.lock"   # the checkout's versions, pruned to the probe's graph by cargo

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # ver_ge A B: A >= B
mode="${CARGO_MODE:-auto}"
if [ "$mode" = auto ]; then
  if command -v cargo >/dev/null 2>&1 && ver_ge "$(rustc --version | awk '{print $2}')" "$rust_version"; then mode=native; else mode=docker; fi
fi
case "$mode" in
  native) registry_path="$repo/$registry_rel"; configs_path="$CONFIGS_DIR"; toolchain="$(rustc --version)" ;;
  docker) require_cmd docker; registry_path="/repo/$registry_rel"; configs_path="/configs"; toolchain="rust:$rust_version (docker)" ;;
  *) die "CARGO_MODE must be auto, native or docker" ;;
esac
sed "s#@KONA_REGISTRY@#$registry_path#" "$FINCHAIN_ROOT/drill/kona-check/Cargo.toml.in" > "$probe/Cargo.toml"

# probe <label> <custom:0|1> -> prints the probe's JSON; the compile log goes to drill/out/logs
probe_run() {
  local label="$1" custom="$2" logf out rc=0
  logf="$LOGS/kona-check-$label-$(date -u +%Y%m%dT%H%M%SZ).log"; out="$probe/out-$label.json"
  log "building the probe ($label, $mode cargo) - the first build compiles the registry's dependencies; log: $logf"
  if [ "$mode" = native ]; then
    ( cd "$probe" && if [ "$custom" = 1 ]; then export KONA_CUSTOM_CONFIGS=true KONA_CUSTOM_CONFIGS_DIR="$configs_path"; fi && \
      cargo run --quiet -- "$chain_id" ) >"$out" 2>"$logf" || rc=$?
  else
    local envs=()
    [ "$custom" = 1 ] && envs=(-e KONA_CUSTOM_CONFIGS=true -e "KONA_CUSTOM_CONFIGS_DIR=$configs_path")
    docker run --rm "${envs[@]}" -v "$repo:/repo:ro" -v "$probe:/probe" -v "$CONFIGS_DIR:/configs:ro" \
      -v finchain-kona-check-cargo:/usr/local/cargo/registry -w /probe "rust:$rust_version" \
      cargo run --quiet -- "$chain_id" >"$out" 2>"$logf" || rc=$?
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then die "probe build failed (exit $rc); the last lines of $logf: $(tail -n 8 "$logf" | tr '\n' ' ')"; fi
  jq -e . "$out" >/dev/null 2>&1 || die "the probe printed no JSON ($label); see $logf"
  cat "$out"
}

stock="$(probe_run stock 0)"
[ "$(jq -r .embedded <<<"$stock")" = false ] || die "the stock registry of $KONA_TAG already contains chain $chain_id; the custom configuration would conflict"
custom="$(probe_run custom 1)"
[ "$(jq -r .embedded <<<"$custom")" = true ] || die "chain $chain_id is not in the registry after the merge; see the probe log"

# the derived rollup config against rollup.json: every field op-node's file states
derived="$(jq -c .rollupConfig <<<"$custom")"
checks="$(jq -n --slurpfile r "$ROLLUP" --argjson d "$derived" '
  def low: if type == "string" then ascii_downcase else . end;
  def chk(name; want; got): {check: name, expected: want, derived: got, result: (if (want|low) == (got|low) then "PASS" else "FAIL" end)};
  $r[0] as $r |
  [ chk("l2_chain_id"; $r.l2_chain_id; $d.l2_chain_id),
    chk("l1_chain_id"; $r.l1_chain_id; $d.l1_chain_id),
    chk("block_time"; $r.block_time; $d.block_time),
    chk("max_sequencer_drift"; $r.max_sequencer_drift; $d.max_sequencer_drift),
    chk("seq_window_size"; $r.seq_window_size; $d.seq_window_size),
    chk("channel_timeout"; $r.channel_timeout; $d.channel_timeout),
    chk("batch_inbox_address"; $r.batch_inbox_address; $d.batch_inbox_address),
    chk("deposit_contract_address"; $r.deposit_contract_address; $d.deposit_contract_address),
    chk("l1_system_config_address"; $r.l1_system_config_address; $d.l1_system_config_address),
    chk("chain_op_config"; $r.chain_op_config; $d.chain_op_config),
    chk("genesis.l1.hash"; $r.genesis.l1.hash; $d.genesis.l1.hash),
    chk("genesis.l1.number"; $r.genesis.l1.number; $d.genesis.l1.number),
    chk("genesis.l2.hash"; $r.genesis.l2.hash; $d.genesis.l2.hash),
    chk("genesis.l2.number"; $r.genesis.l2.number; $d.genesis.l2.number),
    chk("genesis.l2_time"; $r.genesis.l2_time; $d.genesis.l2_time),
    chk("genesis.system_config.batcherAddr"; $r.genesis.system_config.batcherAddr; $d.genesis.system_config.batcherAddr),
    chk("genesis.system_config.overhead"; $r.genesis.system_config.overhead; $d.genesis.system_config.overhead),
    chk("genesis.system_config.scalar"; $r.genesis.system_config.scalar; $d.genesis.system_config.scalar),
    chk("genesis.system_config.gasLimit"; $r.genesis.system_config.gasLimit; $d.genesis.system_config.gasLimit) ]
  + [ $r | to_entries[] | select((.key | endswith("_time")) and .key != "block_time" and .value != null) | chk(.key; .value; $d[.key]) ]')"
fails="$(jq '[.[] | select(.result != "PASS")] | length' <<<"$checks")"
result=PASS; [ "$fails" -eq 0 ] || result=FAIL

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ev="$FINCHAIN_ROOT/manifests/evidence/kona-configs-$chain_id-$stamp.json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$chain_id" --arg tag "$KONA_TAG" --arg commit "$commit" \
  --arg crate "$registry_version" --arg toolchain "$toolchain" --arg mode "$mode" \
  --arg rsrc "$(sha256_of "$ROLLUP")" --arg gsrc "$(sha256_of "$GENESIS")" \
  --slurpfile cl "$CONFIGS_DIR/chainList.json" --slurpfile cf "$CONFIGS_DIR/configs.json" --slurpfile ds "$CONFIGS_DIR/depsets.json" \
  --arg clsha "$(sha256_of "$CONFIGS_DIR/chainList.json")" --arg cfsha "$(sha256_of "$CONFIGS_DIR/configs.json")" --arg dssha "$(sha256_of "$CONFIGS_DIR/depsets.json")" \
  --argjson stock "$stock" --argjson custom "$custom" --argjson checks "$checks" --arg result "$result" '
  {schema: "finchain.kona-configs/1",
   acceptance: "M4 K1: Finchain configuration converted to the kona-client registry format, merged by the registry build script and found equal to rollup.json (docs/acceptance.md M4; docs/proof-plan.md K1)",
   environment: "build", recordedAt: $at, chainId: $cid,
   source: {repository: "https://github.com/ethereum-optimism/optimism", tag: $tag, commit: $commit, crate: ("kona-registry " + $crate), toolchain: $toolchain, cargo: $mode,
            rollupSha256: $rsrc, genesisSha256: $gsrc},
   files: {chainList: {sha256: $clsha, content: $cl[0]}, configs: {sha256: $cfsha, content: $cf[0]}, depsets: {sha256: $dssha, content: $ds[0]}},
   stockRegistry: {embedded: $stock.embedded, registryChains: $stock.registryChains},
   mergedRegistry: {embedded: $custom.embedded, registryChains: $custom.registryChains, chain: $custom.chain, rollupConfig: $custom.rollupConfig, dependencySet: $custom.dependencySet},
   comparison: {method: "the rollup configuration the merged registry derives for the chain id, field by field against op-node rollup.json", checks: $checks, failures: ($checks | map(select(.result != "PASS")) | length), result: $result}}' > "$ev"

echo "stock registry: $(jq -r .registryChains <<<"$stock") chains, $chain_id absent; merged: $(jq -r .registryChains <<<"$custom") chains, $chain_id present"
jq -r '.[] | "  \(.result)  \(.check): \(.derived|tostring)"' <<<"$checks"
echo "comparison: $result ($fails failures)"
echo "record: $ev"
[ "$result" = PASS ] || exit 3
