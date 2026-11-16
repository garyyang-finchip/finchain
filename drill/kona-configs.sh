#!/usr/bin/env bash
# K1: Finchain's chain configuration in the form the kona-client registry embeds (docs/proof-plan.md, K1).
#
# kona-client looks the L2 chain up by chain id in the registry compiled into it (crate kona-registry), and
# that registry can be extended at build time with KONA_CUSTOM_CONFIGS_DIR: a directory holding chainList.json,
# configs.json and (optionally) depsets.json in the superchain-registry format of the crate's etc/ files. This
# script writes those three files for one chain from op-node's rollup.json and the L2 genesis.json:
#   chainList.json  - one Chain entry (name, identifier <superchain>/<slug>, chain id, parent L1);
#   configs.json    - one Superchain entry holding one ChainConfig. By default the superchain is the one of the L1
#                     (sepolia or mainnet), so the registry keeps its own superchain config and appends the chain;
#                     KONA_SUPERCHAIN names a superchain of its own instead (the devnet of K3), which the merge
#                     inserts whole, with this chain's SuperchainConfig address and L1 endpoint;
#   depsets.json    - the self-only dependency set the registry gives every non-interop chain.
# Field names and the set of fields follow kona-genesis at the pinned tag (ChainConfig, ChainGenesis,
# HardForkConfig and Roles reject unknown fields). The op-node genesis block (l1, l2, l2_time, system_config)
# and the EIP-1559 parameters are copied verbatim: kona-genesis deserialises op-node's own encodings.
#
# Usage: drill/kona-configs.sh [ROLLUP] [GENESIS] [OUTDIR]
#   defaults: <chain dir>/out/rollup.json, <chain dir>/out/genesis.json, drill/work/kona-configs-<chainId>
#   KONA_CHAIN_NAME  display name (default: name in <chain dir>/out/chain-record.json, else "Finchain")
#   KONA_CHAIN_SLUG  identifier slug (default finchain): the identifier is <superchain>/<slug>
#   KONA_SUPERCHAIN  a superchain of this chain's own (lowercase letters, digits, dashes; must not be a registry
#                    superchain: mainnet, sepolia, sepolia-devnet-*). Its L1 is rollup.json's l1_chain_id, which must
#                    be one kona-client carries an L1 configuration for (1, 11155111, 17000: kona-registry l1/mod.rs;
#                    any other L1 makes the client fall back to an oracle-supplied L1 configuration).
#   L1_PUBLIC_RPC, L1_EXPLORER  the L1 endpoint and explorer written into that superchain entry (devnet: the anvil URL)
#   EXPLORER_URL     explorer of the L2 (default: none)
#   FAULT_PROOFS_STATUS  none | permissioned | permissionless (default permissioned, the testnet's state)
#   L1_ADDRESSES     op-deployer's L1 address file (default <chain dir>/out/l1-addresses.json; optional)
# No key, no chain access; jq only.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require_cmd jq

ROLLUP="${1:-${ROLLUP:-$CHAIN_DIR/out/rollup.json}}"
GENESIS="${2:-${GENESIS:-$CHAIN_DIR/out/genesis.json}}"
[ -f "$ROLLUP" ] || die "rollup config not found: $ROLLUP"
[ -f "$GENESIS" ] || die "L2 genesis not found: $GENESIS"
chain_id="$(jq -r '.l2_chain_id' "$ROLLUP")"
[ "$(jq -r '.config.chainId' "$GENESIS")" = "$chain_id" ] || die "chain id differs between $ROLLUP ($chain_id) and $GENESIS"
OUTDIR="${3:-${OUTDIR:-$FINCHAIN_ROOT/drill/work/kona-configs-$chain_id}}"
L1_ADDRESSES="${L1_ADDRESSES:-$CHAIN_DIR/out/l1-addresses.json}"
SLUG="${KONA_CHAIN_SLUG:-finchain}"
case "$SLUG" in *[!a-z0-9-]*|"") die "KONA_CHAIN_SLUG must be lowercase letters, digits and dashes: $SLUG" ;; esac

