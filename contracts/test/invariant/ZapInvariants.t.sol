// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {BasketFactory} from "../../src/BasketFactory.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {BasketZap} from "../../src/BasketZap.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";
import {IRouteExecutor} from "../../src/interfaces/IRouteExecutor.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRouter} from "../mocks/MockRouter.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// Mints and redeems through the zap at random sizes while strangers keep sending tokens to it. The zap
/// must end every transaction holding exactly what it held before that transaction started: what it was
/// sent by strangers is untouchable, and what a caller sent is either spent, paid as fee or returned.
contract ZapHandler is Test {
    BasketZap public zap;
    BasketToken public basket;
    MockRouter public router;
    MockStockToken public nvda;
    MockStockToken public aapl;
    MockERC20 public usdg;
    address[] public actors;

    /// What strangers have sent the zap of each token; the zap's balance must always equal it.
    mapping(address token => uint256) public stranded;
    uint256 public mints;
    uint256 public redeems;
    uint256 public reverts;

    constructor(
        BasketZap zap_,
        BasketToken basket_,
        MockRouter router_,
        MockStockToken nvda_,
        MockStockToken aapl_,
        MockERC20 usdg_
    ) {
        zap = zap_;
        basket = basket_;
        router = router_;
        nvda = nvda_;
        aapl = aapl_;
        usdg = usdg_;
        for (uint256 i; i < 3; ++i) {
            address a = makeAddr(string(abi.encodePacked("zapper", i)));
            actors.push(a);
            vm.startPrank(a);
            usdg.approve(address(zap), type(uint256).max);
            basket.approve(address(zap), type(uint256).max);
            vm.stopPrank();
        }
    }

    function zapMint(uint256 actorSeed, uint256 shares, uint256 slack) external {
        address actor = _actor(actorSeed);
        shares = bound(shares, 1e15, 50e18);
        (uint256[] memory need,) = basket.previewMint(shares);
        uint256 cost = need[0] * router.price(address(nvda)) / 1e18 + need[1] * router.price(address(aapl)) / 1e18 + 2;
        // Enough for the spend, the fee on it, and up to 10% of slack the caller expects back.
        uint256 amountIn = cost + cost * zap.feeBps() / 10_000 + 1 + bound(slack, 0, cost / 10);
        usdg.mint(actor, amountIn);

        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = _buy(address(nvda), need[0]);
        swaps[1] = _buy(address(aapl), need[1]);
        vm.prank(actor);
        try zap.zapMint(address(basket), address(usdg), amountIn, shares, swaps, actor, block.timestamp) {
            mints++;
        } catch {
            reverts++;
        }
    }

    function zapRedeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 held = basket.balanceOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        (uint256[] memory out,) = basket.previewRedeem(shares);
        if (out[0] == 0 || out[1] == 0) return;

        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = _sell(address(nvda), out[0]);
        swaps[1] = _sell(address(aapl), out[1]);
        vm.prank(actor);
        try zap.zapRedeem(address(basket), shares, address(usdg), 0, swaps, actor, block.timestamp) {
            redeems++;
        } catch {
            reverts++;
        }
    }

    /// A stranger sends the zap tokens it did not ask for.
    function strand(uint256 tokenSeed, uint256 amount) external {
        amount = bound(amount, 1, 100e18);
        uint256 which = bound(tokenSeed, 0, 2);
        if (which == 0) {
            usdg.mint(address(zap), amount / 1e12 + 1);
            stranded[address(usdg)] += amount / 1e12 + 1;
        } else if (which == 1) {
            nvda.mint(address(zap), amount);
            stranded[address(nvda)] += amount;
        } else {
            aapl.mint(address(zap), amount);
            stranded[address(aapl)] += amount;
        }
    }

    function _buy(address token, uint256 amountOut) internal view returns (IRouteExecutor.Swap memory) {
        return IRouteExecutor.Swap(
            address(router),
            address(usdg),
            0,
            abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), token, amountOut))
        );
    }

    function _sell(address token, uint256 amountIn) internal view returns (IRouteExecutor.Swap memory) {
        return IRouteExecutor.Swap(
            address(router), token, 0, abi.encodeCall(MockRouter.swapExactInput, (token, address(usdg), amountIn))
        );
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }
}

contract ZapInvariantsTest is Test {
    BasketZap internal zap;
    BasketToken internal basket;
    ZapHandler internal handler;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockERC20 internal usdg;

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockAggregator feed = new MockAggregator(8, 100e8);
        address owner = makeAddr("protocolOwner");
        address treasury = makeAddr("treasury");

        StockRegistry registry = new StockRegistry(owner);
        BasketFactory factory = new BasketFactory(owner, registry, treasury);
        zap = new BasketZap(owner, factory, treasury, 20, IWETH(address(new MockWETH())));

        MockRouter router = new MockRouter();
        router.setPrice(address(nvda), 230e6);
        router.setPrice(address(aapl), 328e6);
        nvda.mint(address(router), 1_000_000e18);
        aapl.mint(address(router), 1_000_000e18);
        usdg.mint(address(router), 1_000_000_000e6);

        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), 0.2e18);
        recipe[1] = IBasketToken.Constituent(address(aapl), 0.15e18);
        vm.startPrank(owner);
        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        basket = BasketToken(factory.createBasket("Tech", "TECH", recipe, 10, 10));
        zap.setRouter(address(router), true);
        vm.stopPrank();

        handler = new ZapHandler(zap, basket, router, nvda, aapl, usdg);
        targetContract(address(handler));
    }

    /// Delta accounting, stated as an invariant: the zap never ends a transaction holding anything but what
    /// strangers sent it. A caller's money is spent, paid as fee, or returned, and a stranger's is never
    /// touched — not spent by a route, not refunded to a caller, not paid out as proceeds.
    function invariant_ZapHoldsOnlyWhatStrangersSentIt() public view {
        assertEq(usdg.balanceOf(address(zap)), handler.stranded(address(usdg)), "usdg");
        assertEq(nvda.balanceOf(address(zap)), handler.stranded(address(nvda)), "nvda");
        assertEq(aapl.balanceOf(address(zap)), handler.stranded(address(aapl)), "aapl");
        assertEq(basket.balanceOf(address(zap)), 0, "shares");
    }

    /// The zap never leaves a router able to spend on its behalf after the call.
    function invariant_NoStandingRouterAllowance() public view {
        address router = address(handler.router());
        assertEq(usdg.allowance(address(zap), router), 0);
        assertEq(nvda.allowance(address(zap), router), 0);
        assertEq(aapl.allowance(address(zap), router), 0);
    }

    function invariant_CallSummary() public view {
        handler.mints();
        handler.redeems();
        handler.reverts();
    }
}
