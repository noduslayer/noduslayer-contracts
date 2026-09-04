# Governance operations

One file per timelock operation, written by the scripts in `script/` when an operation is scheduled and
named by its operation id. Each holds the targets, values and payloads the id commits to, the salt and
delay, and the three transactions a multisig may need to submit: `scheduleTx`, `executeTx` and `cancelTx`.

Execute and cancel read the file rather than rebuilding the payload, so what runs after the delay is
exactly what was reviewed when it was scheduled. A file that no longer hashes to its name is refused.

Commit these. They are the record of every change the protocol's owner has made, in the order it made
them, and `MODE=status OP=<id>` reports what the chain says about any of them.
