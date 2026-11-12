#!/usr/bin/env bash
# Verify that every command-line flag used in the compose files exists in the pinned images.
# Flag names drift between releases; this catches drift before a container crash-loops.
#
# Usage: scripts/check-flags.sh [a|b|all]   (default all)
#
# How the help text is obtained: the image is pulled quietly first, then run with its own
# entrypoint; if that does not produce a flag list (several OP Stack images have no
# entrypoint, only a CMD), the binary is invoked by name with the entrypoint cleared.
# Matching is done with here-strings, not pipes, so `pipefail` cannot turn an early
# grep exit into a false "missing" result.

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
    insvc && incmd && /^[ \t]*#/ { next }     # comment lines inside the list do not end it
    insvc && incmd && !/^      - / { incmd = 0 }
  ' "$1" | sort -u
}

# looks_like_help <text> -> true when the text lists at least five distinct --flags
looks_like_help() {
  local n
  n="$(grep -oE -- '--[a-z][a-z0-9.-]+' <<< "$1" | sort -u | wc -l | tr -d ' ')"
  [ "${n:-0}" -ge 5 ]
}

# run_help <image> <binary-or-empty> [subcommand] -> captured output (never fails)
run_help() {
  local image="$1" binary="$2" sub="${3:-}"
  if [ -n "$binary" ]; then
    if [ -n "$sub" ]; then docker run --rm --entrypoint "" "$image" "$binary" "$sub" --help 2>&1 || true
    else docker run --rm --entrypoint "" "$image" "$binary" --help 2>&1 || true; fi
  else
    if [ -n "$sub" ]; then docker run --rm "$image" "$sub" --help 2>&1 || true
    else docker run --rm "$image" --help 2>&1 || true; fi
  fi
}

# help_output <image> <binary> [subcommand] -> best-effort --help text
help_output() {
  local image="$1" binary="$2" sub="${3:-}" out
  docker pull -q "$image" >/dev/null 2>&1 || true
  out="$(run_help "$image" "" "$sub")"
  if ! looks_like_help "$out"; then
    out="$(run_help "$image" "$binary" "$sub")"
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
    if ! grep -q -- "$flag" <<< "$help"; then missing+=("$flag"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "  MISSING in $svc help output: ${missing[*]}"
    echo "  last lines of what the container printed:"
    printf '%s\n' "$help" | tail -6 | sed 's/^/    | /'
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
