# Chain id

| Network | Chain id | Status |
| --- | --- | --- |
| Finchain Sepolia | 83380 | candidate; final uniqueness check before genesis |
| Finchain (mainnet) | to be decided | frozen before mainnet deployment |

## Why 8338 is excluded

8338 (the number of the first covenant ERC) has prior network use: a public chain listing
shows the id with an RPC configuration. Prior use is enough to avoid it, regardless of
whether that network is still producing blocks or is in any registry.

## Procedure before genesis

1. `make chain-id-check` - confirms the id is absent from `ethereum-lists/chains`
   (`_data/chains/eip155-83380.json`). Absence is necessary, not sufficient.
2. Manual checks, results recorded here with the date: chainlist.org entry, thirdweb chain
   page, web search for "chain id 83380" / "chainId 83380".
3. The id is a parameter everywhere (`CHAIN_ID` in `.env`); a change before genesis costs
   nothing. After genesis it cannot change.

## Registration after launch

Submit `registry/eip155-83380.json` to `ethereum-lists/chains` once the public RPC answers
and the explorer exists. Wallets pick the entry up from there.

## Record

| Date | Check | Result |
| --- | --- | --- |
| | ethereum-lists/chains | |
| | chainlist.org | |
| | thirdweb | |
| | web search | |
