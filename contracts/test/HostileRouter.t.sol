// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IRouteExecutor} from "../src/interfaces/IRouteExecutor.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {GreedyRouter, ReentrantRouter, ShortRouter, ThiefRouter} from "./mocks/HostileRouters.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// The router allow-list is governance's sharpest lever, and the runbook says a compromised router is the
/// realistic attack. These tests give the zap routers that lie, and check that the most any of them can
/// take is what the caller put in for that one transaction.
contract HostileRouterTest is Test {
    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketToken internal basket;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockERC20 internal usdg;
    MockRouter internal honest;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockAggregator feed = new MockAggregator(8, 100e8);

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        zap = new BasketZap(protocolOwner, factory, treasury, 20, IWETH(address(new MockWETH())));

        honest = new MockRouter();
        honest.setPrice(address(nvda), 230e6);
        honest.setPrice(address(aapl), 328e6);
        nvda.mint(address(honest), 1000e18);
        aapl.mint(address(honest), 1000e18);
        usdg.mint(address(honest), 1_000_000e6);

        vm.startPrank(protocolOwner);
        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        basket = BasketToken(factory.createBasket("Tech", "TECH", _recipe(), 10, 10));
        zap.setRouter(address(honest), true);
        vm.stopPrank();

        usdg.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdg.approve(address(zap), type(uint256).max);
        basket.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    /// A router that calls back into zapMint mid-route meets the reentrancy guard, and the guard's revert
    /// propagates through the route and undoes the whole transaction.
    function test_RevertWhen_RouterReentersZapMint() public {
        ReentrantRouter evil = new ReentrantRouter();
        _allow(address(evil));
        evil.arm(
            abi.encodeCall(
                zap.zapMint,
                (address(basket), address(usdg), 1e6, 1e18, new IRouteExecutor.Swap[](0), alice, block.timestamp)
            )
        );
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](1);
        swaps[0] = IRouteExecutor.Swap(address(evil), address(usdg), 0, abi.encodeCall(ReentrantRouter.swap, ()));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, alice, block.timestamp);

        assertEq(usdg.balanceOf(alice), 10_000e6, "nothing left the caller");
    }

    function test_RevertWhen_RouterReentersZapRedeem() public {
        _seedShares();
        ReentrantRouter evil = new ReentrantRouter();
        _allow(address(evil));
        evil.arm(
            abi.encodeCall(
                zap.zapRedeem,
                (address(basket), 1e18, address(usdg), 0, new IRouteExecutor.Swap[](0), alice, block.timestamp)
            )
        );
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](1);
        swaps[0] = IRouteExecutor.Swap(address(evil), address(nvda), 0, abi.encodeCall(ReentrantRouter.swap, ()));

        uint256 sharesBefore = basket.balanceOf(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        zap.zapRedeem(address(basket), 5e18, address(usdg), 0, swaps, alice, block.timestamp);
        assertEq(basket.balanceOf(alice), sharesBefore);
    }

    /// A router may take everything the caller put in — that is the allowance the route legitimately has —
    /// but then it has bought nothing, the mint cannot be staged, and the transaction reverts. The greedy
    /// router's take is undone with everything else.
    function test_RevertWhen_RouterTakesTheInputAndDeliversNothing() public {
        GreedyRouter evil = new GreedyRouter();
        _allow(address(evil));
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](1);
        swaps[0] =
            IRouteExecutor.Swap(address(evil), address(usdg), 0, abi.encodeCall(GreedyRouter.swap, (address(usdg))));

        vm.expectRevert(abi.encodeWithSelector(IRouteExecutor.InsufficientConstituent.selector, address(nvda), 0, 2e18));
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, alice, block.timestamp);

        assertEq(usdg.balanceOf(alice), 10_000e6);
        assertEq(usdg.balanceOf(address(evil)), 0);
    }

    /// The caller's input is not the only balance the zap holds mid-route: constituents bought by earlier
    /// legs, and anything stranded, sit there too. A router is approved for its own sell token only, so a
    /// leg that reaches for another token finds no allowance.
    function test_RevertWhen_RouterReachesForATokenItWasNotSelling() public {
        nvda.mint(address(zap), 5e18); // stranded, and worth stealing
        ThiefRouter evil = new ThiefRouter();
        _allow(address(evil));
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = IRouteExecutor.Swap(
            address(honest),
            address(usdg),
            0,
            abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), address(nvda), 2e18))
        );
        swaps[1] = IRouteExecutor.Swap(
            address(evil), address(usdg), 0, abi.encodeCall(ThiefRouter.swap, (address(nvda), 1e18))
        );

        vm.expectRevert();
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, alice, block.timestamp);

        assertEq(nvda.balanceOf(address(zap)), 5e18, "the stranded balance is untouched");
        assertEq(nvda.balanceOf(address(evil)), 0);
    }

    /// A router that keeps a slice of what it was paid for leaves the mint short, and the shortfall is
    /// named in the revert: the route is refused rather than the caller quietly overpaying.
    function test_RevertWhen_RouterDeliversLessThanPaidFor() public {
        ShortRouter evil = new ShortRouter();
        _allow(address(evil));
        nvda.mint(address(evil), 10e18);
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = IRouteExecutor.Swap(
            address(evil),
            address(usdg),
            0,
            abi.encodeCall(ShortRouter.swap, (address(usdg), address(nvda), 460e6, 1.9e18))
        );
        swaps[1] = IRouteExecutor.Swap(
            address(honest),
            address(usdg),
            0,
            abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), address(aapl), 1.5e18))
        );

        vm.expectRevert(
            abi.encodeWithSelector(IRouteExecutor.InsufficientConstituent.selector, address(nvda), 1.9e18, 2e18)
        );
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, alice, block.timestamp);
    }

    /// The allow-list is the boundary: none of the above is reachable through a router governance has not
    /// admitted, whatever calldata the front end supplies.
    function test_RevertWhen_RouterIsNotAllowListed() public {
        GreedyRouter evil = new GreedyRouter();
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](1);
        swaps[0] =
            IRouteExecutor.Swap(address(evil), address(usdg), 0, abi.encodeCall(GreedyRouter.swap, (address(usdg))));

        vm.expectRevert(abi.encodeWithSelector(IRouteExecutor.RouterNotAllowed.selector, address(evil)));
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, alice, block.timestamp);
    }

    // ---------------------------------------------------------------- helpers

    function _allow(address router) internal {
        vm.prank(protocolOwner);
        zap.setRouter(router, true);
    }

    function _seedShares() internal {
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = IRouteExecutor.Swap(
            address(honest),
            address(usdg),
            0,
            abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), address(nvda), 2e18))
        );
        swaps[1] = IRouteExecutor.Swap(
            address(honest),
            address(usdg),
            0,
            abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), address(aapl), 1.5e18))
        );
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, alice, block.timestamp);
    }

    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), 0.2e18);
        recipe[1] = IBasketToken.Constituent(address(aapl), 0.15e18);
    }
}
