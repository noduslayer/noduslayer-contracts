// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {BasketFactory} from "../../src/BasketFactory.sol";
import {BasketLens} from "../../src/BasketLens.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";

/// Lists the full published universe against mainnet state and proves what a feed-less constituent costs.
contract ListingForkTest is Test {
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketLens internal lens;

    string[] internal symbols;
    address[] internal tokens;
    address[] internal feeds;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("robinhood"));

        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.json"));
        symbols = vm.parseJsonStringArray(j, ".stockSymbols");
        tokens = vm.parseJsonAddressArray(j, ".stockTokens");
        feeds = vm.parseJsonAddressArray(j, ".stockFeeds");

        registry = new StockRegistry(owner);
        factory = new BasketFactory(owner, registry, treasury);
        lens = new BasketLens(registry);
    }

    function test_Fork_ListsEveryPublishedStockToken() public {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);

        uint256 g = gasleft();
        vm.prank(owner);
        registry.listMany(tokens, feeds);
        uint256 gasUsed = g - gasleft();

        uint256 withFeed;
        for (uint256 i; i < tokens.length; ++i) {
            assertTrue(registry.isListed(tokens[i]), symbols[i]);
            if (registry.hasFeed(tokens[i])) ++withFeed;
        }

        console2.log("tokens listed          ", tokens.length);
        console2.log("with on-chain feed     ", withFeed);
        console2.log("gas for one listMany   ", gasUsed);
        console2.log("cost in USD cents      ", gasUsed * 635_690_000 * 2504 / 1e16);
        assertEq(registry.tokens().length, tokens.length);
    }

    function test_Fork_FeedlessConstituentMintsButCannotBePriced() public {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);

        vm.startPrank(owner);
        registry.listMany(tokens, feeds);
        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(tokens[_i("NVDA")], 0.1e18);
        recipe[1] = IBasketToken.Constituent(tokens[_i("GLD")], 0.1e18);
        BasketToken b = BasketToken(factory.createBasket("Mixed", "MIX", recipe, 0, 0));
        vm.stopPrank();

        // The factory accepts it and the vault is fully functional...
        assertTrue(factory.isBasket(address(b)));
        assertEq(b.constituentCount(), 2);

        // ...but NAV fails loudly, and the lens says exactly how many constituents lack a price.
        assertEq(lens.unpricedCount(address(b)), 1);
        vm.expectRevert(abi.encodeWithSelector(BasketLens.NoFeed.selector, tokens[_i("GLD")]));
        lens.nav(address(b));

        BasketLens.Quote[] memory q = lens.quotes(address(b));
        assertTrue(q[0].priced);
        assertFalse(q[1].priced);
    }

    function _i(string memory s) internal view returns (uint256) {
        bytes32 want = keccak256(bytes(s));
        for (uint256 i; i < symbols.length; ++i) {
            if (keccak256(bytes(symbols[i])) == want) return i;
        }
        revert(string.concat("symbol missing: ", s));
    }
}
