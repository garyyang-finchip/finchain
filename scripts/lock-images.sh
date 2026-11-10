#!/usr/bin/env bash
# Freeze versions.lock: resolve every *_IMAGE tag to an immutable digest
# (repository:tag@sha256:...) and record the op-deployer binary checksum.
# Run only after `make preflight` has passed on both hosts and the version set has been
# verified together (docs/versions.md). Commit the result.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd docker jq
LOCK="$FINCHAIN_ROOT/versions.lock"
load_env "$LOCK"

resolve() { # image ref -> ref@digest
  local ref="$1" base digest
  base="${ref%%@*}"
  digest="$(docker buildx imagetools inspect "$base" --format '{{json .Manifest.Digest}}' | tr -d '"')"
  [ -n "$digest" ] || die "could not resolve digest for $base"
  echo "${base}@${digest}"
}

for var in OP_NODE_IMAGE OP_RETH_IMAGE OP_BATCHER_IMAGE OP_PROPOSER_IMAGE OP_CHALLENGER_IMAGE FOUNDRY_IMAGE CADDY_IMAGE; do
  cur="${!var}"
  new="$(resolve "$cur")"
  sedi -E "s|^${var}=.*|${var}=${new}|" "$LOCK"
  log "$var -> $new"
done

bin="$(op_deployer_bin)"
if [ -x "$bin" ]; then
  if command -v sha256sum >/dev/null 2>&1; then sum="$(sha256sum "$bin" | awk '{print $1}')"; else sum="$(shasum -a 256 "$bin" | awk '{print $1}')"; fi
  sedi -E "s|^OP_DEPLOYER_SHA256=.*|OP_DEPLOYER_SHA256=${sum}|" "$LOCK"
  log "OP_DEPLOYER_SHA256 -> $sum ($(host_os)/$(host_arch))"
else
  warn "op-deployer binary not present; OP_DEPLOYER_SHA256 left unchanged"
fi
sedi -E "s|^LOCKED_AT=.*|LOCKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)|" "$LOCK"
echo "versions.lock frozen. Commit it together with manifests/onchain-*.json."
