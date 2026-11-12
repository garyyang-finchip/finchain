#!/usr/bin/env bash
# Deploy the ERC-8004 reference registries on Finchain: the identity root the covenant World binds to.
#
# Usage: scripts/deploy-8004.sh [l2-rpc]        (default https://rpc.finchain.one)
#   env: WITH_REPUTATION=1 (default 1; 0 deploys the Identity Registry alone)
#        YES=1 (no confirmation prompt), FORCE=1 (ignore an existing chain/out/erc8004.json)
#
# What it does (docs/world.md, "Identity root"):
#   1. deploys the placeholder HardhatMinimalUUPS and one ERC1967Proxy per registry whose initialize()
#      makes the deployer the owner (upstream's vanity flow hard-codes its own owner; this is the
#      upstream test placeholder, source unchanged);
#   2. deploys IdentityRegistryUpgradeable (and ReputationRegistryUpgradeable) and upgrades each proxy
#      to it with upgradeToAndCall(impl, initialize(...)) - the reinitializer the upstream flow uses;
#   3. verifies: implementation slot, getVersion, name/symbol, EIP-712 domain, getIdentityRegistry,
#      runtime code hashes against chain/contracts/erc8004/build.json, a simulated register();
#   4. transfers ownership of both proxies to OWNER_ADDRESS (the upgrade controller from then on);
#   5. writes chain/out/erc8004.json (addresses, transactions, blocks, code hashes, checks).
#
# Build provenance: chain/contracts/erc8004/ (upstream commit, solc 0.8.24 shanghai/200/via-IR,
# OpenZeppelin 5.4.0; scripts/build-8004.sh rebuilds and compares). The deployer is the chain
# operations key (keys/deployer.json); the registries are chain-level infrastructure, not part of
# the World that FOGA's W deploys.

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq curl awk
load_standard_env
[ -n "${CAST_BIN:-}" ] || require_cmd docker

L2_RPC="${1:-https://rpc.finchain.one}"
WITH_REPUTATION="${WITH_REPUTATION:-1}"
BUILD="$FINCHAIN_ROOT/chain/contracts/erc8004/build.json"
OUT="$FINCHAIN_ROOT/chain/out/erc8004.json"
[ -f "$BUILD" ] || die "build record missing: $BUILD"
[ -n "${OWNER_ADDRESS:-}" ] || die "OWNER_ADDRESS is empty in .env (the final owner of the registries)"
if [ -f "$OUT" ] && [ "${FORCE:-0}" != "1" ]; then
  die "$OUT exists (identity root already deployed: $(jq -r '.contracts.IdentityRegistry.proxy' "$OUT")); FORCE=1 to deploy a second set"
fi

IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
deployer="$(key_field deployer address)"
pk="$(key_field deployer private_key)"
chain_hex="$(rpc "$L2_RPC" eth_chainId | jq -r .result)"
[ "$((chain_hex))" = "${CHAIN_ID:?}" ] || die "L2 RPC $L2_RPC reports chain id $((chain_hex)), .env says $CHAIN_ID"
bal_eth="$(hex_to_eth "$(rpc "$L2_RPC" eth_getBalance "[\"$deployer\",\"latest\"]" | jq -r .result)")"
echo "L2 RPC:    $L2_RPC (chain id $((chain_hex)))"
echo "deployer:  $deployer ($bal_eth ETH on L2)"
echo "owner:     $OWNER_ADDRESS (receives ownership at the end)"
echo "upstream:  $(jq -r '.upstream.repository' "$BUILD") @ $(jq -r '.upstream.commit' "$BUILD")"
echo "compiler:  $(jq -r '.contracts.IdentityRegistryUpgradeable.compilerLongVersion' "$BUILD"), via-IR, shanghai, 200 runs"
echo "contracts: IdentityRegistry$([ "$WITH_REPUTATION" = "1" ] && echo ' + ReputationRegistry') (proxy + implementation each) and one placeholder"
awk -v b="$bal_eth" 'BEGIN { exit !(b > 0.001) }' || die "deployer holds $bal_eth ETH on L2; deposit first (make deposit)"
if [ "${YES:-0}" != "1" ]; then
  read -r -p "Deploy the ERC-8004 identity root on this chain now? [yes/NO] " answer
  [ "$answer" = "yes" ] || die "aborted; nothing was sent"
