#!/usr/bin/env bash
# M4 K3: the Finchain devnet - an isolated environment in which a CANNON_KONA (type 8) game is defended down to a
# real step() on chain (docs/proof-plan.md, "K3: isolated environment"; drill/devnet/README.md). One scratch host,
# an anvil L1 with the shim in front of it, the production images of versions.lock, Finchain's parameters and a
# chain id of its own. Nothing here touches the public chain or its hosts; the only keys are anvil's published test
# accounts.
#
# Usage: drill/devnet/devnet.sh <step>   (make devnet-<step>; one step at a time, each prints what it did)
#   keys          derive the devnet accounts from anvil's test mnemonic -> out/keys/addresses.env, out/secrets/
#   l1            start anvil and the shim; place the deterministic deployer; check the shim on a real anvil block
#   intent        render the op-deployer intent (drill/devnet/intent.toml.in over op-deployer init) for review
#   deploy        render the intent again, op-deployer apply (live, against the anvil), inspect -> out/chain/
#   l2            start op-reth, op-node (sequencer) and op-batcher; wait for the first safe block (right after deploy:
#                 the chain must not fall behind its sequencing window while the prestate builds)
#   build         K1 and K2 for the devnet chain: kona-configs (KONA_CHECK=1 adds kona-check), prestate, kona-host
#   install-game  the owner installs game type 8 on the factory with the devnet prestate in its arguments
#                 (setImplementation(8, FaultDisputeGameImpl, args)); DEVNET_GAME_RESPECTED=1 also makes it respected
#   proof         start op-proposer (type 8) and the honest op-challenger (cannon-kona); wait for the first game
#   anchor        bootstrap the anchor root: resolve and close the first type-8 game once its clock has run out, so
#                 that the anchor state registry leaves op-deployer's placeholder (2.5 h of waiting, see README)
#   run-trace     K2b on the devnet: drill/run-trace.sh against the devnet's own endpoints
#   dispute       the adversary (drill/devnet/adversary.sh): attack the newest game down to the leaf, wait for the step
#   resolve       wait for the game to resolve; the final record
#   status        containers, heads, games
#   down          stop the devnet and delete its data (the shared prestate store under drill/out/ is kept)
# Environment: KONA_TAG (default kona-client/v1.9.0), KONA_BUILD_JOBS / BUILD_JOBS / CARGO_MODE as for the K2 scripts,
#   GAME=0x... (dispute: a game other than the newest), DISPUTE_TIMEOUT (default 4h), FRESH=1 (down: also delete out/),
#   OP_DEPLOYER_BIN (a binary other than the release scripts/get-op-deployer.sh fetches).
# Host: docker (compose v2.24+), git, jq, curl, openssl, python3 is not needed on the host (the shim runs in a
# container), just and docker buildx for the prestate build; the op-deployer binary is downloaded by scripts/.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
require_cmd docker jq curl openssl
DEVNET_DIR="$FINCHAIN_ROOT/drill/devnet"; OUT="$DEVNET_DIR/out"
load_env "$FINCHAIN_ROOT/versions.lock" "$DEVNET_DIR/devnet.env"
GEN="$OUT/generated.env"
[ ! -f "$GEN" ] || load_env "$GEN"
mkdir -p "$OUT/keys" "$OUT/secrets" "$OUT/deploy" "$OUT/chain" "$OUT/logs" "$OUT/bin" "$OUT/evidence" "$FINCHAIN_ROOT/manifests/evidence"
chmod 700 "$OUT/secrets"

L1_URL="http://127.0.0.1:$DEVNET_L1_PORT"        # the anvil, from this host
SHIM_URL="http://127.0.0.1:$DEVNET_SHIM_PORT"    # the shim, from this host
NODE_URL="http://127.0.0.1:$DEVNET_NODE_PORT"    # op-node, from this host
NETWORK=finchain-devnet_default                  # the compose network, where the containers see anvil:8545 and rpc-shim:8550
DET_DEPLOYER=0x4e59b44847b379578588920ca78fbf26c0b4956c
DET_DEPLOYER_CODE=0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3
# op-deployer's placeholder starting anchor root (opcm/opchain.go PermissionedGameStartingAnchorRoot): the anchor state
# registry starts here and moves only when a respected game is finalized and closed
DEAD_ROOT=0xdead000000000000000000000000000000000000000000000000000000000000
KONA_TAG="${KONA_TAG:-kona-client/v1.9.0}"

compose() {
  local args=(docker compose -p finchain-devnet -f "$DEVNET_DIR/docker-compose.yml" --env-file "$FINCHAIN_ROOT/versions.lock" --env-file "$DEVNET_DIR/devnet.env")
  [ ! -f "$GEN" ] || args+=(--env-file "$GEN")
  "${args[@]}" "$@"
}
# set_gen KEY VALUE: write a derived value into out/generated.env (compose and later steps read it)
set_gen() {
  touch "$GEN"
  if grep -q "^$1=" "$GEN"; then sedi -E "s|^$1=.*|$1=$2|" "$GEN"; else echo "$1=$2" >> "$GEN"; fi
  export "$1=$2"
}
l1_rpc() { rpc "$L1_URL" "$@"; }
hexdec() { printf '%d' "$1"; }
need_file() { [ -f "$1" ] || die "$2"; }
owner_key() { need_file "$OUT/secrets/deployer.key" "no devnet keys yet: devnet.sh keys"; cat "$OUT/secrets/deployer.key"; }
# the op-challenger CLI subcommands inside the compose network (list-games, list-claims, move)
challenger_cli() { docker run --rm --network "$NETWORK" --entrypoint op-challenger "${OP_CHALLENGER_IMAGE:?}" "$@"; }
image_digest() { docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || echo "$1"; }

