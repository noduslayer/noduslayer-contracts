# Published ABI

The external interface other repositories build against: the quote service, and any front end.

`selectors.json` carries the 4-byte selector for every external function across these contracts, and
`errors.json` the selector of every custom error they can revert with, plus `Error(string)` and
`Panic(uint256)`. A consumer that encodes calls or decodes reverts by hand pins itself to these files and
asserts its own constants against them, so a change here fails the consumer's tests instead of surfacing as
a reverted transaction or an unreadable one.

The six contracts covered: BasketToken, BasketFactory, BasketZap, BasketMigrator, BasketLens and
StockRegistry. `config/catalogue.json`, built by `config/build-catalogue.sh`, is the matching artifact for
the basket specs.

Regenerate after any change to an external signature:

```sh
./abi/export.sh
```

Requires `jq` and `cast`. Commit the result in the same change as the contract edit that caused it.