l1_chain_id="$(jq -r '.l1_chain_id' "$ROLLUP")"
own_superchain="${KONA_SUPERCHAIN:-}"
if [ -n "$own_superchain" ]; then
  case "$own_superchain" in *[!a-z0-9-]*) die "KONA_SUPERCHAIN must be lowercase letters, digits and dashes: $own_superchain" ;; esac
  case "$own_superchain" in mainnet|sepolia|sepolia-devnet-*) die "KONA_SUPERCHAIN $own_superchain is a superchain of the registry itself; leave KONA_SUPERCHAIN unset to append the chain to it" ;; esac
  # kona-client holds an L1 configuration for these three L1s only (kona-registry l1/mod.rs); for any other L1 chain
  # id the client would fall back to an oracle-supplied L1 configuration, the path the embedding exists to avoid
  case "$l1_chain_id" in 1|11155111|17000) ;; *) die "L1 chain id $l1_chain_id: kona-client embeds no L1 configuration for it (only 1, 11155111 and 17000); the devnet L1 must present one of these" ;; esac
  [ -n "${L1_PUBLIC_RPC:-}" ] || die "L1_PUBLIC_RPC (the L1 endpoint of the $own_superchain superchain) must be set with KONA_SUPERCHAIN"
  superchain="$own_superchain"; l1_rpc="$L1_PUBLIC_RPC"; l1_explorer="${L1_EXPLORER:-}"
else
  case "$l1_chain_id" in
    11155111) superchain=sepolia; l1_rpc=https://ethereum-sepolia-rpc.publicnode.com; l1_explorer=https://sepolia.etherscan.io ;;
    1) superchain=mainnet; l1_rpc=https://ethereum-rpc.publicnode.com; l1_explorer=https://etherscan.io ;;
    *) die "L1 chain id $l1_chain_id is neither Sepolia nor mainnet; set KONA_SUPERCHAIN (and L1_PUBLIC_RPC) to describe its superchain" ;;
  esac
fi

name="${KONA_CHAIN_NAME:-}"
if [ -z "$name" ] && [ -f "$CHAIN_DIR/out/chain-record.json" ]; then name="$(jq -r '.name // empty' "$CHAIN_DIR/out/chain-record.json")"; fi
name="${name:-Finchain}"
l2_rpc="$(public_rpc)"
explorer="${EXPLORER_URL:-}"
fp_status="${FAULT_PROOFS_STATUS:-permissioned}"
case "$fp_status" in none|permissioned|permissionless) ;; *) die "FAULT_PROOFS_STATUS must be none, permissioned or permissionless" ;; esac

# Hardforks: the keys kona-genesis HardForkConfig knows at kona-client/v1.9.0. A fork scheduled in rollup.json
# that is not in this list has no counterpart in the client and the conversion stops rather than drop it.
known_forks='["regolith_time","canyon_time","delta_time","ecotone_time","fjord_time","granite_time","holocene_time","pectra_blob_schedule_time","isthmus_time","jovian_time","karst_time","lagoon_time"]'
unknown="$(jq -r --argjson known "$known_forks" '[to_entries[] | select((.key | endswith("_time")) and .key != "block_time" and .value != null) | .key] - $known | .[]' "$ROLLUP")"
[ -z "$unknown" ] || die "rollup.json schedules forks the pinned kona-client does not model: $(printf '%s ' "$unknown")"

# EIP-1559 parameters: rollup.json chain_op_config, which must agree with genesis.json config.optimism
op_cfg="$(jq -c '.chain_op_config // empty' "$ROLLUP")"
gen_op="$(jq -c '.config.optimism // empty' "$GENESIS")"
[ -n "$op_cfg" ] || op_cfg="$gen_op"
[ -n "$op_cfg" ] || die "neither rollup.json chain_op_config nor genesis.json config.optimism carries the EIP-1559 parameters"
if [ -n "$gen_op" ] && [ "$(jq -cS . <<<"$op_cfg")" != "$(jq -cS . <<<"$gen_op")" ]; then
  die "EIP-1559 parameters differ: rollup.json $op_cfg, genesis.json $gen_op"
fi

