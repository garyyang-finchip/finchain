# chain/world: FOGA on Finchain

The files a user needs to run the released FOGA package against Finchain, kept here so that
FOGA's package carries nothing about Finchain (`docs/world.md`, sections 1 and 5;
`docs/acceptance.md` M3-C).

| File | What it is | Written by |
| --- | --- | --- |
| `finchain-sepolia.world.json` | FOGA world configuration (schema `foga.world-config/1`, deploy mode, the Finchain ERC-8004 identity root, the RPC from `FINCHAIN_SEPOLIA_RPC_URL`) | this repository |
| `finchain-sepolia.json` | The address book (schema `foga.world/1`) the released FOGA wrote when it deployed the current reference World, `finchain-sepolia-85422-20261113T023727Z` (2026-11-13, blocks 61389-61527 plus wiring and flows) | copied from `foga world deploy --out` |
| `superseded/finchain-sepolia-85422-20261112T154525Z.json` | The first World (2026-11-12), superseded on 2026-11-13; see the note below | kept for history |
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

## The first World and ERC-8004 agent id 0

The first World, `finchain-sepolia-85422-20261112T154525Z`, was deployed on 2026-11-12 and
verified by host B at the finalized block 42684 (`manifests/evidence/world-verify-42684.json`,
59 contracts MATCH). Its genesis passed T0-T3 and stopped at T4: cell A had been registered
on the Finchain ERC-8004 registry as agent id 0 (the upstream v2 registry numbers agents
from 0; `chain/out/erc8004.json` records `simulatedFirstAgentId = 0`), and the ERC-8447
reference module `ERC8004Eligibility` uses `agentId == 0` as its no-agent sentinel in both
`declareAgent` and `isEligible`, so A could not be declared. The same holds on the official
Sepolia registry, whose agent 0 exists; FOGA's Sepolia cells were numbered from 11255 and
never met it. Nothing in the chain or in FOGA was changed: the T0 registrations of a World
are not repeatable (the ASF, ACDF and ADRF registries refuse duplicates), so a second World
was deployed by the same released FOGA 1.0.7 and the genesis ran there with a fresh store;
its cells are agents 3, 4 and 5. Agent id 0 is held by the first run's cell A account,
`0x7eBead23804165673D6E14566efF28da439c5079`. The sentinel is left to the upstream
ERC-8447 repository to fix (both functions at once); the first World's files stay under
`superseded/` with this record.
