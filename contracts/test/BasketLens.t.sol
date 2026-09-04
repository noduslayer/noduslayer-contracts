// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketLens} from "../src/BasketLens.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

contract BasketLensTest is Test {
    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketLens internal lens;
    BasketToken internal basket;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockAggregator internal nvdaFeed;
    MockAggregator internal aaplFeed;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_800_000_000);
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        nvdaFeed = new MockAggregator(8, 230e8);
        aaplFeed = new MockAggregator(8, 328e8);

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        lens = new BasketLens(registry);

        vm.startPrank(protocolOwner);
        registry.list(address(nvda), address(nvdaFeed));
        registry.list(address(aapl), address(aaplFeed));
        basket =
            BasketToken(factory.createBasket("NodusLayer Tech", "TECH", _recipe(address(nvda), address(aapl)), 10, 10));
        vm.stopPrank();
    }

    function test_Price_NormalizesFeedDecimals() public view {
        (uint256 price, uint256 updatedAt) = lens.price(address(nvda));
        assertEq(price, 230e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_RevertWhen_PriceHasNoFeed() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(BasketLens.NoFeed.selector, unknown));
        lens.price(unknown);
    }

    function test_RevertWhen_PriceNotPositive() public {
        nvdaFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(BasketLens.InvalidPrice.selector, address(nvda)));
        lens.price(address(nvda));
    }

    function test_Nav_SumsConstituentValues() public view {
        (uint256 nav, uint256 oldestUpdate) = lens.nav(address(basket));
        assertEq(nav, 95.2e18);
        assertEq(oldestUpdate, block.timestamp);
    }

    function test_Nav_ReportsOldestFeedUpdate() public {
        aaplFeed.set(328e8, block.timestamp - 3 days);
        (, uint256 oldestUpdate) = lens.nav(address(basket));
        assertEq(oldestUpdate, block.timestamp - 3 days);
    }

    function test_NavWithMaxAge_RevertsWhenStale() public {
        aaplFeed.set(328e8, block.timestamp - 3 days);
        vm.expectRevert(abi.encodeWithSelector(BasketLens.StalePrice.selector, address(aapl), block.timestamp - 3 days));
        lens.nav(address(basket), 1 days);
    }

    function test_NavWithMaxAge_ReturnsWhenFresh() public view {
        assertEq(lens.nav(address(basket), 1 days), 95.2e18);
    }

    function test_NavWithMaxAge_SaturatesHugeMaxAge() public view {
        assertEq(lens.nav(address(basket), type(uint256).max), 95.2e18);
    }

    function test_Nav_HandlesNon18DecimalConstituent() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        MockAggregator sixFeed = new MockAggregator(8, 2e8);
        vm.startPrank(protocolOwner);
        registry.list(address(six), address(sixFeed));
        IBasketToken.Constituent[] memory recipe = _recipe(address(nvda), address(six));
        recipe[1].units = 0.15e6;
        BasketToken mixed = BasketToken(factory.createBasket("Mixed", "MIX", recipe, 0, 0));
        vm.stopPrank();

        (uint256 nav,) = lens.nav(address(mixed));
        assertEq(nav, 46.3e18);
    }

    function test_Quotes_ReturnsPerConstituentBreakdown() public view {
        BasketLens.Quote[] memory quotes = lens.quotes(address(basket));
        assertEq(quotes.length, 2);
        assertEq(quotes[0].token, address(nvda));
        assertEq(quotes[0].units, 0.2e18);
        assertEq(quotes[0].price, 230e18);
        assertEq(quotes[0].value, 46e18);
        assertEq(quotes[1].value, 49.2e18);
    }

    // ---------------------------------------------------------------- unpriced constituents

    function _basketWithUnpricedAapl() internal returns (BasketToken) {
        vm.startPrank(protocolOwner);
        registry.setFeed(address(aapl), address(0));
        BasketToken b =
            BasketToken(factory.createBasket("Partial", "PART", _recipe(address(nvda), address(aapl)), 0, 0));
        vm.stopPrank();
        return b;
    }

    function test_Quotes_FlagsUnpricedConstituentInsteadOfReverting() public {
        BasketLens.Quote[] memory q = lens.quotes(address(_basketWithUnpricedAapl()));

        assertTrue(q[0].priced);
        assertEq(q[0].value, 46e18);
        assertFalse(q[1].priced);
        assertEq(q[1].price, 0);
        assertEq(q[1].value, 0);
    }

    function test_RevertWhen_NavHasUnpricedConstituent() public {
        BasketToken b = _basketWithUnpricedAapl();

        vm.expectRevert(abi.encodeWithSelector(BasketLens.NoFeed.selector, address(aapl)));
        lens.nav(address(b));
    }

    function test_RevertWhen_NavWithMaxAgeHasUnpricedConstituent() public {
        BasketToken b = _basketWithUnpricedAapl();

        vm.expectRevert(abi.encodeWithSelector(BasketLens.NoFeed.selector, address(aapl)));
        lens.nav(address(b), 1 days);
    }

    function test_UnpricedCount_ReportsHowManyLackAFeed() public {
        assertEq(lens.unpricedCount(address(basket)), 0);
        assertEq(lens.unpricedCount(address(_basketWithUnpricedAapl())), 1);
    }

    function _recipe(address a, address b) internal pure returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(a, 0.2e18);
        recipe[1] = IBasketToken.Constituent(b, 0.15e18);
    }
}
