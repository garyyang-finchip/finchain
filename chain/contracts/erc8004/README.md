# ERC-8004 reference contracts, as built for Finchain

The identity root of the covenant World (`docs/world.md`, section 3): the upstream ERC-8004
reference implementation, built once from a pinned commit and committed here so that the
deployment (`scripts/deploy-8004.sh`) sends exactly this bytecode and anyone can rebuild it.

| File | Content |
| --- | --- |
| `standard-input.json` | solc standard JSON input: the four contracts and every OpenZeppelin source they import (39 files in all), with the upstream compiler settings |
| `build.json` | per contract: ABI, creation and runtime bytecode, their keccak256, the immutable references of the runtime code, method identifiers; plus the upstream commit, compiler and dependency versions |
| `sources.json` | sha256 of every source file that entered the build |

Provenance:

| | |
| --- | --- |
| Upstream | `https://github.com/erc-8004/erc-8004-contracts`, commit `b9e466c250744a7e06b13dff9d3c2844ed64f825` |
| Contracts | `IdentityRegistryUpgradeable`, `ReputationRegistryUpgradeable`, `ERC1967Proxy` (OpenZeppelin's, re-exported upstream), `HardhatMinimalUUPS` (the upstream test placeholder whose `initialize()` makes the sender the owner) |
| Compiler | solc 0.8.24+commit.e11b9ed9, evm `shanghai`, optimizer 200 runs, via-IR, metadata hash `ipfs` (the upstream Hardhat profile) |
| Dependencies | `@openzeppelin/contracts` 5.4.0, `@openzeppelin/contracts-upgradeable` 5.4.0 (the upstream lock file) |
| Licence | upstream contracts MIT; OpenZeppelin contracts MIT |

Rebuild and compare: `make build-8004` (the `ethereum/solc:0.8.24` image, or `SOLC_BIN` for a
native binary) recompiles `standard-input.json` and compares every creation and runtime
bytecode hash with `build.json`.

Comparing with chain code: contracts that inherit `UUPSUpgradeable` carry one immutable
(`__self`, the implementation's own address), so their on-chain runtime code differs from
the compiled runtime at the offsets listed in `immutableReferences`; `scripts/deploy-8004.sh`
masks those bytes before hashing. The proxy has no immutables and matches byte for byte.

Not built: `ValidationRegistryUpgradeable` (not a prerequisite of the World; see
`docs/world.md`), `MinimalUUPS` and `MinimalUUPSMainnet` (hard-code the upstream owner),
`SingletonFactory` (vanity deployment, not used).
