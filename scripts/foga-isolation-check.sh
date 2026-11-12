#!/usr/bin/env bash
# FOGA on its own: the reverse acceptance (docs/world.md, "FOGA on its own"; docs/acceptance.md M3-B).
# A FOGA package, installed from the npm registry into a clean directory with a clean home, is run as a user runs
# it while every Node process it starts is preloaded with scripts/foga-isolation-preload.mjs: each host name it
# resolves or connects to is logged, and any name under finchain.one fails as if it did not exist. The legs are the
# release check's own: the help, the chain table and its default, the local quickstart (anvil), the local genesis
# T0-T9, and - when SEPOLIA_RPC_URL is set - a read of the packaged Sepolia world with the doctor. The result is the
# log: zero names under finchain.one, and every leg passing without it.
#
# Usage: scripts/foga-isolation-check.sh [foga-version=1.0.7]
#   env: FOGA_FOUNDRY_DIR  directory holding anvil (else anvil on PATH; the quickstart and genesis legs are skipped without one)
#        SEPOLIA_RPC_URL   a Sepolia RPC for the Sepolia-world leg (skipped without it)
#        KEEP=1            keep the working directory
# Needs Node >= 22.13 and npm; no root, no ports, no changes to the host (the home is a temporary directory).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd node npm jq

