# FOGA confirmation and recovery policy on Finchain

This document is the specification handed to the FOGA repository for its Finchain chain
configuration. It defines which confirmation level a FOGA cell requires before each class
of action, how it handles rollbacks, and how it keeps business operations idempotent.
Wallet and contract logic are unchanged; the kernel/doctor confirmation, rollback and
idempotency handling is real implementation work.

## Confirmation levels

op-node labels L2 blocks `unsafe`, `safe` and `finalized`; op-reth exposes them through the
`latest`, `safe` and `finalized` block tags.

| Level | Meaning | FOGA use |
| --- | --- | --- |
| `latest` (unsafe) | executed by the sequencer; data not yet on L1; can be dropped if the batcher misses the sequencer window (about 12 hours) | progress display, preparation of retryable work, UI |
| `safe` | batch data included on L1; a verifier can rebuild it from L1; still rolled back if L1 reorgs below the batch | cell-to-cell messages, provisional ledger entries, scheduling of next steps |
| `finalized` | the L1 blocks carrying the data are finalized | irreversible external actions: payments outside the chain, publishing, revocation, deleting local secrets |
| L1 withdrawal complete | output proposal + proof + delays satisfied | asset exit to L1 |

`safe` is a **provisional ledger state**, never a permanent business fact. Application
outcomes (a task `settled`, an ADRF case `Final`) are state-machine results; the cell reads
the confirmation level of the block that produced them before acting.

## Event processing

- The event cursor stores `(blockNumber, blockHash, logIndex, level)` per subscription and
  is rollback-capable: on a mismatch between the stored hash and the hash at that height,
  the cursor rewinds to the last common ancestor and re-processes.
- Every read checks both block identity (hash) and level; a block that was `safe` and is
  no longer in the canonical chain is treated as a rollback, including of entries recorded
  from it.
- Provisional entries carry the level they were recorded at; promotion to `finalized` is a
  separate step, so a crash between "finalized observed" and "local record written" is
  recoverable by re-reading.

## Idempotency

- Each business operation has a stable operation id derived from its inputs (for example
  task id + fulfilment id + action), stored before any side effect.
- External side effects (model calls that cost money, messages, payments) are executed at
  most once per operation id; a replay after rollback or crash first checks the operation
  log, then the on-chain state, then decides.
- Before re-sending a transaction, the cell reads the on-chain task state: the original
  transaction may have been dropped, replaced or re-included. Nonce management handles
  ordering only; it does not provide business idempotency.
- "Retryable" is judged by consequence, not by API shape: a call that incurs inference
  cost, sends a message or triggers a payment is not replayed freely at `safe`.

## Profiles and waiting time

The batcher profile sets how fast `safe` advances: `demo` every few minutes, `lowcost`
30-60 minutes. A cell that waits for `safe` before continuing a collaboration pauses for
that interval; UI and acceptance records state the active profile and the expected wait.
`finalized` additionally waits for L1 finality (about 15-20 minutes after inclusion). The
proposal interval affects only withdrawals.

## Acceptance (M3)

- Two independent cells complete discovery -> eligibility -> task -> execution ->
  submission -> acceptance -> payment with the confirmation levels above enforced.
- Induced rollback test on a devnet: an `unsafe` segment dropped and re-sequenced; the cell
  rewinds its cursor, no duplicate payment, no duplicate external message.
- Resend test: a dropped transaction is detected from on-chain state before resend.
- Crash test: process killed between external payment and local record; recovery performs
  no second payment.
- Each result recorded with the profile and environment.
