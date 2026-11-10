#!/usr/bin/env bash
# Assemble the per-host secrets directory from keys/.
#   scripts/secrets.sh a      -> node-a/secrets/{jwt.txt,p2p-node-key.txt,op-node.env,op-batcher.env,op-proposer.env}
#   scripts/secrets.sh b      -> node-b/secrets/{jwt.txt,p2p-node-key.txt,op-challenger.env}
#   scripts/secrets.sh bundle-b -> keys/node-b-bundle.tar (move to host B once, then delete)
#   scripts/secrets.sh install-b <bundle.tar> -> unpack into node-b/secrets on host B

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq tar
load_env "$FINCHAIN_ROOT/versions.lock"

KEYS="$FINCHAIN_ROOT/keys"
mode="${1:-}"

copy_secret() { # src dst
  umask 077
  cp "$1" "$2"
  chmod 600 "$2"
}

assemble_a() {
  local d="$FINCHAIN_ROOT/node-a/secrets"
  mkdir -p "$d"; chmod 700 "$d"
  copy_secret "$KEYS/node-a-jwt.txt" "$d/jwt.txt"
  copy_secret "$KEYS/node-a-p2p-node-key.txt" "$d/p2p-node-key.txt"
  umask 077
  printf 'OP_NODE_P2P_SEQUENCER_KEY=%s\n' "$(key_field unsafe_block_signer private_key | sed 's/^0x//')" > "$d/op-node.env"
  printf 'OP_BATCHER_PRIVATE_KEY=%s\n' "$(key_field batcher private_key)" > "$d/op-batcher.env"
  printf 'OP_PROPOSER_PRIVATE_KEY=%s\n' "$(key_field proposer private_key)" > "$d/op-proposer.env"
  chmod 600 "$d"/*.env
  log "host A secrets written to node-a/secrets"
}

assemble_b_into() { # target dir
  local d="$1"
  mkdir -p "$d"; chmod 700 "$d"
  copy_secret "$KEYS/node-b-jwt.txt" "$d/jwt.txt"
  copy_secret "$KEYS/node-b-p2p-node-key.txt" "$d/p2p-node-key.txt"
  umask 077
  printf 'OP_CHALLENGER_PRIVATE_KEY=%s\n' "$(key_field challenger private_key)" > "$d/op-challenger.env"
  chmod 600 "$d"/*.env
}

case "$mode" in
  a) assemble_a ;;
  b) assemble_b_into "$FINCHAIN_ROOT/node-b/secrets"; log "host B secrets written to node-b/secrets" ;;
  bundle-b)
    tmp="$(mktemp -d)"
    assemble_b_into "$tmp/secrets"
    tar -C "$tmp" -cf "$KEYS/node-b-bundle.tar" secrets
    chmod 600 "$KEYS/node-b-bundle.tar"
    rm -rf "$tmp"
    log "bundle written: keys/node-b-bundle.tar"
    log "move it once over the private network, e.g.: scp keys/node-b-bundle.tar <host-b>:finchain/keys/ ; then delete the local copy"
    ;;
  install-b)
    bundle="${2:?usage: secrets.sh install-b <bundle.tar>}"
    [ -f "$bundle" ] || die "bundle not found: $bundle"
    d="$FINCHAIN_ROOT/node-b"
    tar -C "$d" -xf "$bundle"
    chmod 700 "$d/secrets"; chmod 600 "$d"/secrets/*
    log "host B secrets installed into node-b/secrets; delete the bundle now: rm $bundle"
    ;;
  *) die "usage: secrets.sh a | b | bundle-b | install-b <bundle.tar>" ;;
esac