VERSION="${1:-1.0.7}"
PRELOAD="$FINCHAIN_ROOT/scripts/foga-isolation-preload.mjs"
[ -f "$PRELOAD" ] || die "preload missing: $PRELOAD"
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" -ge 22 ] || die "Node 22.13 or newer is required (found $(node -v))"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/foga-isolation-XXXXXX")"
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR"
LOGFILE="$WORK/hosts.log"; : > "$LOGFILE"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cleanup() { if [ "${KEEP:-0}" = "1" ]; then echo "kept $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

# The environment the package runs in: a clean home, the preload, and only the variables a proxy or a private CA
# needs to reach the registry (nothing of the operator's FOGA configuration).
PASS_ENV=""
for v in HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy NODE_EXTRA_CA_CERTS SSL_CERT_FILE npm_config_registry npm_config_cafile npm_config_proxy npm_config_https_proxy; do
  eval "val=\${$v:-}"
  [ -n "$val" ] && PASS_ENV="$PASS_ENV $v=$val"
done
run_env() { # run a command with the clean home and the preload
  # shellcheck disable=SC2086
  env -i PATH="$PATH" HOME="$HOMEDIR" TMPDIR="$WORK/tmp" NODE_OPTIONS="--import=$PRELOAD" FOGA_ISOLATION_LOG="$LOGFILE" \
      ${FOGA_FOUNDRY_DIR:+FOGA_FOUNDRY_DIR="$FOGA_FOUNDRY_DIR"} ${SEPOLIA_RPC_URL:+SEPOLIA_RPC_URL="$SEPOLIA_RPC_URL"} $PASS_ENV "$@"
}
mkdir -p "$WORK/tmp" "$WORK/pkg"
LEGS=""
leg() { # <name> <expected exit> <command...>  -> runs in $WORK/pkg, records exit code and the last output lines
  local name="$1" expect="$2"; shift 2
  local out code
  out="$(cd "$WORK/pkg" && run_env "$@" 2>&1)" && code=0 || code=$?
  local verdict=pass; [ "$code" = "$expect" ] || verdict=fail
  printf '  %-6s %-22s exit %s (expected %s)\n' "$verdict" "$name" "$code" "$expect"
  LEGS="$LEGS$(jq -cn --arg n "$name" --arg v "$verdict" --argjson c "$code" --argjson e "$expect" --arg tail "$(printf '%s' "$out" | tail -n 12)" '{leg: $n, result: $v, exit: $c, expected: $e, tail: $tail}'),"
  [ "$verdict" = "pass" ] || FAILED=1
}
FAILED=0

echo "FOGA isolation check: @finchip.ai/foga@$VERSION in $WORK (home $HOMEDIR); finchain.one blocked and every host name logged"
log "installing @finchip.ai/foga@$VERSION from the registry into a clean directory"
(cd "$WORK/pkg" && run_env npm init -y >/dev/null 2>&1 && run_env npm install --no-audit --no-fund --loglevel=error "@finchip.ai/foga@$VERSION" >/dev/null) || die "npm install failed"
PKG="$WORK/pkg/node_modules/@finchip.ai/foga"
: > "$LOGFILE" # the installer's own lookups are not the package's
installed="$(jq -r .version "$PKG/package.json")"
echo "installed $installed ($(jq -r .name "$PKG/package.json"))"
FOGA=(node "$PKG/bin/foga.js")

log "instrumentation controls (their own log, not counted below)"
CONTROL="$WORK/control.log"; : > "$CONTROL"
ctl="$(cd "$WORK/pkg" && run_env env FOGA_ISOLATION_LOG="$CONTROL" node -e '
  const dns = require("node:dns"); const net = require("node:net");
  dns.lookup("registry.npmjs.org", (e, a) => { console.log("lookup registry.npmjs.org:", e ? e.code : "resolved");
    dns.lookup("rpc.finchain.one", (e2) => { console.log("lookup rpc.finchain.one:", e2 ? e2.code : "RESOLVED");
      const s = net.connect({ host: "rpc.finchain.one", port: 443 }); s.on("error", (e3) => { console.log("connect rpc.finchain.one:", e3.code);
        const l = net.connect({ host: "127.0.0.1", port: 9 }); l.on("error", () => { console.log("connect 127.0.0.1: attempted"); process.exit(0); }); l.on("connect", () => { console.log("connect 127.0.0.1: attempted"); l.destroy(); process.exit(0); }); });
      s.on("connect", () => { console.log("connect rpc.finchain.one: CONNECTED"); process.exit(5); }); }); });' 2>&1)" || true
printf '%s\n' "$ctl" | sed 's/^/  /'
logged="$(grep -c 'registry.npmjs.org' "$CONTROL" || true)"; socket_logged="$(grep -c '"socket.connect","host":"127.0.0.1"' "$CONTROL" || true)"; blocked_dns="$(printf '%s' "$ctl" | grep -c 'lookup rpc.finchain.one: ENOTFOUND' || true)"; blocked_net="$(printf '%s' "$ctl" | grep -c 'connect rpc.finchain.one: ENOTFOUND' || true)"
if [ "$logged" -ge 1 ] && [ "$socket_logged" -ge 1 ] && [ "$blocked_dns" = "1" ] && [ "$blocked_net" = "1" ]; then echo "  pass   controls: a real name and a socket to an IP literal are logged, finchain.one is refused at the resolver and at the socket"; CONTROLS=pass; else echo "  FAIL   controls: logged=$logged socketLogged=$socket_logged blockedDns=$blocked_dns blockedNet=$blocked_net"; CONTROLS=fail; FAILED=1; fi

log "legs"
leg help 0 "${FOGA[@]}" --help
leg chain-table 0 node --input-type=module -e "import('$PKG/dist/core/chains.js').then((m) => { const names = Object.keys(m.CHAINS); const finchain = names.filter((n) => /finchain/i.test(n)); console.log(JSON.stringify({ chains: names, finchainEntries: finchain, sepoliaWorld: m.CHAINS.sepolia?.world ?? null })); if (!m.CHAINS.sepolia?.world) process.exit(4); })"
ANVIL=""
if [ -n "${FOGA_FOUNDRY_DIR:-}" ] && [ -x "$FOGA_FOUNDRY_DIR/anvil" ]; then ANVIL="$FOGA_FOUNDRY_DIR/anvil"
elif command -v anvil >/dev/null 2>&1; then ANVIL="$(command -v anvil)"; fi
if [ -n "$ANVIL" ]; then
  echo "  anvil  $ANVIL ($("$ANVIL" --version 2>/dev/null | head -n 1))"
  leg quickstart 0 "${FOGA[@]}" quickstart --exit
  leg genesis-T9 0 "${FOGA[@]}" demo --genesis T9 --port 8599
else
  echo "  skip   quickstart, genesis-T9 (no anvil: set FOGA_FOUNDRY_DIR to a Foundry directory or put anvil on PATH)"
fi
if [ -n "${SEPOLIA_RPC_URL:-}" ]; then
  # the doctor exits 3 on a known failing layer of the Sepolia world (an upstream fixture); the leg is the read itself
  out="$(cd "$WORK/pkg" && run_env "${FOGA[@]}" doctor --world "$PKG/deployments/sepolia.example.json" --rpc "$SEPOLIA_RPC_URL" --out "$WORK/sepolia.doctor.json" 2>&1)" && code=0 || code=$?
  if [ -f "$WORK/sepolia.doctor.json" ]; then verdict=pass; else verdict=fail; FAILED=1; fi
  printf '  %-6s %-22s exit %s (a report was %s)\n' "$verdict" sepolia-world-read "$code" "$([ "$verdict" = pass ] && echo written || echo 'not written')"
  LEGS="$LEGS$(jq -cn --arg v "$verdict" --argjson c "$code" --arg tail "$(printf '%s' "$out" | tail -n 12)" --arg summary "$(jq -c '.summary // {}' "$WORK/sepolia.doctor.json" 2>/dev/null || echo '{}')" '{leg: "sepolia-world-read", result: $v, exit: $c, doctorSummary: ($summary | fromjson? // $summary), tail: $tail}'),"
else
  echo "  skip   sepolia-world-read (SEPOLIA_RPC_URL not set)"
fi

log "host names seen by the package's Node processes"
total="$(wc -l < "$LOGFILE" | tr -d ' ')"
finchain_hits="$(grep -ci 'finchain' "$LOGFILE" || true)"
hosts="$(jq -r '.host' "$LOGFILE" 2>/dev/null | sort | uniq -c | sort -rn | awk '{ printf "%s (%s)\n", $2, $1 }')"
printf '%s\n' "$hosts" | sed 's/^/  /'
echo "  entries $total; names under finchain.one: $finchain_hits"
[ "$finchain_hits" = "0" ] || FAILED=1
result=PASS; [ "$FAILED" = "0" ] || result=FAIL

mkdir -p "$FINCHAIN_ROOT/manifests/evidence"
out="$FINCHAIN_ROOT/manifests/evidence/foga-isolation-$installed-$(date -u +%Y%m%dT%H%M%SZ).json"
jq -n --arg version "$installed" --arg started "$STARTED" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg node "$(node -v)" --arg platform "$(uname -srm)" \
  --argjson legs "[${LEGS%,}]" --argjson total "$total" --argjson hits "$finchain_hits" --arg hosts "$hosts" --arg result "$result" \
  --arg foundry "$ANVIL" --arg sepolia "$([ -n "${SEPOLIA_RPC_URL:-}" ] && echo set || echo unset)" --arg controls "$CONTROLS" '
  { acceptance: "M3-B FOGA on its own (isolation check)", package: "@finchip.ai/foga", version: $version, node: $node, platform: $platform,
    startedAt: $started, finishedAt: $at, anvil: (if $foundry == "" then null else $foundry end), sepoliaRpc: $sepolia,
    method: "clean directory and home; every Node process preloaded with scripts/foga-isolation-preload.mjs (host names logged, finchain.one refused); legs run as a user runs them",
    instrumentationControls: $controls, legs: $legs, hostNameEntries: $total, hostNames: ($hosts | split("\n") | map(select(length > 0))), finchainNames: $hits, result: $result }' > "$out"
echo "RESULT: $result; report $out"
[ "$result" = "PASS" ] || exit 3
