#!/usr/bin/env bash
# Download the op-deployer release binary for this host into bin/ and print its sha256.
# Version comes from versions.lock (OP_DEPLOYER_VERSION). Release tag: op-deployer/<version>.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd curl tar
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "need sha256sum or shasum"
load_env "$FINCHAIN_ROOT/versions.lock"

ver="${OP_DEPLOYER_VERSION:?}"
os="$(host_os)"; arch="$(host_arch)"
dest="$(op_deployer_bin)"
mkdir -p "$FINCHAIN_ROOT/bin"

if [ -x "$dest" ] && [ "${FORCE:-0}" != "1" ]; then
  log "op-deployer $ver already present at $dest"
else
  base="https://github.com/ethereum-optimism/optimism/releases/download/op-deployer%2F${ver}"
  asset="op-deployer-${os}-${arch}"
  tmp="$(mktemp -d)"
  log "downloading ${base}/${asset}"
  if curl -fsSL -o "$tmp/$asset" "${base}/${asset}"; then
    mv "$tmp/$asset" "$dest"
  elif curl -fsSL -o "$tmp/$asset.tar.gz" "${base}/${asset}.tar.gz"; then
    tar -C "$tmp" -xzf "$tmp/$asset.tar.gz"
    f="$(find "$tmp" -type f -name 'op-deployer*' ! -name '*.tar.gz' | head -1)"
    [ -n "$f" ] || die "archive did not contain an op-deployer binary"
    mv "$f" "$dest"
  else
    die "could not download op-deployer $ver for $os/$arch. Check the release assets for tag op-deployer/$ver and adjust the asset name in this script."
  fi
  chmod +x "$dest"
  rm -rf "$tmp"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "$dest" | awk '{print $1}')"
else
  sum="$(shasum -a 256 "$dest" | awk '{print $1}')"
fi
echo "op-deployer $ver ($os/$arch) sha256=$sum"
"$dest" --version || warn "binary did not report a version; check that it runs on this host"
