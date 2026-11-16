#!/bin/sh
# kona-host-finchain: the preimage server of the cannon-kona path for a chain that lives in the client's and the
# host's embedded registry but not in op-challenger's own chain list.
#
# op-challenger hands kona-host `--rollup-config-path <file>` for any chain it does not know by name. kona-host then
# treats the chain id as unknown (0) and the client inside the VM, finding no chain 0 in its registry, falls back to
# the rollup configuration the host feeds it through the preimage oracle - the path kona-client itself labels
# "insecure in production". On chain it is the game contract that gives the client the chain id (local preimage key
# 5, the implementation's L2_CHAIN_ID), so the client looks the chain up in the registry built into the prestate; an
# off-chain run must take the same path or its trace is not the one step() verifies. This wrapper drops
# `--rollup-config-path <file>` from the arguments, appends `--l2-chain-id $KONA_L2_CHAIN_ID` and runs the kona-host
# that was built with the chain embedded (drill/kona-host-build.sh). drill/run-trace.sh mounts both into the
# op-challenger container and names this file as --cannon-kona-server. Plain sh: the image has busybox.
set -eu
: "${KONA_L2_CHAIN_ID:?KONA_L2_CHAIN_ID must be set to the chain id the client should look up}"
bin="${KONA_HOST_REAL:-$(dirname "$0")/kona-host-finchain-bin}"
n=$#; i=0; skip=0
while [ "$i" -lt "$n" ]; do
  a="$1"; shift; i=$((i + 1))
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  if [ "$a" = "--rollup-config-path" ] || [ "$a" = "--rollup-cfg" ]; then skip=1; continue; fi
  set -- "$@" "$a"
done
exec "$bin" "$@" --l2-chain-id "$KONA_L2_CHAIN_ID"