portal="$(jq -r '.deposit_contract_address' "$ROLLUP")"; sysconfig="$(jq -r '.l1_system_config_address' "$ROLLUP")"
addresses="$(jq -cn --arg p "$portal" --arg s "$sysconfig" '{OptimismPortalProxy: $p, SystemConfigProxy: $s}')"
superchain_config_addr=null
if [ -f "$L1_ADDRESSES" ]; then
  # the two addresses the client derives from must match rollup.json; the rest is informational
  for pair in OptimismPortalProxy:"$portal" SystemConfigProxy:"$sysconfig"; do
    k="${pair%%:*}"; want="${pair#*:}"; have="$(jq -r --arg k "$k" '.[$k] // empty' "$L1_ADDRESSES" | tr 'A-F' 'a-f')"
    [ -z "$have" ] || [ "$have" = "$(printf '%s' "$want" | tr 'A-F' 'a-f')" ] || die "$k differs: rollup.json $want, $L1_ADDRESSES $have"
  done
  addresses="$(jq -c --argjson base "$addresses" '
    def nz: if . == null or . == "0x0000000000000000000000000000000000000000" then null else . end;
    $base + ({L1CrossDomainMessengerProxy: (.L1CrossDomainMessengerProxy | nz),
              L1Erc721BridgeProxy: (.L1Erc721BridgeProxy | nz),
              L1StandardBridgeProxy: (.L1StandardBridgeProxy | nz),
              L2OutputOracleProxy: (.L2OutputOracleProxy | nz),
              OptimismMintableErc20FactoryProxy: (.OptimismMintableErc20FactoryProxy | nz),
              SuperchainConfig: (.SuperchainConfigProxy | nz),
              AnchorStateRegistryProxy: (.AnchorStateRegistryProxy | nz),
              DelayedWethProxy: (.DelayedWethPermissionlessGameProxy // .DelayedWethPermissionedGameProxy | nz),
              DisputeGameFactoryProxy: (.DisputeGameFactoryProxy | nz),
              FaultDisputeGame: (.FaultDisputeGameImpl | nz),
              Mips: (.MipsImpl | nz),
              PermissionedDisputeGame: (.PermissionedDisputeGameImpl | nz),
              PreimageOracle: (.PreimageOracleImpl | nz),
              DataAvailabilityChallenge: (.AltDAChallengeProxy | nz)} | with_entries(select(.value != null)))' "$L1_ADDRESSES")"
  superchain_config_addr="$(jq -c '.SuperchainConfigProxy // null | if . == "0x0000000000000000000000000000000000000000" then null else . end' "$L1_ADDRESSES")"
fi

mkdir -p "$OUTDIR"
jq -n --arg name "$name" --arg ident "$superchain/$SLUG" --argjson cid "$chain_id" --arg rpc "$l2_rpc" --arg explorer "$explorer" \
      --arg sc "$superchain" --arg fp "$fp_status" '
  [{name: $name, identifier: $ident, chainId: $cid, rpc: [$rpc], explorers: (if $explorer == "" then [] else [$explorer] end),
    governedByOptimism: false, dataAvailabilityType: "eth-da", parent: {type: "L2", chain: $sc}, faultProofs: {status: $fp}}]' \
  > "$OUTDIR/chainList.json"

jq -n --slurpfile r "$ROLLUP" --arg name "$name" --arg rpc "$l2_rpc" --arg explorer "$explorer" --argjson known "$known_forks" \
      --argjson op "$op_cfg" --argjson addrs "$addresses" --arg sc "$superchain" --argjson l1id "$l1_chain_id" \
      --arg l1rpc "$l1_rpc" --arg l1exp "$l1_explorer" --argjson scaddr "$superchain_config_addr" '
  $r[0] as $r |
  {superchains: [{
     name: $sc,
     config: {name: (($sc | .[0:1] | ascii_upcase) + ($sc | .[1:])), l1: {chain_id: $l1id, public_rpc: $l1rpc, explorer: $l1exp},
              hardforks: {}, superchain_config_addr: $scaddr, op_contracts_manager_proxy_addr: null},
     chains: [{
       Name: $name, PublicRPC: $rpc, SequencerRPC: $rpc, Explorer: $explorer,
       GovernedByOptimism: false, SuperchainTime: null, DataAvailabilityType: "eth-da",
       l2_chain_id: $r.l2_chain_id, batch_inbox_address: $r.batch_inbox_address,
       block_time: $r.block_time, seq_window_size: $r.seq_window_size, max_sequencer_drift: $r.max_sequencer_drift,
       GasPayingToken: null,
       hardfork_configuration: ($r | with_entries(select((.key | IN($known[])) and .value != null))),
       optimism: $op,
       alt_da: ($r.alt_da // null),
       genesis: $r.genesis,
       Roles: {BatchSubmitter: $r.genesis.system_config.batcherAddr},
       Addresses: $addrs
     }]}]}' > "$OUTDIR/configs.json"

jq -n --argjson cid "$chain_id" '[{dependencies: {($cid | tostring): {}}, overrideMessageExpiryWindow: null}]' > "$OUTDIR/depsets.json"

echo "kona custom configs for chain $chain_id ($superchain/$SLUG, \"$name\") in $OUTDIR"
for f in chainList.json configs.json depsets.json; do echo "  $f  sha256 $(sha256_of "$OUTDIR/$f")"; done
if [ -n "$own_superchain" ]; then
  echo "note: $superchain is a superchain of its own; the merge inserts it whole (L1 chain id $l1_chain_id, L1 endpoint $(rpc_label "$l1_rpc"), SuperchainConfig $(jq -r . <<<"$superchain_config_addr"))"
else
  echo "note: the $superchain superchain exists in the registry, so the merge keeps the registry's own superchain config (L1 chain id, SuperchainConfig address) and appends this chain"
fi
