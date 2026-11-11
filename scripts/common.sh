#!/usr/bin/env bash
# Shared helpers for the Finchain operator scripts. Source, do not execute.
# Requirements on the operator host: bash 4+, docker (compose v2), curl, jq, openssl.

set -euo pipefail

FINCHAIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FINCHAIN_ROOT

log()  { printf '[finchain] %s\n' "$*" >&2; }
warn() { printf '[finchain] WARNING: %s\n' "$*" >&2; }
die()  { printf '[finchain] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Load KEY=VALUE files (dotenv style) into the environment. Later files override earlier ones.
load_env() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || die "environment file not found: $f"
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  done
}

# Load the standard set: versions.lock, .env (shared), and optionally a profile.
load_standard_env() {
  load_env "$FINCHAIN_ROOT/versions.lock"
  [ -f "$FINCHAIN_ROOT/.env" ] || die "copy .env.example to .env first"
  load_env "$FINCHAIN_ROOT/.env"
  if [ -n "${PROFILE:-}" ]; then
    load_env "$FINCHAIN_ROOT/profiles/${PROFILE}.env"
  fi
}

# Portable in-place sed (GNU sed on Linux, BSD sed on macOS).
sedi() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Host OS / architecture in the names used by release assets.
host_os() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo darwin ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# Run Foundry's cast through Docker so that no host install is required.
# The foundry image's entrypoint is a shell (`/bin/sh -c`), so the binary is named
# explicitly with --entrypoint; otherwise the arguments are swallowed and cast prints help.
cast() {
  docker run --rm -i --network host --entrypoint cast \
    -v "$FINCHAIN_ROOT":"$FINCHAIN_ROOT" -w "$FINCHAIN_ROOT" \
    "${FOUNDRY_IMAGE:?FOUNDRY_IMAGE not set (load versions.lock)}" "$@"
}

# JSON-RPC helper: rpc <url> <method> [params-json]
rpc() {
  local url="$1" method="$2" params="${3:-[]}"
  curl -sS -X POST "$url" -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
}

# Path to the op-deployer binary for this host (downloaded by scripts/get-op-deployer.sh).
op_deployer_bin() {
  echo "$FINCHAIN_ROOT/bin/op-deployer-${OP_DEPLOYER_VERSION:?}"
}

# Read a key file written by gen-keys.sh: key_field <role> <address|private_key>
key_field() {
  local role="$1" field="$2" f="$FINCHAIN_ROOT/keys/$1.json"
  [ -f "$f" ] || die "key file not found for role '$role': $f (run make keys)"
  jq -r ".$field" "$f"
}

# Chain id as 32-byte hex, the form op-deployer uses in intent.toml.
chain_id_hex32() {
  printf '0x%064x' "${CHAIN_ID:?}"
}
