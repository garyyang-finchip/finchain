# chain/world: FOGA on Finchain

The files a user needs to run the released FOGA package against Finchain, kept here so that
FOGA's package carries nothing about Finchain (`docs/world.md`, sections 1 and 5;
`docs/acceptance.md` M3-C).

| File | What it is | Written by |
| --- | --- | --- |
| `finchain-sepolia.world.json` | FOGA world configuration (schema `foga.world-config/1`, deploy mode, the Finchain ERC-8004 identity root, the RPC from `FINCHAIN_SEPOLIA_RPC_URL`) | this repository |
| `finchain-sepolia.json` | The address book (schema `foga.world/1`) the released FOGA wrote when it deployed the World; absent until that run | copied from `foga world deploy --out` |
| `../../manifests/covenant-world-finchain-sepolia.json` | The manifest's `covenantWorld` section derived from the address book: modules, raw code hashes at the completing block, build identity, both blocks | `make world-manifest` |

The released FOGA (`@finchip.ai/foga`, 1.0.7 or later) already takes a world configuration
by path, so nothing in FOGA changes and nothing is published for this:

```sh
# on the FOGA host, W's phrase in FOGA_MNEMONIC_FILE (or the key in FOGA_DEPLOYER_PK), W funded on L2
export FINCHAIN_SEPOLIA_RPC_URL=https://rpc.finchain.one
foga world deploy --world <finchain repo>/chain/world/finchain-sepolia.world.json \
  --rpc "$FINCHAIN_SEPOLIA_RPC_URL" --out deployments/finchain-sepolia.json      # --resume after an interruption
cp deployments/finchain-sepolia.json <finchain repo>/chain/world/finchain-sepolia.json

# in this repository: the manifest section, then host B's check at a finalized block, then verifiedAt
make world-manifest BOOK=chain/world/finchain-sepolia.json BUNDLE=<foga package>/artifacts/bundle.json
make verify-world SECTION=manifests/covenant-world-finchain-sepolia.json AT=finalized     # host B
make world-manifest BOOK=chain/world/finchain-sepolia.json BUNDLE=... REPORT=manifests/evidence/world-verify-<block>.json

# a cell on Finchain: the address book and the RPC are named explicitly; a bare `foga join` stays on Sepolia
foga join --world <finchain repo>/chain/world/finchain-sepolia.json --rpc https://rpc.finchain.one
```

`foga genesis preflight` and `foga genesis run` take the same `--world` and `--rpc`. The
identity root address in the configuration is the IdentityRegistry proxy of
`chain/out/erc8004.json`; for an address book that names a different registry,
`scripts/world-manifest.sh` records that registry's code hash and marks its provenance
unknown, which blocks the manifest candidate until it is explained.