###############################################################################################################
cmd_keys() {
  # anvil's test accounts in the order of the mnemonic; account 0 pays the deployment and holds every owner role
  local roles=(deployer batcher proposer challenger adversary unsafe_block_signer treasury) i role pk addr
  : > "$OUT/keys/addresses.env"
  for i in "${!roles[@]}"; do
    role="${roles[$i]}"
    pk="$(cast wallet private-key "$DEVNET_MNEMONIC" "$i" | tr -d '\r\n')"
    [[ "$pk" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "cast wallet private-key gave no key for index $i: $pk"
    addr="$(cast wallet address --private-key "$pk" | tr -d '\r\n')"
    [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "cast wallet address gave no address for $role: $addr"
    echo "DEVNET_ADDR_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')=$addr" >> "$OUT/keys/addresses.env"
    ( umask 077
      case "$role" in
        deployer) printf '%s\n' "$pk" > "$OUT/secrets/deployer.key" ;;
        batcher) printf 'OP_BATCHER_PRIVATE_KEY=%s\n' "$pk" > "$OUT/secrets/op-batcher.env" ;;
        proposer) printf 'OP_PROPOSER_PRIVATE_KEY=%s\n' "$pk" > "$OUT/secrets/op-proposer.env" ;;
        challenger) printf 'OP_CHALLENGER_PRIVATE_KEY=%s\n' "$pk" > "$OUT/secrets/op-challenger.env" ;;
        adversary) printf 'OP_CHALLENGER_PRIVATE_KEY=%s\n' "$pk" > "$OUT/secrets/adversary.env" ;;
        unsafe_block_signer) printf 'OP_NODE_P2P_SEQUENCER_KEY=%s\n' "$pk" > "$OUT/secrets/op-node.env" ;;
      esac )
    log "account $i: $role $addr"
  done
  [ -s "$OUT/secrets/jwt.txt" ] || ( umask 077; openssl rand -hex 32 > "$OUT/secrets/jwt.txt" )
  # shellcheck disable=SC1091
  . "$OUT/keys/addresses.env"
  local v name
  for v in DEPLOYER BATCHER PROPOSER CHALLENGER ADVERSARY UNSAFE_BLOCK_SIGNER TREASURY; do
    name="DEVNET_ADDR_$v"; set_gen "$name" "${!name}"
  done
  echo "accounts in $OUT/keys/addresses.env; keys in $OUT/secrets/ (anvil's published test accounts: funds on the devnet L1 only)"
}

###############################################################################################################
cmd_l1() {
  if [ -f "$OUT/deploy/state.json" ] && [ "$(jq -r '.superchainDeployment.superchainConfigProxy // empty' "$OUT/deploy/state.json")" != "" ] && [ "${FRESH:-0}" != 1 ]; then
    die "out/deploy/state.json holds a deployment: the L1 lives in memory, so a new anvil would be a new chain under the old artifacts. devnet.sh down (FRESH=1 deletes out/) before starting over"
  fi
  need_file "$OUT/secrets/deployer.key" "no devnet keys yet: devnet.sh keys"
  compose --profile l1 up -d
  local want i cid
  want="$(printf '0x%x' "$DEVNET_L1_CHAIN_ID")"
  for i in $(seq 1 60); do
    cid="$(l1_rpc eth_chainId 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
    [ "$cid" = "$want" ] && break
    sleep 1
  done
  [ "$cid" = "$want" ] || die "anvil does not answer eth_chainId $want on $L1_URL (docker compose -p finchain-devnet logs anvil)"
  log "anvil up: chain id $DEVNET_L1_CHAIN_ID, block time ${DEVNET_L1_BLOCK_TIME}s, head $(hexdec "$(l1_rpc eth_blockNumber | jq -r .result)")"

  # the CREATE2 deployer op-deployer requires (pipeline/init.go): the canonical runtime code placed with anvil_setCode
  local code
  code="$(l1_rpc eth_getCode "[\"$DET_DEPLOYER\",\"latest\"]" | jq -r .result)"
  if [ "$code" = "0x" ]; then
    l1_rpc anvil_setCode "[\"$DET_DEPLOYER\",\"$DET_DEPLOYER_CODE\"]" >/dev/null
    code="$(l1_rpc eth_getCode "[\"$DET_DEPLOYER\",\"latest\"]" | jq -r .result)"
  fi
  [ "$code" = "$DET_DEPLOYER_CODE" ] || die "the deterministic deployer code at $DET_DEPLOYER is not the canonical one: $code"
  log "deterministic deployer in place at $DET_DEPLOYER"

  # the shim: raw methods synthesised from a real anvil block (verified against the header inside the shim) and the beacon stub
  for i in $(seq 1 30); do curl -sf "$SHIM_URL/healthz" >/dev/null 2>&1 && break; sleep 1; done
  curl -sf "$SHIM_URL/healthz" >/dev/null 2>&1 || die "the shim does not answer on $SHIM_URL (docker compose -p finchain-devnet logs rpc-shim)"
  local head hdr rcpt gen
  head="$(l1_rpc eth_getBlockByNumber '["latest",false]' | jq -r .result.hash)"
  hdr="$(rpc "$SHIM_URL" debug_getRawHeader "[\"$head\"]")"
  [ "$(jq -r '.error.message // empty' <<<"$hdr")" = "" ] || die "the shim cannot synthesise debug_getRawHeader for anvil block $head: $(jq -r .error.message <<<"$hdr")"
  rcpt="$(rpc "$SHIM_URL" debug_getRawReceipts "[\"$head\"]")"
  [ "$(jq -r '.error.message // empty' <<<"$rcpt")" = "" ] || die "the shim cannot synthesise debug_getRawReceipts for anvil block $head: $(jq -r .error.message <<<"$rcpt")"
  gen="$(curl -sf "$SHIM_URL/eth/v1/beacon/genesis" | jq -r '.data.genesis_time // empty')"
  [ -n "$gen" ] || die "the beacon stub gives no genesis_time"
  log "shim up: raw header and receipts of $head verified, beacon genesis_time $gen, ${DEVNET_L1_BLOCK_TIME}s slots"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cid "$DEVNET_L1_CHAIN_ID" --argjson bt "$DEVNET_L1_BLOCK_TIME" --arg hf "$DEVNET_L1_HARDFORK" \
    --arg anvil "$(image_digest "${FOUNDRY_IMAGE:?}")" --arg py "$(image_digest "$DEVNET_PYTHON_IMAGE")" --arg dd "$DET_DEPLOYER" --arg gen "$gen" --arg head "$head" \
    '{startedAt: $at, chainId: $cid, blockTime: $bt, hardfork: $hf, slotsInAnEpoch: 1, anvilImage: $anvil, shimImage: $py,
      deterministicDeployer: {address: $dd, placedWith: "anvil_setCode, the canonical runtime code"}, beaconStub: {genesisTime: ($gen | tonumber)}, checkedBlock: $head}' > "$OUT/chain/l1.json"
  echo "L1 up: $L1_URL (anvil), $SHIM_URL (shim); record $OUT/chain/l1.json"
}

