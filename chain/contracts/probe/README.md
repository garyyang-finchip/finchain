# FinchainProbe: the EVM acceptance contract

A deliberately small contract (one storage word, one counter, one event) for the chain's
own acceptance: it belongs to no covenant and to no agent runtime. `scripts/evm-acceptance.sh`
deploys it through the public RPC, writes to it, reads it back and records every transaction;
`scripts/verify-evm.sh` re-reads the receipts, the code and the storage on host B at a
`finalized` block. Together they answer "is Finchain a complete, usable EVM chain on its
own?" without any application in the picture (`docs/world.md`, "Finchain on its own").

| File | Content |
| --- | --- |
| `FinchainProbe.sol` | the source (Apache-2.0) |
| `standard-input.json` | solc standard JSON input (solc 0.8.24, shanghai, optimizer 200 runs, no via-IR) |
| `build.json` | ABI, creation and runtime bytecode and their keccak256, method identifiers, compiler settings, source sha256 |

Rebuild and compare: `docker run --rm -i ethereum/solc:0.8.24 --standard-json < standard-input.json`
and compare `evm.deployedBytecode.object` with `build.json`. The contract has no immutables,
so its on-chain runtime code matches the compiled runtime byte for byte.
