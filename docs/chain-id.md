# Chain id

| Network | Chain id | Status |
| --- | --- | --- |
| Finchain Sepolia | 85422 | chosen 2026-11-11 (replaces the first candidate 83380); registry check passed before deployment |
| Finchain (mainnet) | 8454 | decided 2026-11-12 by the project owner: adjacent to Base (8453) and a nod to ERC-8454 (AIFi). Registry check 2026-11-12: absent from `ethereum-lists/chains` (2858 entries; 8450-8459 holds only Base) and no network found in a web search. Fixed at mainnet genesis; registered after launch |

## Why 8338 is excluded

8338 (the number of the first covenant ERC) has prior network use: a public chain listing
shows the id with an RPC configuration. Prior use is enough to avoid it, regardless of
whether that network is still producing blocks or is in any registry.

## Procedure before genesis

1. `make chain-id-check` - confirms the id is absent from `ethereum-lists/chains`
   (`_data/chains/eip155-85422.json`). Absence is necessary, not sufficient.
2. Manual checks, results recorded here with the date: chainlist.org entry, thirdweb chain
   page, web search for "chain id 85422" / "chainId 85422".
3. The id is a parameter everywhere (`CHAIN_ID` in `.env`); a change before genesis costs
   nothing. After genesis it cannot change.

## Registration after launch

Submit `registry/eip155-85422.json` to `ethereum-lists/chains` once the public RPC answers
and the explorer exists. Wallets pick the entry up from there.

## Record

| Date | Check | Result |
| --- | --- | --- |
| 2026-11-11 | testnet id 85422: `make chain-id-check` against `ethereum-lists/chains` | absent; deployed 2026-11-11 |
| 2026-11-12 | mainnet id 8454: `ethereum-lists/chains` `_data/chains/eip155-8454.json` | absent (neighbours: 8453 Base only) |
| 2026-11-12 | mainnet id 8454: web search for networks using the id | none found |
| | chainlist.org | |
| | thirdweb | |
| | web search | |