###############################################################################################################
op_deployer() { echo "${OP_DEPLOYER_BIN:-$(op_deployer_bin)}"; }
# intent: op-deployer init (custom) for the version string and state.json, then the rendered template over it
cmd_intent() {
  need_file "$OUT/keys/addresses.env" "no devnet keys yet: devnet.sh keys"
  # shellcheck disable=SC1091
  . "$OUT/keys/addresses.env"
  local bin work intent ver
  bin="$(op_deployer)"
  [ -x "$bin" ] || { log "fetching op-deployer ${OP_DEPLOYER_VERSION:?}"; bash "$FINCHAIN_ROOT/scripts/get-op-deployer.sh" >&2; }
  [ -x "$bin" ] || die "op-deployer binary missing at $bin"
  work="$OUT/deploy"; intent="$work/intent.toml"
  [ ! -f "$work/state.json" ] || [ "$(jq -r '.superchainDeployment.superchainConfigProxy // empty' "$work/state.json")" = "" ] || die "$work/state.json already holds a deployment; devnet.sh down first"
  # the constructor's own rules, checked before anything is rendered or deployed (FaultDisputeGame.sol), and the
  # parity the scenario needs (README: the honest side steps only against a leaf of the attacker at the max depth)
  local ext2=$(( DEVNET_GAME_CLOCK_EXTENSION * 2 )) extp=$(( DEVNET_GAME_CLOCK_EXTENSION + DEVNET_ORACLE_CHALLENGE_PERIOD ))
  [ "$ext2" -le "$DEVNET_GAME_MAX_CLOCK_DURATION" ] && [ "$extp" -le "$DEVNET_GAME_MAX_CLOCK_DURATION" ] || die "clock extension $DEVNET_GAME_CLOCK_EXTENSION, oracle challenge period $DEVNET_ORACLE_CHALLENGE_PERIOD and max clock duration $DEVNET_GAME_MAX_CLOCK_DURATION break the FaultDisputeGame constructor's rule (max(2e, e + p) <= d)"
  [ $(( DEVNET_GAME_SPLIT_DEPTH + 1 )) -lt "$DEVNET_GAME_MAX_DEPTH" ] && [ "$DEVNET_GAME_SPLIT_DEPTH" -ge 2 ] || die "split depth $DEVNET_GAME_SPLIT_DEPTH and max depth $DEVNET_GAME_MAX_DEPTH break the constructor's rule (2 <= split, split + 1 < max)"
  [ $(( DEVNET_GAME_MAX_DEPTH % 2 )) -eq 1 ] || die "max game depth $DEVNET_GAME_MAX_DEPTH is even: the honest side only executes step() when the attacker's claim sits at the max depth, which needs an odd depth with an honest root (README)"

  rm -f "$intent" "$work/state.json"
  "$bin" init --intent-type custom --l1-chain-id "$DEVNET_L1_CHAIN_ID" --l2-chain-ids "$DEVNET_L2_CHAIN_ID" --workdir "$work" >&2
  ver="$(grep -E '^[[:space:]]*opDeployerVersion' "$intent" | sed -E 's/.*"([^"]*)".*/\1/')"
  [ -n "$ver" ] || die "op-deployer init wrote no opDeployerVersion into $intent"
  # the rendered intent replaces init's skeleton; state.json (version, op-deployer version) stays
  sed -e "s|@OP_DEPLOYER_VERSION@|$ver|" -e "s|@L1_CHAIN_ID@|$DEVNET_L1_CHAIN_ID|" \
      -e "s|@L2_CHAIN_ID_HEX32@|$(printf '0x%064x' "$DEVNET_L2_CHAIN_ID")|" \
      -e "s|@OWNER@|$DEVNET_ADDR_DEPLOYER|g" -e "s|@TREASURY@|$DEVNET_ADDR_TREASURY|g" -e "s|@CHALLENGER@|$DEVNET_ADDR_CHALLENGER|g" \
      -e "s|@UNSAFE_BLOCK_SIGNER@|$DEVNET_ADDR_UNSAFE_BLOCK_SIGNER|" -e "s|@BATCHER@|$DEVNET_ADDR_BATCHER|" -e "s|@PROPOSER@|$DEVNET_ADDR_PROPOSER|" \
      -e "s|@GAME_MAX_DEPTH@|$DEVNET_GAME_MAX_DEPTH|" -e "s|@GAME_SPLIT_DEPTH@|$DEVNET_GAME_SPLIT_DEPTH|" \
      -e "s|@GAME_CLOCK_EXTENSION@|$DEVNET_GAME_CLOCK_EXTENSION|" -e "s|@GAME_MAX_CLOCK_DURATION@|$DEVNET_GAME_MAX_CLOCK_DURATION|" \
      -e "s|@ORACLE_CHALLENGE_PERIOD@|$DEVNET_ORACLE_CHALLENGE_PERIOD|" -e "s|@WITHDRAWAL_DELAY@|$DEVNET_WITHDRAWAL_DELAY|" \
      -e "s|@PROOF_MATURITY_DELAY@|$DEVNET_PROOF_MATURITY_DELAY|" -e "s|@GAME_FINALITY_DELAY@|$DEVNET_GAME_FINALITY_DELAY|" \
      -e "s|@EIP1559_DENOMINATOR_CANYON@|$DEVNET_EIP1559_DENOMINATOR_CANYON|" -e "s|@EIP1559_DENOMINATOR@|$DEVNET_EIP1559_DENOMINATOR|" \
      -e "s|@EIP1559_ELASTICITY@|$DEVNET_EIP1559_ELASTICITY|" -e "s|@GAS_LIMIT@|$DEVNET_GAS_LIMIT|" \
      "$DEVNET_DIR/intent.toml.in" > "$intent"
  ! grep -q '@[A-Z0-9_]*@' "$intent" || die "unfilled tokens in $intent: $(grep -o '@[A-Z0-9_]*@' "$intent" | sort -u | tr '\n' ' ')"
  echo "intent rendered: $intent (op-deployer $ver; L1 $DEVNET_L1_CHAIN_ID, L2 $DEVNET_L2_CHAIN_ID, owner $DEVNET_ADDR_DEPLOYER)"
  grep -E '^[[:space:]]*(configType|l1ChainID|l1ContractsLocator|id|gasLimit|eip1559[A-Za-z]*|faultGame[A-Za-z]*|preimageOracle[A-Za-z]*|proofMaturityDelaySeconds|disputeGameFinalityDelaySeconds|[a-zA-Z0-9]*Owner|SuperchainGuardian|Challenger|challenger|batcher|proposer|unsafeBlockSigner)[[:space:]]*=' "$intent"
}

cmd_deploy() {
  local bin work logf ver
  bin="$(op_deployer)"; work="$OUT/deploy"
  local want_cid
  want_cid="$(printf '0x%x' "$DEVNET_L1_CHAIN_ID")"
  [ "$(l1_rpc eth_chainId 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)" = "$want_cid" ] || die "no anvil with chain id $DEVNET_L1_CHAIN_ID on $L1_URL: devnet.sh l1 first"
  [ "$(l1_rpc eth_getCode "[\"$DET_DEPLOYER\",\"latest\"]" | jq -r .result)" = "$DET_DEPLOYER_CODE" ] || die "the deterministic deployer is not on this anvil: devnet.sh l1"
  cmd_intent >&2
  ver="$(grep -E '^[[:space:]]*opDeployerVersion' "$work/intent.toml" | sed -E 's/.*"([^"]*)".*/\1/')"
  logf="$OUT/logs/op-deployer-apply-$(date -u +%Y%m%dT%H%M%SZ).log"
  log "op-deployer apply (live, against the anvil) - a few minutes; log $logf"
  DEPLOYER_PRIVATE_KEY="$(owner_key)" "$bin" apply --l1-rpc-url "$L1_URL" --workdir "$work" --deployment-target live >"$logf" 2>&1 \
    || die "op-deployer apply failed; the last lines of $logf: $(tail -n 6 "$logf" | tr '\n' ' ' | cut -c1-600)"
  "$bin" inspect genesis --workdir "$work" "$DEVNET_L2_CHAIN_ID" > "$OUT/chain/genesis.json"
  "$bin" inspect rollup --workdir "$work" "$DEVNET_L2_CHAIN_ID" > "$OUT/chain/rollup.json"
  "$bin" inspect l1 --workdir "$work" "$DEVNET_L2_CHAIN_ID" > "$OUT/chain/l1-addresses.json"
  local A="$OUT/chain/l1-addresses.json" dgf k
  dgf="$(jq -r '.DisputeGameFactoryProxy // empty' "$A")"; [ -n "$dgf" ] || die "no DisputeGameFactoryProxy in $A (the inspect l1 layout differs from what this script knows)"
  for k in FaultDisputeGameImpl MipsImpl AnchorStateRegistryProxy DelayedWethPermissionlessGameProxy SuperchainConfigProxy PreimageOracleImpl OptimismPortalProxy SystemConfigProxy; do
    [ "$(jq -r --arg k "$k" '.[$k] // "0x0000000000000000000000000000000000000000"' "$A")" != "0x0000000000000000000000000000000000000000" ] || die "$k is missing or zero in $A"
  done
  jq -n --argjson cid "$DEVNET_L2_CHAIN_ID" --arg name "$DEVNET_CHAIN_NAME" --slurpfile r "$OUT/chain/rollup.json" --slurpfile a "$A" \
    --arg rsha "$(jq -cS . "$OUT/chain/rollup.json" | (sha256sum 2>/dev/null || shasum -a 256) | awk '{print $1}')" --arg ver "$ver" '
    $r[0] as $r | $a[0] as $a |
    {chainId: $cid, name: $name, environment: "local-devnet", opDeployerVersion: $ver,
     l2GenesisHash: $r.genesis.l2.hash, l1Anchor: {hash: $r.genesis.l1.hash, number: $r.genesis.l1.number}, rollupConfigSha256: $rsha,
     l1: {DisputeGameFactoryProxy: $a.DisputeGameFactoryProxy, OptimismPortalProxy: $a.OptimismPortalProxy, SystemConfigProxy: $a.SystemConfigProxy,
          AnchorStateRegistryProxy: $a.AnchorStateRegistryProxy, L1StandardBridgeProxy: $a.L1StandardBridgeProxy, PermissionedDisputeGame: $a.PermissionedDisputeGameImpl,
          FaultDisputeGameImpl: $a.FaultDisputeGameImpl, MipsImpl: $a.MipsImpl, PreimageOracleImpl: $a.PreimageOracleImpl,
          DelayedWethPermissionlessGameProxy: $a.DelayedWethPermissionlessGameProxy, SuperchainConfigProxy: $a.SuperchainConfigProxy}}' > "$OUT/chain/chain-record.json"
  set_gen DEVNET_DGF "$dgf"
  echo "deployed: factory $dgf, L2 genesis $(jq -r .l2GenesisHash "$OUT/chain/chain-record.json"), L1 anchor block $(jq -r .l1Anchor.number "$OUT/chain/chain-record.json")"
  echo "artifacts: $OUT/chain/{genesis,rollup,l1-addresses,chain-record}.json; intent and state: $work/"
  echo "forks at genesis: $(jq -r '[to_entries[] | select((.key | endswith("_time")) and .key != "block_time" and .value != null) | .key] | join(" ")' "$OUT/chain/rollup.json")"
}

###############################################################################################################
# the devnet chain through the K1/K2 scripts: the same code, this chain's files and registry identity
devnet_chain_env() {
  need_file "$OUT/chain/rollup.json" "no devnet artifacts yet: devnet.sh deploy"
  export ROLLUP="$OUT/chain/rollup.json" GENESIS="$OUT/chain/genesis.json" L1_ADDRESSES="$OUT/chain/l1-addresses.json"
  export KONA_SUPERCHAIN="$DEVNET_KONA_SUPERCHAIN" KONA_CHAIN_SLUG="$DEVNET_KONA_SLUG" KONA_CHAIN_NAME="$DEVNET_CHAIN_NAME"
  export L1_PUBLIC_RPC="http://anvil:8545" PUBLIC_RPC_URL="http://op-reth:8545" FAULT_PROOFS_STATUS=permissionless EXPLORER_URL=""
}
newest_record() { find "$FINCHAIN_ROOT/manifests/evidence" -maxdepth 1 -name "$1-$DEVNET_L2_CHAIN_ID-*.json" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-; }

cmd_build() {
  devnet_chain_env
  docker ps --format '{{.Names}}' | grep -q '^finchain-devnet-op-node-' \
    || warn "the L2 is not running: start it first (devnet.sh l2) so that the chain does not fall behind its sequencing window while the prestate builds"
  log "K1: registry files for chain $DEVNET_L2_CHAIN_ID ($DEVNET_KONA_SUPERCHAIN/$DEVNET_KONA_SLUG)"
  bash "$FINCHAIN_ROOT/drill/kona-configs.sh" "$ROLLUP" "$GENESIS"
  if [ "${KONA_CHECK:-0}" = 1 ]; then bash "$FINCHAIN_ROOT/drill/kona-check.sh" "$ROLLUP" "$GENESIS"; fi
  log "K2a: the devnet prestate (UPSTREAM_CHECK=0: the published prestate was reproduced for this tag in K2; the build reuses the caches)"
  UPSTREAM_CHECK=0 KONA_BUILD_JOBS="${KONA_BUILD_JOBS:-1}" bash "$FINCHAIN_ROOT/drill/prestate.sh" "$KONA_TAG" "$ROLLUP" "$GENESIS"
  local prec hash
  prec="$(newest_record prestate)"; [ -n "$prec" ] || die "no prestate record for chain $DEVNET_L2_CHAIN_ID under manifests/evidence/"
  hash="$(jq -r '.prestate.hash' "$prec")"
  [ -s "$FINCHAIN_ROOT/drill/out/prestates/$hash.bin.gz" ] || die "prestate file missing: drill/out/prestates/$hash.bin.gz"
  set_gen DEVNET_PRESTATE_HASH "$hash"; set_gen DEVNET_PRESTATE_FILE "$hash.bin.gz"; set_gen DEVNET_PRESTATE_RECORD "manifests/evidence/$(basename "$prec")"
  log "K2b host: kona-host with the devnet chain in its registry"
  KONA_TAG="$KONA_TAG" bash "$FINCHAIN_ROOT/drill/kona-host-build.sh"
  local hrec hbin
  hrec="$(newest_record kona-host)"; [ -n "$hrec" ] || die "no kona-host record for chain $DEVNET_L2_CHAIN_ID"
  hbin="$FINCHAIN_ROOT/$(jq -r '.binary.file' "$hrec")"
  [ -s "$hbin" ] || die "kona-host binary missing: $hbin"
  set_gen DEVNET_KONA_HOST_BIN "$hbin"; set_gen DEVNET_KONA_HOST_SHA256 "$(jq -r '.binary.sha256' "$hrec")"; set_gen DEVNET_KONA_HOST_RECORD "manifests/evidence/$(basename "$hrec")"
  cp "$FINCHAIN_ROOT/drill/kona-host-wrapper.sh" "$OUT/bin/kona-host-wrapper.sh"; chmod +x "$OUT/bin/kona-host-wrapper.sh" "$hbin"
  set_gen DEVNET_KONA_CONFIGS_RECORD "$( r="$(newest_record kona-configs)"; [ -z "$r" ] && echo "" || echo "manifests/evidence/$(basename "$r")")"
  echo "prestate $hash ($prec)"
  echo "kona-host $hbin ($hrec)"
}

###############################################################################################################
cmd_install_game() {
  need_file "$OUT/chain/l1-addresses.json" "no devnet artifacts yet: devnet.sh deploy"
  [ -n "${DEVNET_PRESTATE_HASH:-}" ] || die "no devnet prestate yet: devnet.sh build"
  # shellcheck disable=SC1091
  . "$OUT/keys/addresses.env"
  local A="$OUT/chain/l1-addresses.json" dgf fdg mips asr weth oracle key gt="$DEVNET_GAME_TYPE"
  dgf="$(jq -r .DisputeGameFactoryProxy "$A")"; fdg="$(jq -r .FaultDisputeGameImpl "$A")"; mips="$(jq -r .MipsImpl "$A")"
  asr="$(jq -r .AnchorStateRegistryProxy "$A")"; weth="$(jq -r .DelayedWethPermissionlessGameProxy "$A")"; oracle="$(jq -r .PreimageOracleImpl "$A")"
  key="$(owner_key)"
  # what the chain says about the pieces the game will be made of
  local owner sv cp fdgver maxd splitd ext dur
  owner="$(cast call "$dgf" 'owner()(address)' --rpc-url "$L1_URL" | tr -d '\r\n')"
  [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$DEVNET_ADDR_DEPLOYER" | tr '[:upper:]' '[:lower:]')" ] || die "the factory owner is $owner, not the devnet owner $DEVNET_ADDR_DEPLOYER"
  sv="$(cast call "$mips" 'stateVersion()(uint256)' --rpc-url "$L1_URL" | awk '{print $1}')"
  [ "$sv" = 8 ] || die "MIPS $mips implements state version $sv; the kona prestate is multithreaded64-5, state version 8"
  cp="$(cast call "$oracle" 'challengePeriod()(uint256)' --rpc-url "$L1_URL" | awk '{print $1}')"
  fdgver="$(cast call "$fdg" 'version()(string)' --rpc-url "$L1_URL" | tr -d '"\r\n')"
  maxd="$(cast call "$fdg" 'maxGameDepth()(uint256)' --rpc-url "$L1_URL" | awk '{print $1}')"; splitd="$(cast call "$fdg" 'splitDepth()(uint256)' --rpc-url "$L1_URL" | awk '{print $1}')"
  ext="$(cast call "$fdg" 'clockExtension()(uint64)' --rpc-url "$L1_URL" | awk '{print $1}')"; dur="$(cast call "$fdg" 'maxClockDuration()(uint64)' --rpc-url "$L1_URL" | awk '{print $1}')"
  [ "$maxd" = "$DEVNET_GAME_MAX_DEPTH" ] && [ "$splitd" = "$DEVNET_GAME_SPLIT_DEPTH" ] && [ "$ext" = "$DEVNET_GAME_CLOCK_EXTENSION" ] && [ "$dur" = "$DEVNET_GAME_MAX_CLOCK_DURATION" ] \
    || die "the deployed FaultDisputeGame has depths $maxd/$splitd and clocks $ext/$dur, not devnet.env's $DEVNET_GAME_MAX_DEPTH/$DEVNET_GAME_SPLIT_DEPTH, $DEVNET_GAME_CLOCK_EXTENSION/$DEVNET_GAME_MAX_CLOCK_DURATION"
  log "FaultDisputeGame $fdgver at $fdg: depths $maxd/$splitd, clocks ${ext}s/${dur}s; MIPS $mips state version $sv; oracle challenge period ${cp}s"

  # the game arguments the factory hands every type-8 game (gameargs.PackPermissionless: 124 bytes)
  local args anchor_before
  args="$(cast abi-encode --packed 'f(bytes32,address,address,address,uint256)' "$DEVNET_PRESTATE_HASH" "$mips" "$asr" "$weth" "$DEVNET_L2_CHAIN_ID" | tr -d '\r\n')"
  [ "${#args}" -eq $(( 2 + 124 * 2 )) ] || die "packed game args have ${#args} characters, expected $(( 2 + 124 * 2 ))"
  anchor_before="$(cast call "$asr" 'getAnchorRoot()(bytes32,uint256)' --rpc-url "$L1_URL" | tr '\n' ' ')"
  local tx1 tx2 tx3="" respected_before respected_after
  respected_before="$(cast call "$asr" 'respectedGameType()(uint32)' --rpc-url "$L1_URL" | awk '{print $1}')"
  log "setImplementation($gt, $fdg, args) with prestate $DEVNET_PRESTATE_HASH"
  tx1="$(cast send "$dgf" 'setImplementation(uint32,address,bytes)' "$gt" "$fdg" "$args" --private-key "$key" --rpc-url "$L1_URL" --json | jq -r .transactionHash)"
  tx2="$(cast send "$dgf" 'setInitBond(uint32,uint256)' "$gt" 0 --private-key "$key" --rpc-url "$L1_URL" --json | jq -r .transactionHash)"
  if [ "${DEVNET_GAME_RESPECTED:-0}" = 1 ]; then
    log "setRespectedGameType($gt) on the anchor state registry (the guardian)"
    tx3="$(cast send "$asr" 'setRespectedGameType(uint32)' "$gt" --private-key "$key" --rpc-url "$L1_URL" --json | jq -r .transactionHash)"
  fi
  respected_after="$(cast call "$asr" 'respectedGameType()(uint32)' --rpc-url "$L1_URL" | awk '{print $1}')"
  # read back
  local impl_set args_set
  impl_set="$(cast call "$dgf" 'gameImpls(uint32)(address)' "$gt" --rpc-url "$L1_URL" | tr -d '\r\n')"
  args_set="$(cast call "$dgf" 'gameArgs(uint32)(bytes)' "$gt" --rpc-url "$L1_URL" | tr -d '\r\n')"
  [ "$(printf '%s' "$impl_set" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$fdg" | tr '[:upper:]' '[:lower:]')" ] || die "gameImpls($gt) reads $impl_set, not $fdg"
  [ "$(printf '%s' "$args_set" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$args" | tr '[:upper:]' '[:lower:]')" ] || die "gameArgs($gt) reads back differently: $args_set"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson gt "$gt" --arg dgf "$dgf" --arg fdg "$fdg" --arg fdgver "$fdgver" --arg mips "$mips" --argjson sv "$sv" --arg asr "$asr" --arg weth "$weth" \
    --arg oracle "$oracle" --argjson cp "$cp" --arg pre "$DEVNET_PRESTATE_HASH" --arg args "$args" --argjson l2 "$DEVNET_L2_CHAIN_ID" --arg owner "$owner" \
    --arg tx1 "$tx1" --arg tx2 "$tx2" --arg tx3 "$tx3" --argjson rb "$respected_before" --argjson ra "$respected_after" --arg anchor "$anchor_before" \
    --argjson maxd "$maxd" --argjson splitd "$splitd" --argjson ext "$ext" --argjson dur "$dur" '
    {installedAt: $at, gameType: $gt, factory: $dgf, owner: $owner,
     implementation: {address: $fdg, version: $fdgver, maxGameDepth: $maxd, splitDepth: $splitd, clockExtension: $ext, maxClockDuration: $dur,
                      note: "the shared FaultDisputeGame implementation of the chain; the game type is defined by the arguments the factory stores for it"},
     gameArgs: {packed: $args, layout: "absolutePrestate(32) vm(20) anchorStateRegistry(20) weth(20) l2ChainId(32) - op-challenger gameargs.PackPermissionless",
                absolutePrestate: $pre, vm: {address: $mips, stateVersion: $sv}, anchorStateRegistry: $asr, weth: $weth, l2ChainId: $l2},
     preimageOracle: {address: $oracle, challengePeriod: $cp},
     transactions: {setImplementation: $tx1, setInitBond: $tx2, setRespectedGameType: (if $tx3 == "" then null else $tx3 end)},
     respectedGameType: {before: $rb, after: $ra}, anchorRootBefore: $anchor}' > "$OUT/chain/game-type-$gt.json"
  echo "game type $gt installed on $dgf: impl $fdg, prestate $DEVNET_PRESTATE_HASH, respected type $respected_before -> $respected_after"
  echo "record: $OUT/chain/game-type-$gt.json"
}

###############################################################################################################
cmd_l2() {
  need_file "$OUT/chain/genesis.json" "no devnet artifacts yet: devnet.sh deploy"
  need_file "$OUT/secrets/jwt.txt" "no devnet secrets yet: devnet.sh keys"
  compose --profile l2 up -d
  local i st safe unsafe
  log "waiting for op-node (sequencing from the L2 genesis; the first safe block needs a batch on L1)"
  for i in $(seq 1 120); do
    st="$(rpc "$NODE_URL" optimism_syncStatus 2>/dev/null || true)"
    unsafe="$(jq -r '.result.unsafe_l2.number // empty' <<<"$st" 2>/dev/null || true)"; safe="$(jq -r '.result.safe_l2.number // empty' <<<"$st" 2>/dev/null || true)"
    [ -n "$safe" ] && [ "$safe" -gt 0 ] && break
    sleep 5
  done
  [ -n "${safe:-}" ] || die "op-node gives no sync status on $NODE_URL (docker compose -p finchain-devnet logs op-node)"
  echo "L2 up: unsafe head $unsafe, safe head $safe (op-reth $L1_URL -> ${DEVNET_L2_PORT}, op-node $NODE_URL)"
  [ "$safe" -gt 0 ] || warn "no safe block yet after 10 minutes; check the batcher: docker compose -p finchain-devnet logs op-batcher"
}

###############################################################################################################
list_games() { challenger_cli list-games --l1-eth-rpc http://anvil:8545 --game-factory-address "${DEVNET_DGF:?}" --format json 2>/dev/null; }
cmd_proof() {
  [ -n "${DEVNET_DGF:-}" ] || die "no factory address yet: devnet.sh deploy"
  [ -n "${DEVNET_PRESTATE_FILE:-}" ] && [ -n "${DEVNET_KONA_HOST_BIN:-}" ] || die "no devnet prestate or kona-host yet: devnet.sh build"
  [ -s "$OUT/chain/game-type-$DEVNET_GAME_TYPE.json" ] || die "game type $DEVNET_GAME_TYPE is not installed yet: devnet.sh install-game"
  [ -x "$OUT/bin/kona-host-wrapper.sh" ] || { cp "$FINCHAIN_ROOT/drill/kona-host-wrapper.sh" "$OUT/bin/kona-host-wrapper.sh"; chmod +x "$OUT/bin/kona-host-wrapper.sh"; }
  compose --profile proof up -d
  log "waiting for the first type-$DEVNET_GAME_TYPE game (proposal interval $DEVNET_PROPOSAL_INTERVAL; the proposer waits for a finalized L2 block)"
  local i games n
  for i in $(seq 1 60); do
    games="$(list_games || echo '{"games":[]}')"
    n="$(jq -r --argjson gt "$DEVNET_GAME_TYPE" '[.games[] | select(.gameType == $gt)] | length' <<<"$games" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] && break
    sleep 10
  done
  if [ "${n:-0}" -gt 0 ]; then
    echo "proof services up; $n game(s) of type $DEVNET_GAME_TYPE so far:"
    jq -r --argjson gt "$DEVNET_GAME_TYPE" '.games[] | select(.gameType == $gt) | "  #\(.index) \(.game) L2 block \(.l2BlockNumber) \(.status) claims \(.claimCount) \(.created)"' <<<"$games"
  else
    warn "no type-$DEVNET_GAME_TYPE game after 10 minutes; check: docker compose -p finchain-devnet logs op-proposer"
  fi
  local root
  root="$(anchor_root | cut -d' ' -f1)"
  if [ "$root" = "$DEAD_ROOT" ]; then
    echo "anchor root: op-deployer's placeholder $DEAD_ROOT - games created now start from it and the honest challenger refuses them ('output root absolute prestate does not match'); devnet.sh anchor moves it (the first game's clock, ${DEVNET_GAME_MAX_CLOCK_DURATION}s, plus the finality delay)"
  else
    echo "anchor root: $(anchor_root)"
  fi
}
anchor_root() { cast call "$(jq -r .AnchorStateRegistryProxy "$OUT/chain/l1-addresses.json")" 'getAnchorRoot()(bytes32,uint256)' --rpc-url "$L1_URL" | tr '\n' ' ' | sed 's/ *$//'; }

###############################################################################################################
# The anchor root. op-deployer deploys the chain with a placeholder anchor (0xdead..., L2 block 0), because the L2
# genesis is generated after the L1 contracts. Every game starts its output bisection at the anchor, so a game created
# before the anchor has moved carries the placeholder as its starting root; the honest challenger compares that with
# the real output root at that block, finds them different and refuses to play the game (op-challenger validates
# permissionless games this way, permissioned ones not at all). The anchor moves when a respected game resolves in
# favour of its root, waits out the finality delay and is closed: closeGame() calls setAnchorState(). Nobody tracks
# the placeholder games (the challenger declined them), so the first type-8 game is resolved and closed here, by hand,
# once its clock has run out. The same holds for the public chain: a Type 8 game there can only be played once the
# anchor has moved off the placeholder (the first closeGame of the permissioned type).
cmd_anchor() {
  [ -n "${DEVNET_DGF:-}" ] || die "no factory address yet: devnet.sh deploy"
  local asr before root blk games ginfo game idx created l2blk rootclaim expires now left st key tx1 tx2 tx3 resolved_at after
  asr="$(jq -r .AnchorStateRegistryProxy "$OUT/chain/l1-addresses.json")"
  before="$(anchor_root)"; root="${before%% *}"; blk="${before##* }"
  if [ "$root" != "$DEAD_ROOT" ]; then echo "the anchor root is already $root at L2 block $blk; nothing to do"; return 0; fi
  games="$(list_games)" || die "list-games failed (is the L1 up?)"
  ginfo="$(jq -c --argjson gt "$DEVNET_GAME_TYPE" '[.games[] | select(.gameType == $gt)] | sort_by(.index) | first // empty' <<<"$games")"
  [ -n "$ginfo" ] || die "no type-$DEVNET_GAME_TYPE game yet: devnet.sh proof"
  game="$(jq -r .game <<<"$ginfo")"; idx="$(jq -r .index <<<"$ginfo")"; created="$(jq -r .timestamp <<<"$ginfo")"; l2blk="$(jq -r .l2BlockNumber <<<"$ginfo")"; rootclaim="$(jq -r .outputRoot <<<"$ginfo")"
  [ "$(cast call "$game" 'wasRespectedGameTypeWhenCreated()(bool)' --rpc-url "$L1_URL" | tr -d '\r\n')" = true ] || die "game #$idx was not of the respected type when created; it cannot move the anchor"
  expires=$(( created + DEVNET_GAME_MAX_CLOCK_DURATION ))
  log "bootstrap game #$idx $game: L2 block $l2blk, root $rootclaim, created $(date -u -d "@$created" +%H:%M:%SZ); its clock runs out at $(date -u -d "@$expires" +%H:%M:%SZ) UTC, the anchor moves ${DEVNET_GAME_FINALITY_DELAY}s after the resolution"
  while :; do
    now="$(date +%s)"; left=$(( expires + 6 - now ))
    [ "$left" -gt 0 ] || break
    if [ $(( left % 300 )) -lt 60 ]; then log "waiting for the clock: $(( left / 60 )) min left"; fi
    sleep 60
  done
  key="$(owner_key)"
  st="$(cast call "$game" 'status()(uint8)' --rpc-url "$L1_URL" | awk '{print $1}')"
  tx1=""; tx2=""
  if [ "$st" = 0 ]; then
    log "resolving game #$idx (resolveClaim(0, 0), then resolve())"
    tx1="$(cast send "$game" 'resolveClaim(uint256,uint256)' 0 0 --private-key "$key" --rpc-url "$L1_URL" --json | jq -r .transactionHash)"
    tx2="$(cast send "$game" 'resolve()' --private-key "$key" --rpc-url "$L1_URL" --json | jq -r .transactionHash)"
    st="$(cast call "$game" 'status()(uint8)' --rpc-url "$L1_URL" | awk '{print $1}')"
  fi
  [ "$st" = 2 ] || die "game #$idx has status $st after resolution, not DEFENDER_WINS (2)"
  resolved_at="$(cast call "$game" 'resolvedAt()(uint64)' --rpc-url "$L1_URL" | awk '{print $1}')"
  log "resolved DEFENDER_WINS at $(date -u -d "@$resolved_at" +%H:%M:%SZ) UTC; waiting out the finality delay (${DEVNET_GAME_FINALITY_DELAY}s)"
  while [ "$(cast call "$asr" 'isGameFinalized(address)(bool)' "$game" --rpc-url "$L1_URL" | tr -d '\r\n')" != true ]; do sleep 15; done
  log "closing game #$idx (closeGame() -> setAnchorState)"
  tx3="$(cast send "$game" 'closeGame()' --private-key "$key" --rpc-url "$L1_URL" --json | jq -r .transactionHash)"
  after="$(anchor_root)"
  [ "$(printf '%s' "${after%% *}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$rootclaim" | tr '[:upper:]' '[:lower:]')" ] && [ "${after##* }" = "$l2blk" ] \
    || die "the anchor root did not move to game #$idx: before '$before', after '$after'"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson g "$ginfo" --arg game "$game" --argjson created "$created" --argjson resolved "$resolved_at" \
    --arg tx1 "$tx1" --arg tx2 "$tx2" --arg tx3 "$tx3" --arg before "$before" --arg after "$after" --arg by "$DEVNET_ADDR_DEPLOYER" '
    {movedAt: $at, bootstrapGame: ($g + {address: $game}), createdAt: $created, resolvedAt: $resolved,
     transactions: {resolveClaim: (if $tx1 == "" then null else $tx1 end), resolve: (if $tx2 == "" then null else $tx2 end), closeGame: $tx3}, sentBy: $by,
     anchorRootBefore: $before, anchorRootAfter: $after,
     why: "op-deployer deploys the chain with the placeholder anchor 0xdead... at L2 block 0; a game created before the anchor moved starts from it and the honest challenger refuses it; the anchor moves when a respected game is finalized and closed (closeGame -> setAnchorState)"}' > "$OUT/chain/anchor.json"
  echo "anchor root moved: $before -> $after (game #$idx closed, tx $tx3)"
  echo "record: $OUT/chain/anchor.json"
  echo "the games created before this moment keep the placeholder as their starting root and stay untracked; the dispute uses a game the proposer creates from now on"
}

###############################################################################################################
cmd_run_trace() {
  [ -n "${DEVNET_PRESTATE_FILE:-}" ] || die "no devnet prestate yet: devnet.sh build"
  CHAIN_OUT="$OUT/chain" L1_RPC_URL=http://rpc-shim:8550 L1_BEACON_URL=http://rpc-shim:8550 ROLLUP_RPC=http://op-node:8547 L2_RPC_DEBUG=http://op-reth:8545 \
    DRILL_NETWORK="$NETWORK" KONA_CHAIN_SLUG="$DEVNET_KONA_SLUG" KONA_TAG="$KONA_TAG" ENVIRONMENT=local-devnet \
    bash "$FINCHAIN_ROOT/drill/run-trace.sh" "$FINCHAIN_ROOT/drill/out/prestates/$DEVNET_PRESTATE_FILE" b
}

###############################################################################################################
cmd_dispute() { bash "$DEVNET_DIR/adversary.sh" dispute; }
cmd_resolve() { bash "$DEVNET_DIR/adversary.sh" resolve; }

###############################################################################################################
cmd_status() {
  compose ps 2>/dev/null || true
  local head st
  head="$(l1_rpc eth_blockNumber 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)"
  if [ -z "$head" ]; then echo "L1: not running"; else echo "L1: head $(hexdec "$head"), chain id $(hexdec "$(l1_rpc eth_chainId | jq -r .result)")"; fi
  st="$(rpc "$NODE_URL" optimism_syncStatus 2>/dev/null || true)"
  if [ -z "$st" ]; then echo "L2: op-node not running"
  else jq -r '.result | "L2: unsafe \(.unsafe_l2.number) safe \(.safe_l2.number) finalized \(.finalized_l2.number); L1 head seen \(.head_l1.number) finalized \(.finalized_l1.number)"' <<<"$st"; fi
  if [ -n "${DEVNET_DGF:-}" ] && [ -n "$head" ]; then
    echo "games (factory $DEVNET_DGF):"
    list_games | jq -r '.games[] | "  #\(.index) \(.game) type \(.gameType) L2 block \(.l2BlockNumber) \(.status) claims \(.claimCount) \(.created)"' 2>/dev/null || echo "  (list-games failed)"
  fi
}

###############################################################################################################
cmd_down() {
  compose --profile l1 --profile l2 --profile proof down -v --remove-orphans 2>/dev/null || compose down -v --remove-orphans || true
  if [ "${FRESH:-0}" = 1 ]; then rm -rf "$OUT"; echo "devnet stopped; $OUT deleted (the prestates and kona-host binaries under drill/out/ are kept)"; else echo "devnet stopped and its volumes deleted; $OUT kept (FRESH=1 deletes it)"; fi
}

###############################################################################################################
case "${1:-}" in
  keys) cmd_keys ;;
  l1) cmd_l1 ;;
  intent) cmd_intent ;;
  deploy) cmd_deploy ;;
  build) cmd_build ;;
  install-game) cmd_install_game ;;
  l2) cmd_l2 ;;
  proof) cmd_proof ;;
  anchor) cmd_anchor ;;
  run-trace) cmd_run_trace ;;
  dispute) cmd_dispute ;;
  resolve) cmd_resolve ;;
  status) cmd_status ;;
  down) cmd_down ;;
  *) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
