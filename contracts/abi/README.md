# Published ABI

The external interface other repositories build against: the quote service, and any front end.

`selectors.json` carries the 4-byte selector for every external function across these contracts. A consumer
that encodes calls by hand pins itself to that file and asserts its own constants against it, so a signature
change here fails the consumer's tests instead of surfacing as a reverted transaction.

Regenerate after any change to an external signature:

```sh
./abi/export.sh
```

Requires `jq` and `cast`. Commit the result in the same change as the contract edit that caused it.
