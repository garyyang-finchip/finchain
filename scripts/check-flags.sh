#!/usr/bin/env bash
# Verify that every command-line flag used in the compose files exists in the pinned images.
# Flag names drift between releases; this catches drift before a container crash-loops.
#
# Usage: scripts/check-flags.sh [a|b|all]   (default all)
#
# Each image is started with its own entrypoint (the service binary) and asked for --help;
# if that yields no flag list, the binary is tried by name with the entrypoint cleared.
# On a failure the first lines of the captured output are printed for diagnosis.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd docker awk
load_env "$FINCHAIN_ROOT/versions.lock"
docker info >/dev/null 2>&1 || die "docker daemon not reachable - start Docker (OrbStack / Docker Desktop / dockerd) and re-run"

target="${1:-all}"
fail=0

# flags_from_compose <compose-file> <service>  -> prints --flag names used by that service
flags_from_compose() {
  awk -v svc="$2" '
    $0 ~ "^  "svc":" { insvc = 1; next }
    insvc && /^  [a-zA-Z]/ { insvc = 0 }
    insvc && /^    command:/ { incmd = 1; next }
    insvc && incmd && /^      - / {
      line = $0; sub(/^      - /, "", line);
      if (line ~ /^--/) { split(line, kv, "="); print kv[1] }
      next
    }
    insvc && incmd && !/^      - / { incmd = 0 }
  ' "$1" | sort -u
}

# help_output <image> <binary> [subcommand]  -> prints the --help text (best effort)
help_output() {
  local image="$1" binary="$2" sub="${3:-}" out=""
  # 1. image entrypoint (the service binary itself)
  if [ -n "$sub" ]; then
    out="$(docker run --rm "$image" "$sub" --help 2>&1 || true)"
  else
    out="$(docker run --rm "$image" --help 2>&1 || true)"
  fi
  if printf '%s' "$out" | grep -q -- '--'; then printf '%s' "$out"; return; fi
  # 2. binary by name with the entrypoint cleared
  if [ -n "$sub" ]; then
    out="$(docker run --rm --entrypoint "" "$image" "$binary" "$sub" --help 2>&1 || true)"
  else
    out="$(docker run --rm --entrypoint "" "$image" "$binary" --help 2>&1 || true)"
  fi
  printf '%s' "$out"
}

# check_service <compose-file> <service> <image> <binary> [subcommand]
check_service() {
  local compose_file="$1" svc="$2" image="$3" binary="$4" sub="${5:-}"
  local help flags flag missing=()
  log "checking $svc ($image)"
  help="$(help_output "$image" "$binary" "$sub")"
  flags="$(flags_from_compose "$compose_file" "$svc")"
  for flag in $flags; do
    if ! printf '%s' "$help" | grep -q -- "$flag"; then missing+=("$flag"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "  MISSING in $svc help output: ${missing[*]}"
    echo "  first lines of what the container printed:"
    printf '%s\n' "$help" | head -8 | sed 's/^/    | /'
    fail=1
  else
    echo "  all $(echo "$flags" | wc -w | tr -d ' ') flags present"
  fi
}

if [ "$target" = "a" ] || [ "$target" = "all" ]; then
  compose_a="$FINCHAIN_ROOT/node-a/docker-compose.yml"
  check_service "$compose_a" op-reth     "$OP_RETH_IMAGE"     op-reth node
  check_service "$compose_a" op-node     "$OP_NODE_IMAGE"     op-node
  check_service "$compose_a" op-batcher  "$OP_BATCHER_IMAGE"  op-batcher
  check_service "$compose_a" op-proposer "$OP_PROPOSER_IMAGE" op-proposer
fi
if [ "$target" = "b" ] || [ "$target" = "all" ]; then
  compose_b="$FINCHAIN_ROOT/node-b/docker-compose.yml"
  check_service "$compose_b" op-reth       "$OP_RETH_IMAGE"       op-reth node
  check_service "$compose_b" op-node       "$OP_NODE_IMAGE"       op-node
  check_service "$compose_b" op-challenger "$OP_CHALLENGER_IMAGE" op-challenger
fi

if [ "$fail" -ne 0 ]; then
  echo "Flag check FAILED: adjust the compose files or versions.lock (see docs/versions.md)."
  exit 1
fi
echo "Flag check passed."
