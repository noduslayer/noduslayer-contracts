// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BasketFactory} from "../../src/BasketFactory.sol";
import {BasketLens} from "../../src/BasketLens.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";

/// Deploys every curated basket in config/baskets against live mainnet state. This is the catalogue's
/// regression test: a recipe that breaches a depth cap, misses a feed or misprices its weights fails here.
contract BasketCatalogueForkTest is Test {
    uint256 private constant BPS = 10_000;

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketLens internal lens;

    string[] internal symbols;
    address[] internal tokens;
    address[] internal feeds;
    uint256[] internal caps;
    uint256[] internal depths;
    uint256 internal minWeightBps;
    uint256 internal maxDepthShareBps;

    address internal owner = makeAddr("owner");

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("robinhood"));

        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.json"));
        symbols = vm.parseJsonStringArray(j, ".stockSymbols");
        tokens = vm.parseJsonAddressArray(j, ".stockTokens");
        feeds = vm.parseJsonAddressArray(j, ".stockFeeds");
        caps = vm.parseJsonUintArray(j, ".stockMaxWeightBps");
        depths = vm.parseJsonUintArray(j, ".stockDepthUsd");
        minWeightBps = vm.parseJsonUint(j, ".constituentPolicy.minWeightBps");
        maxDepthShareBps = vm.parseJsonUint(j, ".constituentPolicy.maxDepthShareBps");

        registry = new StockRegistry(owner);
        factory = new BasketFactory(owner, registry, makeAddr("treasury"));
        lens = new BasketLens(registry);
        vm.prank(owner);
        registry.listMany(tokens, feeds);
    }

    function test_Fork_EveryCuratedBasketDeploysAndPrices() public {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);

        Vm.DirEntry[] memory entries = vm.readDir(string.concat(vm.projectRoot(), "/config/baskets"));
        uint256 built;
        uint256 worstCapacity = type(uint256).max;
        string memory worst;

        for (uint256 e; e < entries.length; ++e) {
            if (!_endsWithJson(entries[e].path)) continue;
            string memory spec = vm.readFile(entries[e].path);

            string[] memory syms = vm.parseJsonStringArray(spec, ".symbols");
            uint256[] memory weights = vm.parseJsonUintArray(spec, ".weightsBps");
            assertEq(syms.length, weights.length, entries[e].path);

            (IBasketToken.Constituent[] memory recipe, uint256 capacity) = _recipe(spec, syms, weights);

            vm.prank(owner);
            address basket = factory.createBasket(
                vm.parseJsonString(spec, ".name"),
                vm.parseJsonString(spec, ".symbol"),
                recipe,
                uint16(vm.parseJsonUint(spec, ".mintFeeBps")),
                uint16(vm.parseJsonUint(spec, ".redeemFeeBps"))
            );

            // Every curated basket must be fully priceable on-chain.
            assertEq(lens.unpricedCount(basket), 0, vm.parseJsonString(spec, ".symbol"));
            (uint256 nav,) = lens.nav(basket);
            assertApproxEqRel(nav, vm.parseJsonUint(spec, ".navPerShareUsd") * 1e18, 0.01e18);
            assertEq(BasketToken(basket).constituentCount(), syms.length);

            if (capacity < worstCapacity) {
                worstCapacity = capacity;
                worst = vm.parseJsonString(spec, ".symbol");
            }
            ++built;
        }

        console2.log("curated baskets deployed", built);
        console2.log("thinnest capacity (USD) ", worstCapacity);
        console2.log("held by                 ", worst);
        assertEq(built, 20);
        assertGt(worstCapacity, 5000);
    }

    function _recipe(string memory spec, string[] memory syms, uint256[] memory weights)
        private
        view
        returns (IBasketToken.Constituent[] memory recipe, uint256 capacity)
    {
        recipe = new IBasketToken.Constituent[](syms.length);
        uint256 nav = vm.parseJsonUint(spec, ".navPerShareUsd") * 1e18;
        uint256 total;
        capacity = type(uint256).max;

        for (uint256 i; i < syms.length; ++i) {
            uint256 k = _indexOf(syms[i]);
            assertTrue(feeds[k] != address(0), syms[i]);
            assertGe(weights[i], minWeightBps, syms[i]);
            assertLe(weights[i], caps[k], syms[i]);
            total += weights[i];

            recipe[i] = IBasketToken.Constituent(tokens[k], _units(feeds[k], weights[i], nav));

            uint256 c = depths[k] * maxDepthShareBps / weights[i];
            if (c < capacity) capacity = c;
        }
        assertEq(total, BPS);
    }

    function _units(address feed, uint256 weightBps, uint256 nav) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        assertGt(answer, 0);
        assertGt(updatedAt + 7 days, block.timestamp);
        return
            Math.mulDiv(weightBps * nav, 10 ** AggregatorV3Interface(feed).decimals(), BPS * SafeCast.toUint256(answer));
    }

    function _indexOf(string memory s) private view returns (uint256) {
        bytes32 want = keccak256(bytes(s));
        for (uint256 i; i < symbols.length; ++i) {
            if (keccak256(bytes(symbols[i])) == want) return i;
        }
        revert(string.concat("symbol not in chain config: ", s));
    }

    function _endsWithJson(string memory path) private pure returns (bool) {
        bytes memory b = bytes(path);
        if (b.length < 5) return false;
        return b[b.length - 5] == "." && b[b.length - 4] == "j" && b[b.length - 3] == "s" && b[b.length - 2] == "o"
            && b[b.length - 1] == "n";
    }
}