fi

bytecode() { jq -r ".contracts.$1.creationBytecode" "$BUILD"; }
runtime_keccak() { jq -r ".contracts.$1.runtimeBytecodeKeccak" "$BUILD"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
rfield() { printf '%s' "$1" | jq -r ".$2"; }
code_keccak() { cast keccak "$(rpc "$L2_RPC" eth_getCode "[\"$1\",\"latest\"]" | jq -r .result)"; }
# identity_keccak <address> <contract>: keccak of the on-chain code with the contract's immutable slots
# (UUPSUpgradeable's __self, set at construction) zeroed, so it compares with the compiled runtime code.
identity_keccak() {
  local code refs
  code="$(rpc "$L2_RPC" eth_getCode "[\"$1\",\"latest\"]" | jq -r .result)"
  refs="$(jq -c ".contracts.$2.immutableReferences // []" "$BUILD")"
  cast keccak "$(jq -rn --arg c "$code" --argjson refs "$refs" '
    reduce $refs[] as $r ($c; .[0:2 + 2 * $r.start] + ("0" * (2 * $r.length)) + .[2 + 2 * ($r.start + $r.length):])')"
}

# send_create <creation-bytecode-with-args> -> receipt JSON (status checked)
send_create() {
  local r
  r="$(cast send --rpc-url "$L2_RPC" --private-key "$pk" --json --create "$1")" || die "deployment transaction failed"
  [ "$(rfield "$r" status)" = "0x1" ] || die "deployment reverted: $(rfield "$r" transactionHash)"
  printf '%s' "$r"
}
# send_call <to> <calldata> -> receipt JSON (status checked)
send_call() {
  local r
  r="$(cast send --rpc-url "$L2_RPC" --private-key "$pk" --json "$1" "$2")" || die "transaction to $1 failed"
  [ "$(rfield "$r" status)" = "0x1" ] || die "transaction reverted: $(rfield "$r" transactionHash)"
  printf '%s' "$r"
}
CHECK_ROWS=""; FAILED=0
check() { # <name> <actual> <expected>
  if [ "$(lower "$2")" = "$(lower "$3")" ]; then
    echo "  ok   $1 = $2"; CHECK_ROWS="$CHECK_ROWS$1	pass	$2	$3
"
  else
    echo "  FAIL $1 = $2 (expected $3)"; CHECK_ROWS="$CHECK_ROWS$1	fail	$2	$3
"; FAILED=1
  fi
}

log "1/5 placeholder implementation (HardhatMinimalUUPS)"
r_ph="$(send_create "$(bytecode HardhatMinimalUUPS)")"; placeholder="$(rfield "$r_ph" contractAddress)"
echo "  placeholder $placeholder (tx $(rfield "$r_ph" transactionHash), block $(( $(rfield "$r_ph" blockNumber) )))"

log "2/5 proxies (owner = deployer until the final transfer)"
init_ph_identity="$(cast calldata 'initialize(address)' 0x0000000000000000000000000000000000000000)"
args_identity="$(cast abi-encode 'f(address,bytes)' "$placeholder" "$init_ph_identity")"
r_ip="$(send_create "$(bytecode ERC1967Proxy)${args_identity#0x}")"; identity_proxy="$(rfield "$r_ip" contractAddress)"
echo "  IdentityRegistry proxy $identity_proxy (tx $(rfield "$r_ip" transactionHash))"
reputation_proxy=""; r_rp=""
if [ "$WITH_REPUTATION" = "1" ]; then
  init_ph_rep="$(cast calldata 'initialize(address)' "$identity_proxy")"
  args_rep="$(cast abi-encode 'f(address,bytes)' "$placeholder" "$init_ph_rep")"
  r_rp="$(send_create "$(bytecode ERC1967Proxy)${args_rep#0x}")"; reputation_proxy="$(rfield "$r_rp" contractAddress)"
  echo "  ReputationRegistry proxy $reputation_proxy (tx $(rfield "$r_rp" transactionHash))"
fi

log "3/5 implementations and upgrades"
r_ii="$(send_create "$(bytecode IdentityRegistryUpgradeable)")"; identity_impl="$(rfield "$r_ii" contractAddress)"
echo "  IdentityRegistryUpgradeable $identity_impl (tx $(rfield "$r_ii" transactionHash))"
r_iu="$(send_call "$identity_proxy" "$(cast calldata 'upgradeToAndCall(address,bytes)' "$identity_impl" "$(cast calldata 'initialize()')")")"
echo "  identity proxy upgraded and initialized (tx $(rfield "$r_iu" transactionHash))"
reputation_impl=""; r_ri=""; r_ru=""
if [ "$WITH_REPUTATION" = "1" ]; then
  r_ri="$(send_create "$(bytecode ReputationRegistryUpgradeable)")"; reputation_impl="$(rfield "$r_ri" contractAddress)"
  echo "  ReputationRegistryUpgradeable $reputation_impl (tx $(rfield "$r_ri" transactionHash))"
  r_ru="$(send_call "$reputation_proxy" "$(cast calldata 'upgradeToAndCall(address,bytes)' "$reputation_impl" "$(cast calldata 'initialize(address)' "$identity_proxy")")")"
  echo "  reputation proxy upgraded and initialized (tx $(rfield "$r_ru" transactionHash))"
fi

log "4/5 checks"
impl_slot="$(rpc "$L2_RPC" eth_getStorageAt "[\"$identity_proxy\",\"$IMPL_SLOT\",\"latest\"]" | jq -r .result)"
check "identity.implementationSlot" "0x${impl_slot#0x000000000000000000000000}" "$identity_impl"
version="$(cast call "$identity_proxy" 'getVersion()(string)' --rpc-url "$L2_RPC" | tr -d '"')"
check "identity.getVersion" "$version" "$(cast call "$identity_impl" 'getVersion()(string)' --rpc-url "$L2_RPC" | tr -d '"')"
check "identity.name" "$(cast call "$identity_proxy" 'name()(string)' --rpc-url "$L2_RPC" | tr -d '"')" "AgentIdentity"
check "identity.symbol" "$(cast call "$identity_proxy" 'symbol()(string)' --rpc-url "$L2_RPC" | tr -d '"')" "AGENT"
check "identity.owner.beforeTransfer" "$(cast call "$identity_proxy" 'owner()(address)' --rpc-url "$L2_RPC")" "$deployer"
domain="$(cast call "$identity_proxy" 'eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])' --rpc-url "$L2_RPC" --json)"
check "identity.eip712.name" "$(printf '%s' "$domain" | jq -r '.[1]')" "ERC8004IdentityRegistry"
check "identity.eip712.version" "$(printf '%s' "$domain" | jq -r '.[2]')" "1"
check "identity.eip712.chainId" "$(printf '%s' "$domain" | jq -r '.[3] | tostring')" "$CHAIN_ID"
check "identity.eip712.verifyingContract" "$(printf '%s' "$domain" | jq -r '.[4]')" "$identity_proxy"
check "identity.impl.runtimeIdentity" "$(identity_keccak "$identity_impl" IdentityRegistryUpgradeable)" "$(runtime_keccak IdentityRegistryUpgradeable)"
check "identity.proxy.runtimeIdentity" "$(identity_keccak "$identity_proxy" ERC1967Proxy)" "$(runtime_keccak ERC1967Proxy)"
check "placeholder.runtimeIdentity" "$(identity_keccak "$placeholder" HardhatMinimalUUPS)" "$(runtime_keccak HardhatMinimalUUPS)"
probe=0x000000000000000000000000000000000000dEaD
simulated="$(cast call "$identity_proxy" 'register()(uint256)' --from "$probe" --rpc-url "$L2_RPC" 2>/dev/null || echo reverted)"
check "identity.register.simulatedFirstAgentId" "$simulated" "0"
check "identity.probeBalanceUntouched" "$(cast call "$identity_proxy" 'balanceOf(address)(uint256)' "$probe" --rpc-url "$L2_RPC")" "0"
if [ "$WITH_REPUTATION" = "1" ]; then
  rslot="$(rpc "$L2_RPC" eth_getStorageAt "[\"$reputation_proxy\",\"$IMPL_SLOT\",\"latest\"]" | jq -r .result)"
  check "reputation.implementationSlot" "0x${rslot#0x000000000000000000000000}" "$reputation_impl"
  check "reputation.getIdentityRegistry" "$(cast call "$reputation_proxy" 'getIdentityRegistry()(address)' --rpc-url "$L2_RPC")" "$identity_proxy"
  check "reputation.owner.beforeTransfer" "$(cast call "$reputation_proxy" 'owner()(address)' --rpc-url "$L2_RPC")" "$deployer"
  check "reputation.impl.runtimeIdentity" "$(identity_keccak "$reputation_impl" ReputationRegistryUpgradeable)" "$(runtime_keccak ReputationRegistryUpgradeable)"
fi
[ "$FAILED" = "0" ] || die "a check failed before the ownership transfer; nothing transferred. Inspect the addresses above."

log "5/5 ownership -> $OWNER_ADDRESS"
r_it=""; r_rt=""
if [ "$(lower "$OWNER_ADDRESS")" = "$(lower "$deployer")" ]; then
  echo "  owner is the deployer itself; no transfer"
else
  r_it="$(send_call "$identity_proxy" "$(cast calldata 'transferOwnership(address)' "$OWNER_ADDRESS")")"
  check "identity.owner" "$(cast call "$identity_proxy" 'owner()(address)' --rpc-url "$L2_RPC")" "$OWNER_ADDRESS"
  if [ "$WITH_REPUTATION" = "1" ]; then
    r_rt="$(send_call "$reputation_proxy" "$(cast calldata 'transferOwnership(address)' "$OWNER_ADDRESS")")"
    check "reputation.owner" "$(cast call "$reputation_proxy" 'owner()(address)' --rpc-url "$L2_RPC")" "$OWNER_ADDRESS"
  fi
fi
[ "$FAILED" = "0" ] || die "ownership check failed; see above"

# receipt -> compact JSON {tx, block, gasUsed} (null when the step did not run)
rec() {
  if [ -z "$1" ]; then echo null; else
    printf '%s' "$1" | jq -c '{tx: .transactionHash, block: (.blockNumber | tonumber? // (. | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d))), gasUsed: (.gasUsed | ltrimstr("0x") | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d))}'
  fi
}
last_receipt="${r_rt:-${r_it:-${r_ru:-$r_iu}}}"
last_block_hex="$(rfield "$last_receipt" blockNumber)"
block_hash="$(rpc "$L2_RPC" eth_getBlockByNumber "[\"$last_block_hex\",false]" | jq -r .result.hash)"
checks_json="$(printf '%s' "$CHECK_ROWS" | awk -F'\t' 'NF >= 3 { printf "{\"check\":\"%s\",\"result\":\"%s\",\"value\":\"%s\",\"expected\":\"%s\"}\n", $1, $2, $3, $4 }' | jq -s '.')"

mkdir -p "$(dirname "$OUT")"
jq -n \
  --argjson chainId "$CHAIN_ID" --arg rpc "$L2_RPC" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson upstream "$(jq -c '.upstream' "$BUILD")" --argjson compiler "$(jq -c '.compiler' "$BUILD")" --argjson deps "$(jq -c '.dependencies' "$BUILD")" \
  --arg deployer "$deployer" --arg owner "$OWNER_ADDRESS" \
  --arg placeholder "$placeholder" --argjson r_ph "$(rec "$r_ph")" --arg ph_code "$(code_keccak "$placeholder")" \
  --arg ip "$identity_proxy" --arg ii "$identity_impl" --argjson r_ip "$(rec "$r_ip")" --argjson r_ii "$(rec "$r_ii")" --argjson r_iu "$(rec "$r_iu")" --argjson r_it "$(rec "$r_it")" \
  --arg ip_code "$(code_keccak "$identity_proxy")" --arg ii_code "$(code_keccak "$identity_impl")" --arg ii_id "$(identity_keccak "$identity_impl" IdentityRegistryUpgradeable)" --arg version "$version" \
  --arg rp "$reputation_proxy" --arg ri "$reputation_impl" --argjson r_rp "$(rec "$r_rp")" --argjson r_ri "$(rec "$r_ri")" --argjson r_ru "$(rec "$r_ru")" --argjson r_rt "$(rec "$r_rt")" \
  --arg rp_code "$([ -n "$reputation_proxy" ] && code_keccak "$reputation_proxy" || echo "")" --arg ri_code "$([ -n "$reputation_impl" ] && code_keccak "$reputation_impl" || echo "")" --arg ri_id "$([ -n "$reputation_impl" ] && identity_keccak "$reputation_impl" ReputationRegistryUpgradeable || echo "")" \
  --argjson block "$(( last_block_hex ))" --arg blockHash "$block_hash" --argjson checks "$checks_json" '
  {
    schema: "finchain.erc8004-root/1",
    chainId: $chainId, rpc: $rpc, recordedAt: $at,
    upstream: $upstream, compiler: $compiler, dependencies: $deps,
    deployer: $deployer, owner: $owner,
    placeholderImplementation: { address: $placeholder, contract: "HardhatMinimalUUPS", deployment: $r_ph, runtimeCodeKeccak: $ph_code },
    contracts: ({
      IdentityRegistry: {
        proxy: $ip, implementation: $ii, contract: "IdentityRegistryUpgradeable", version: $version,
        transactions: { proxy: $r_ip, implementation: $r_ii, upgradeToAndCall: $r_iu, transferOwnership: $r_it },
        runtimeCodeKeccak: { proxy: $ip_code, implementation: $ii_code },
        runtimeIdentity: { implementation: $ii_id, note: "keccak of the runtime code with the immutable slots zeroed; equals build.json runtimeBytecodeKeccak" },
        eip712Domain: { name: "ERC8004IdentityRegistry", version: "1", chainId: $chainId, verifyingContract: $ip }
      }
    } + (if $rp == "" then {} else {
      ReputationRegistry: {
        proxy: $rp, implementation: $ri, contract: "ReputationRegistryUpgradeable", identityRegistry: $ip,
        transactions: { proxy: $r_rp, implementation: $r_ri, upgradeToAndCall: $r_ru, transferOwnership: $r_rt },
        runtimeCodeKeccak: { proxy: $rp_code, implementation: $ri_code },
        runtimeIdentity: { implementation: $ri_id }
      }
    } end)),
    notDeployed: { ValidationRegistry: "not needed by the World (kya-standard ValidationRegistry8004 companion is part of the World); deploy later if an application needs the upstream one" },
    completion: { number: $block, hash: $blockHash },
    checks: $checks,
    note: "Finchain-deployed ERC-8004 reference registries: the identity root of the covenant World, not the upstream singleton deployment. The proxies are owned by the Finchain owner address, which is the upgrade authority."
  }' > "$OUT"
echo
echo "identity root recorded: $OUT"
echo "  IdentityRegistry   $identity_proxy"
[ -n "$reputation_proxy" ] && echo "  ReputationRegistry $reputation_proxy"
echo "  completion block   $(( last_block_hex )) ($block_hash)"
echo "Commit chain/out/erc8004.json. The IdentityRegistry address goes into FOGA's worlds/finchain-sepolia.json (identity8004.address)."
