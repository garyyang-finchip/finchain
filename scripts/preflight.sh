#!/usr/bin/env bash
# Host preflight for a Finchain operator machine.
#   scripts/preflight.sh a   -> host A (sequencing host)
#   scripts/preflight.sh b   -> host B (verification host)
# Checks: tools, Docker and Compose, CPU architecture support of every pinned image,
# disk and memory, L1 execution RPC and beacon API, time synchronisation, port
# availability, and the command-line flags used by the compose files.
# Exit code 0 means every check passed; warnings are printed but do not fail.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
host="${1:-}"
[ "$host" = "a" ] || [ "$host" = "b" ] || die "usage: preflight.sh <a|b>"

fail=0
ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; fail=1; }
note() { echo "  [warn] $*"; }

echo "== tools"
for c in docker curl jq openssl awk tar; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else bad "$c missing"; fi
done
if docker compose version >/dev/null 2>&1; then ok "docker compose $(docker compose version --short)"; else bad "docker compose v2 missing"; fi
if docker info >/dev/null 2>&1; then ok "docker daemon reachable"; else bad "docker daemon not reachable"; fi

echo "== host"
os="$(host_os)"; arch="$(host_arch)"
ok "os=$os arch=$arch"
if [ "$os" = "darwin" ]; then
  note "macOS host: keep the machine awake (pmset -a sleep 0 disablesleep 1) and use named volumes (bind mounts are slow)"
fi
if [ "$os" = "linux" ]; then
  mem_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
  echo "  memory: $((mem_kb / 1024 / 1024)) GiB"
  [ "$mem_kb" -ge $((7 * 1024 * 1024)) ] || note "less than 8 GiB RAM; fine for an idle chain, not for dispute drills"
fi
df_avail_gb="$(df -Pk . | awk 'NR==2 { printf "%d", $4 / 1024 / 1024 }')"
echo "  disk available in $(pwd): ${df_avail_gb} GiB"
[ "$df_avail_gb" -ge 100 ] || note "less than 100 GiB free; archive data grows with chain activity"

echo "== time"
if command -v timedatectl >/dev/null 2>&1; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then ok "NTP synchronised"; else note "NTP not synchronised (sequencer timestamps and L1 derivation need a correct clock)"; fi
else
  note "cannot verify clock sync on this OS; make sure time is synchronised"
fi

echo "== environment files"
if [ -f "$FINCHAIN_ROOT/.env" ]; then ok ".env"; else bad ".env missing (cp .env.example .env)"; fi
if [ -f "$FINCHAIN_ROOT/node-$host/.env" ]; then ok "node-$host/.env"; else bad "node-$host/.env missing"; fi
if [ "$host" = "a" ]; then secrets=(jwt.txt p2p-node-key.txt op-node.env op-batcher.env op-proposer.env); else secrets=(jwt.txt p2p-node-key.txt op-challenger.env); fi
for s in "${secrets[@]}"; do
  if [ -f "$FINCHAIN_ROOT/node-$host/secrets/$s" ]; then ok "secret $s"; else note "secret node-$host/secrets/$s missing (make secrets-$host / install-bundle-b before up)"; fi
done
for a in genesis.json rollup.json; do
  if [ -f "$FINCHAIN_ROOT/chain/out/$a" ]; then ok "chain/out/$a"; else note "chain/out/$a missing (make export before up)"; fi
done
load_env "$FINCHAIN_ROOT/versions.lock"
[ -f "$FINCHAIN_ROOT/.env" ] && load_env "$FINCHAIN_ROOT/.env"
[ -f "$FINCHAIN_ROOT/node-$host/.env" ] && load_env "$FINCHAIN_ROOT/node-$host/.env"

echo "== images (architecture $arch)"
if [ "$host" = "a" ]; then images=("$OP_RETH_IMAGE" "$OP_NODE_IMAGE" "$OP_BATCHER_IMAGE" "$OP_PROPOSER_IMAGE" "$FOUNDRY_IMAGE");
else images=("$OP_RETH_IMAGE" "$OP_NODE_IMAGE" "$OP_CHALLENGER_IMAGE" "$CADDY_IMAGE" "$FOUNDRY_IMAGE"); fi
for img in "${images[@]}"; do
  if m="$(docker manifest inspect "$img" 2>/dev/null)"; then
    archs="$(echo "$m" | jq -r '[.manifests[]?.platform.architecture // empty] | unique | join(",")')"
    if [ -z "$archs" ]; then
      # single-platform manifest: inspect config after pull is needed; pull and check
      if docker pull -q "$img" >/dev/null 2>&1; then
        a="$(docker image inspect "$img" --format '{{.Architecture}}')"
        if [ "$a" = "$arch" ]; then ok "$img (single-arch $a)"; else bad "$img is $a, host is $arch"; fi
      else
        bad "cannot pull $img"
      fi
    elif echo ",$archs," | grep -q ",$arch,"; then
      ok "$img [$archs]"
    else
      bad "$img has no $arch build [$archs] - see docs/networking.md (host A fallback: native binary or emulation)"
    fi
  else
    bad "manifest not found for $img (tag typo or registry unreachable)"
  fi
done

echo "== L1 endpoints"
if cid="$(rpc "${L1_RPC_URL:?}" eth_chainId | jq -r .result 2>/dev/null)" && [ -n "$cid" ] && [ "$cid" != "null" ]; then
  if [ "$((cid))" = "${L1_CHAIN_ID:-11155111}" ]; then ok "L1 RPC chain id $((cid))"; else bad "L1 RPC chain id $((cid)) != ${L1_CHAIN_ID}"; fi
  fin="$(rpc "$L1_RPC_URL" eth_getBlockByNumber '["finalized",false]' | jq -r .result.number)"
  if [ -n "$fin" ] && [ "$fin" != "null" ]; then ok "L1 RPC serves the finalized tag ($((fin)))"; else bad "L1 RPC does not serve the finalized tag (op-node needs it)"; fi
else
  bad "L1 RPC unreachable: $L1_RPC_URL"
fi
if v="$(curl -fsS "${L1_BEACON_URL:?}/eth/v1/node/version" 2>/dev/null | jq -r .data.version)"; then ok "beacon API: $v"; else bad "beacon API unreachable: $L1_BEACON_URL"; fi

echo "== ports"
ports=(8545 8546 8547 9222)
[ "$host" = "a" ] && ports+=(8548 8560)
[ "$host" = "b" ] && ports+=(80 443)
for p in "${ports[@]}"; do
  if (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$") || \
     (command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1); then
    note "port $p already in use (fine if it is this stack)"
  else
    ok "port $p free"
  fi
done

echo "== flags in pinned images"
if bash "$FINCHAIN_ROOT/scripts/check-flags.sh" "$host"; then ok "flag check"; else bad "flag check"; fi

echo
if [ "$fail" -eq 0 ]; then echo "PREFLIGHT PASSED for host $host"; else echo "PREFLIGHT FAILED for host $host"; exit 1; fi
