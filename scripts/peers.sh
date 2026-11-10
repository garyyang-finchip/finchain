#!/usr/bin/env bash
# Print this host's op-node peer identity and the multiaddr the other host should put in
# P2P_STATIC_PEERS, and optionally connect to a peer right away.
#
# Usage: scripts/peers.sh <a|b> [peer-multiaddr-to-connect]
# The multiaddr printed uses the private-network IP from the host .env
# (A_BIND_IP for host A, B_BIND_IP for host B; replace with the address the other host dials).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl

host="${1:?a|b}"
case "$host" in
  a) load_env "$FINCHAIN_ROOT/node-a/.env"; bind="${A_BIND_IP}" ;;
  b) load_env "$FINCHAIN_ROOT/node-b/.env"; bind="${B_BIND_IP}" ;;
  *) die "usage: peers.sh <a|b> [peer-multiaddr]" ;;
esac
node="http://${bind}:8547"

self="$(rpc "$node" opp2p_self)"
peer_id="$(echo "$self" | jq -r '.result.peerID')"
echo "peer id: $peer_id"
echo "listen addresses:"
echo "$self" | jq -r '.result.addresses[]' | sed 's/^/  /'
echo
echo "Put this in the OTHER host's P2P_STATIC_PEERS (adjust the IP to the address that host dials):"
echo "  /ip4/${bind}/tcp/9222/p2p/${peer_id}"
echo
echo "Connected peers: $(rpc "$node" opp2p_peers '[true]' | jq -r '.result.totalConnected')"

if [ -n "${2:-}" ]; then
  log "connecting to $2"
  rpc "$node" opp2p_connectPeer "[\"$2\"]" | jq -c .
  sleep 2
  echo "Connected peers now: $(rpc "$node" opp2p_peers '[true]' | jq -r '.result.totalConnected')"
fi
