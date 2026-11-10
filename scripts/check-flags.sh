#!/usr/bin/env bash
# Verify that every command-line flag used in the compose files exists in the pinned images.
# Flag names drift between releases; this catches drift before a container crash-loops.
#
# Usage: scripts/check-flags.sh [a|b|all]   (default all)

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd docker awk
load_env "$FINCHAIN_ROOT/versions.lock"

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

check_service() { # <compose-file> <service> <image> <help-command...>
  local file="$1" svc="$2" image="$3"; shift 3
  local help flags missing=()
  log "checking $svc ($image)"
  if ! help="$(docker run --rm --entrypoint "" "$image" "$@" 2>&1)"; then
    # some images print help to stderr with a non-zero exit; keep the output anyway
    :
  fi
  flags="$(flags_from_compose "$file" "$svc")"
  for f in $flags; do
    if ! printf '%s' "$help" | grep -q -- "$f"; then missing+=("$f"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "  MISSING in $svc help output: ${missing[*]}"
    fail=1
  else
    echo "  all $(echo "$flags" | wc -w | tr -d ' ') flags present"
  fi
}

if [ "$target" = "a" ] || [ "$target" = "all" ]; then
  f="$FINCHAIN_ROOT/node-a/docker-compose.yml"
  check_service "$f" op-reth     "$OP_RETH_IMAGE"     op-reth node --help
  check_service "$f" op-node     "$OP_NODE_IMAGE"     op-node --help
  check_service "$f" op-batcher  "$OP_BATCHER_IMAGE"  op-batcher --help
  check_service "$f" op-proposer "$OP_PROPOSER_IMAGE" op-proposer --help
fi
if [ "$target" = "b" ] || [ "$target" = "all" ]; then
  f="$FINCHAIN_ROOT/node-b/docker-compose.yml"
  check_service "$f" op-reth       "$OP_RETH_IMAGE"       op-reth node --help
  check_service "$f" op-node       "$OP_NODE_IMAGE"       op-node --help
  check_service "$f" op-challenger "$OP_CHALLENGER_IMAGE" op-challenger --help
fi

if [ "$fail" -ne 0 ]; then
  echo "Flag check FAILED: adjust the compose files or versions.lock (see docs/versions.md)."
  exit 1
fi
echo "Flag check passed."
