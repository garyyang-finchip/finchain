#!/usr/bin/env bash
# Print this host's op-node peer identity and the multiaddr the other host should put in
# P2P_STATIC_PEERS, and optionally connect to a peer right away.
#
# Usage: scripts/peers.sh <a|b> [peer-multiaddr-to-connect]
# The multiaddr printed uses the private-network IP from the host .env (A_BIND_IP for host A, B_BIND_IP for
# host B; replace with the address the other host dials) and the host p2p port of this chain's stack (A_P2P_PORT /
# B_P2P_PORT, 9222 for the first chain; a second chain publishes its own port, docs/runbook.md section 9).

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl

host="${1:?a|b}"
case "$host" in
  a) load_env "$(host_env a)"; bind="${A_BIND_IP}"; node_port="${A_NODE_RPC_PORT:-8547}"; p2p_port="${A_P2P_PORT:-9222}" ;;
  b) load_env "$(host_env b)"; bind="${B_BIND_IP}"; node_port="${B_NODE_RPC_PORT:-8547}"; p2p_port="${B_P2P_PORT:-9222}" ;;
  *) die "usage: peers.sh <a|b> [peer-multiaddr]" ;;
esac
node="http://${bind}:${node_port}"

self="$(rpc "$node" opp2p_self)"
peer_id="$(echo "$self" | jq -r '.result.peerID')"
echo "peer id: $peer_id"
echo "listen addresses:"
echo "$self" | jq -r '.result.addresses[]' | sed 's/^/  /'
echo
# the listen addresses above show the container port (9222); the other host dials the host port of this chain's stack
echo "Put this in the OTHER host's P2P_STATIC_PEERS (adjust the IP to the address that host dials; the port is this stack's host p2p port):"
echo "  /ip4/${bind}/tcp/${p2p_port}/p2p/${peer_id}"
echo
echo "Connected peers: $(rpc "$node" opp2p_peers '[true]' | jq -r '.result.totalConnected')"

if [ -n "${2:-}" ]; then
  log "connecting to $2"
  rpc "$node" opp2p_connectPeer "[\"$2\"]" | jq -c .
  sleep 2
  echo "Connected peers now: $(rpc "$node" opp2p_peers '[true]' | jq -r '.result.totalConnected')"
fi
