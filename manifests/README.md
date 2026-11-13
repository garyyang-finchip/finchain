# Reference-version manifests

A manifest is the publicly checkable anchor of one Finchain reference version. It records
what the chain is (ids, genesis hash, rollup config hash, L1 contracts), what runs it
(image digests, contracts release, fault-proof program and prestate), who controls what
(Finchain roles and the authority Finchain does not hold), where the covenant World lives
(transaction-level evidence and the completing block), which released FOGA package
deployed it, and which acceptance items passed, in which environment.

Files:

| File | Purpose |
| --- | --- |
| `manifest.schema.json` | JSON Schema (draft 2020-12) every manifest must validate against |
| `manifest.template.json` | Starting point with placeholders |
| `onchain-<l1block>.json` | Live L1 configuration snapshots written by `make verify-onchain` |
| `covenant-world-<name>.json` | The `covenantWorld` section derived from a FOGA address book by `make world-manifest` (raw code hashes at the completing block, modules, both blocks) |
| `superseded/` | Sections of Worlds replaced by a later deployment, kept with the reason and the successor's world id |
| `evidence/` | Acceptance records written by the scripts (rebuild-from-L1, comparisons, EVM acceptance, FOGA isolation, World verification, drills) and the FOGA genesis evidence and doctor report of the reference World |
| `finchain-sepolia/<version>.json` | Published manifests (one per reference version) |

Rules:

- History is kept: a superseded manifest stays in the repository with `status: superseded`
  and the new one names it in `supersedes`. Work that started under an older version keeps
  pointing at that version.
- `software.images` must carry digests, not tags. `make lock` produces them.
- `governance.onchainSnapshot` must reference a snapshot taken at a fixed L1 block; the
  snapshot, not `state.json`, is the authority for respected game type, game
  implementations, prestate, bonds and role addresses.
- Every acceptance entry states the environment (`local-devnet`, `public-testnet`,
  `mainnet`). A result demonstrated locally is never recorded as a public-testnet result.

Validate before publishing:

```bash
python3 -c "import json,jsonschema,sys; s=json.load(open('manifests/manifest.schema.json')); d=json.load(open(sys.argv[1])); jsonschema.validate(d,s); print('valid')" manifests/finchain-sepolia/<version>.json
```
