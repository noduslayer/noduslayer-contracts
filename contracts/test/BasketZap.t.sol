// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketFactory} from "../src/interfaces/IBasketFactory.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IBasketZap} from "../src/interfaces/IBasketZap.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

contract BasketZapTest is Test {
    uint16 internal constant ZAP_FEE_BPS = 20;
    uint256 internal constant NVDA_PRICE = 230e6;
    uint256 internal constant AAPL_PRICE = 328e6;

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketToken internal basket;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockERC20 internal usdg;
    MockRouter internal router;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockAggregator feed = new MockAggregator(8, 100e8);

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        zap = new BasketZap(protocolOwner, factory, treasury, ZAP_FEE_BPS);

        router = new MockRouter();
        router.setPrice(address(nvda), NVDA_PRICE);
        router.setPrice(address(aapl), AAPL_PRICE);
        nvda.mint(address(router), 1000e18);
        aapl.mint(address(router), 1000e18);
        usdg.mint(address(router), 1_000_000e6);

        vm.startPrank(protocolOwner);
        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        basket = BasketToken(factory.createBasket("NodusLayer Tech", "TECH", _recipe(), 10, 10));
        zap.setRouter(address(router), true);
        vm.stopPrank();

        usdg.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdg.approve(address(zap), type(uint256).max);
        basket.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- zapMint

    function test_ZapMint_BuysConstituentsAndMintsShares() public {
        vm.prank(alice);
        uint256 netShares =
            zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);

        assertEq(netShares, 9.99e18);
        assertEq(basket.balanceOf(bob), 9.99e18);
        assertEq(basket.balanceOf(treasury), 0.01e18);
        assertEq(usdg.balanceOf(treasury), 2e6);
        assertEq(usdg.balanceOf(alice), 9046e6);
        _assertZapEmpty();
    }

    function test_ZapMint_EmitsZapMinted() public {
        vm.expectEmit(address(zap));
        emit IBasketZap.ZapMinted(address(basket), alice, bob, address(usdg), 1000e6, 10e18, 9.99e18, 2e6);

        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);
    }

    function test_ZapMint_RefundsExcessConstituentsAndInput() public {
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1200e6, 10e18, _mintSwaps(2.5e18, 1.5e18), bob, block.timestamp);

        assertEq(nvda.balanceOf(alice), 0.5e18);
        assertEq(usdg.balanceOf(alice), 8930.6e6);
        _assertZapEmpty();
    }

    function test_ZapMint_LeavesNoRouterAllowance() public {
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);

        assertEq(usdg.allowance(address(zap), address(router)), 0);
    }

    /// The zap keeps a standing allowance to the basket to avoid re-approving on every mint. It is only
    /// reachable while the zap is msg.sender, and the zap holds nothing between transactions.
    function test_ZapMint_KeepsStandingBasketAllowance() public {
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);

        assertEq(nvda.allowance(address(zap), address(basket)), type(uint256).max);
        assertEq(aapl.allowance(address(zap), address(basket)), type(uint256).max);
        _assertZapEmpty();
    }

    function test_RevertWhen_AttackerMintsAgainstZapBasketAllowance() public {
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);

        address attacker = makeAddr("attacker");
        vm.expectRevert();
        vm.prank(attacker);
        basket.mint(1e18, attacker);

        assertEq(basket.balanceOf(attacker), 0);
        assertEq(nvda.balanceOf(attacker), 0);
        _assertZapEmpty();
    }

    function test_RevertWhen_ZapMintRouterNotAllowed() public {
        MockRouter rogue = new MockRouter();
        IBasketZap.Swap[] memory swaps = _mintSwaps(2e18, 1.5e18);
        swaps[0].router = address(rogue);

        vm.expectRevert(abi.encodeWithSelector(IBasketZap.RouterNotAllowed.selector, address(rogue)));
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, bob, block.timestamp);
    }

    function test_RevertWhen_ZapMintUnknownBasket() public {
        address fake = makeAddr("fake");

        vm.expectRevert(abi.encodeWithSelector(IBasketZap.UnknownBasket.selector, fake));
        vm.prank(alice);
        zap.zapMint(fake, address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);
    }

    function test_RevertWhen_ZapMintExpired() public {
        vm.expectRevert(IBasketZap.Expired.selector);
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp - 1);
    }

    function test_RevertWhen_ZapMintUnderbuysConstituent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IBasketZap.InsufficientConstituent.selector, address(nvda), 1.9e18, 2e18)
        );
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(1.9e18, 1.5e18), bob, block.timestamp);
    }

    function test_RevertWhen_ZapMintWhilePaused() public {
        vm.prank(protocolOwner);
        zap.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);
    }

    // ---------------------------------------------------------------- zapRedeem

    function test_ZapRedeem_SellsConstituentsAndPaysTokenOut() public {
        _seedShares();

        vm.prank(alice);
        uint256 amountOut = zap.zapRedeem(
            address(basket), 5e18, address(usdg), 470e6, _redeemSwaps(0.999e18, 0.74925e18), bob, block.timestamp
        );

        assertEq(amountOut, 474_572_952);
        assertEq(usdg.balanceOf(bob), 474_572_952);
        assertEq(usdg.balanceOf(treasury), 2e6 + 951_048);
        assertEq(basket.balanceOf(alice), 4.99e18);
        assertEq(basket.balanceOf(treasury), 0.015e18);
        _assertZapEmpty();
    }

    function test_ZapRedeem_EmitsZapRedeemed() public {
        _seedShares();

        vm.expectEmit(address(zap));
        emit IBasketZap.ZapRedeemed(address(basket), alice, bob, address(usdg), 5e18, 474_572_952, 951_048);

        vm.prank(alice);
        zap.zapRedeem(
            address(basket), 5e18, address(usdg), 470e6, _redeemSwaps(0.999e18, 0.74925e18), bob, block.timestamp
        );
    }

    function test_ZapRedeem_RefundsUnsoldConstituents() public {
        _seedShares();
        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](1);
        swaps[0] = _sell(address(nvda), 0.999e18);

        vm.prank(alice);
        uint256 amountOut = zap.zapRedeem(address(basket), 5e18, address(usdg), 200e6, swaps, bob, block.timestamp);

        assertEq(amountOut, 229_310_460);
        assertEq(aapl.balanceOf(alice), 0.74925e18);
        _assertZapEmpty();
    }

    function test_RevertWhen_ZapRedeemBelowMinOut() public {
        _seedShares();

        vm.expectRevert(abi.encodeWithSelector(IBasketZap.InsufficientOutput.selector, 474_572_952, 500e6));
        vm.prank(alice);
        zap.zapRedeem(
            address(basket), 5e18, address(usdg), 500e6, _redeemSwaps(0.999e18, 0.74925e18), bob, block.timestamp
        );
    }

    function test_RevertWhen_ZapRedeemUnknownBasket() public {
        address fake = makeAddr("fake");

        vm.expectRevert(abi.encodeWithSelector(IBasketZap.UnknownBasket.selector, fake));
        vm.prank(alice);
        zap.zapRedeem(fake, 5e18, address(usdg), 0, _redeemSwaps(0.999e18, 0.74925e18), bob, block.timestamp);
    }

    // ---------------------------------------------------------------- admin

    function test_SetRouter_UpdatesAllowlist() public {
        vm.expectEmit(address(zap));
        emit IBasketZap.RouterUpdated(address(router), false);

        vm.prank(protocolOwner);
        zap.setRouter(address(router), false);
        assertFalse(zap.isRouter(address(router)));
    }

    function test_RevertWhen_SetRouterByStranger() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        zap.setRouter(address(router), false);
    }

    function test_SetFee_RejectsAboveCap() public {
        vm.startPrank(protocolOwner);
        zap.setFee(50);
        assertEq(zap.feeBps(), 50);

        vm.expectRevert(IBasketZap.FeeTooHigh.selector);
        zap.setFee(51);
        vm.stopPrank();
    }

    function test_Sweep_SendsStuckBalance() public {
        usdg.mint(address(zap), 5e6);

        vm.prank(protocolOwner);
        zap.sweep(address(usdg), bob);
        assertEq(usdg.balanceOf(bob), 5e6);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        zap.sweep(address(usdg), alice);
    }

    // ---------------------------------------------------------------- remaining branches

    function test_RevertWhen_ZapMintZeroInput() public {
        vm.expectRevert(IBasketZap.ZeroAmount.selector);
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 0, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);
    }

    function test_RevertWhen_ZapMintZeroShares() public {
        vm.expectRevert(IBasketZap.ZeroAmount.selector);
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 0, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);
    }

    function test_RevertWhen_ZapRedeemZeroShares() public {
        vm.expectRevert(IBasketZap.ZeroAmount.selector);
        vm.prank(alice);
        zap.zapRedeem(address(basket), 0, address(usdg), 0, _redeemSwaps(1, 1), bob, block.timestamp);
    }

    function test_RevertWhen_ZapRedeemToZeroAddress() public {
        _seedShares();

        vm.expectRevert(IBasketZap.ZeroAddress.selector);
        vm.prank(alice);
        zap.zapRedeem(address(basket), 5e18, address(usdg), 0, _redeemSwaps(1, 1), address(0), block.timestamp);
    }

    function test_ZapMint_SupportsPrefundedRouters() public {
        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](2);
        swaps[0] = IBasketZap.Swap({
            router: address(router),
            sellToken: address(usdg),
            prefund: 460e6,
            data: abi.encodeCall(MockRouter.swapExactOutputPrefunded, (address(nvda), 2e18))
        });
        swaps[1] = IBasketZap.Swap({
            router: address(router),
            sellToken: address(usdg),
            prefund: 492e6,
            data: abi.encodeCall(MockRouter.swapExactOutputPrefunded, (address(aapl), 1.5e18))
        });

        vm.prank(alice);
        uint256 netShares = zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, bob, block.timestamp);

        assertEq(netShares, 9.99e18);
        assertEq(usdg.balanceOf(alice), 9046e6);
        _assertZapEmpty();
    }

    function test_Unpause_RestoresZap() public {
        vm.startPrank(protocolOwner);
        zap.pause();
        zap.unpause();
        vm.stopPrank();

        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), bob, block.timestamp);
        assertEq(basket.balanceOf(bob), 9.99e18);
    }

    function test_SetTreasury_UpdatesRecipient() public {
        vm.expectEmit(address(zap));
        emit IBasketZap.TreasuryUpdated(bob);

        vm.prank(protocolOwner);
        zap.setTreasury(bob);
        assertEq(zap.treasury(), bob);
    }

    function test_RevertWhen_SetTreasuryToZero() public {
        vm.expectRevert(IBasketZap.ZeroAddress.selector);
        vm.prank(protocolOwner);
        zap.setTreasury(address(0));
    }

    function test_RevertWhen_SetRouterToZero() public {
        vm.expectRevert(IBasketZap.ZeroAddress.selector);
        vm.prank(protocolOwner);
        zap.setRouter(address(0), true);
    }

    function test_RevertWhen_SweepToZero() public {
        vm.expectRevert(IBasketZap.ZeroAddress.selector);
        vm.prank(protocolOwner);
        zap.sweep(address(usdg), address(0));
    }

    function test_RevertWhen_ConstructedWithoutFactory() public {
        vm.expectRevert(IBasketZap.ZeroAddress.selector);
        new BasketZap(protocolOwner, IBasketFactory(address(0)), treasury, 20);
    }

    // ---------------------------------------------------------------- multi-leg execution

    function test_ZapMint_HandlesRepeatedLegsOnSameSellTokenAndRouter() public {
        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](4);
        swaps[0] = _buy(address(nvda), 1e18);
        swaps[1] = _buy(address(nvda), 1e18);
        swaps[2] = _buy(address(aapl), 0.75e18);
        swaps[3] = _buy(address(aapl), 0.75e18);

        vm.prank(alice);
        uint256 netShares = zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, bob, block.timestamp);

        assertEq(netShares, 9.99e18);
        assertEq(usdg.allowance(address(zap), address(router)), 0);
        _assertZapEmpty();
    }

    function test_ZapRedeem_HandlesInterleavedSellTokens() public {
        _seedShares();
        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](4);
        swaps[0] = _sell(address(nvda), 0.5e18);
        swaps[1] = _sell(address(aapl), 0.3e18);
        swaps[2] = _sell(address(nvda), 0.499e18);
        swaps[3] = _sell(address(aapl), 0.44925e18);

        vm.prank(alice);
        uint256 amountOut = zap.zapRedeem(address(basket), 5e18, address(usdg), 400e6, swaps, bob, block.timestamp);

        assertEq(amountOut, 474_572_952);
        assertEq(nvda.allowance(address(zap), address(router)), 0);
        assertEq(aapl.allowance(address(zap), address(router)), 0);
        _assertZapEmpty();
    }

    function test_ZapMint_ResetsAllowanceWhenLegsSwitchRouter() public {
        MockRouter second = new MockRouter();
        second.setPrice(address(aapl), AAPL_PRICE);
        aapl.mint(address(second), 100e18);
        vm.prank(protocolOwner);
        zap.setRouter(address(second), true);

        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](2);
        swaps[0] = _buy(address(nvda), 2e18);
        swaps[1] = IBasketZap.Swap({
            router: address(second),
            sellToken: address(usdg),
            prefund: 0,
            data: abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), address(aapl), 1.5e18))
        });

        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, swaps, bob, block.timestamp);

        assertEq(usdg.allowance(address(zap), address(router)), 0);
        assertEq(usdg.allowance(address(zap), address(second)), 0);
        _assertZapEmpty();
    }

    // ---------------------------------------------------------------- helpers

    function _seedShares() internal {
        vm.prank(alice);
        zap.zapMint(address(basket), address(usdg), 1000e6, 10e18, _mintSwaps(2e18, 1.5e18), alice, block.timestamp);
    }

    function _mintSwaps(uint256 nvdaOut, uint256 aaplOut) internal view returns (IBasketZap.Swap[] memory swaps) {
        swaps = new IBasketZap.Swap[](2);
        swaps[0] = _buy(address(nvda), nvdaOut);
        swaps[1] = _buy(address(aapl), aaplOut);
    }

    function _redeemSwaps(uint256 nvdaIn, uint256 aaplIn) internal view returns (IBasketZap.Swap[] memory swaps) {
        swaps = new IBasketZap.Swap[](2);
        swaps[0] = _sell(address(nvda), nvdaIn);
        swaps[1] = _sell(address(aapl), aaplIn);
    }

    function _buy(address token, uint256 amountOut) internal view returns (IBasketZap.Swap memory) {
        return IBasketZap.Swap({
            router: address(router),
            sellToken: address(usdg),
            prefund: 0,
            data: abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), token, amountOut))
        });
    }

    function _sell(address token, uint256 amountIn) internal view returns (IBasketZap.Swap memory) {
        return IBasketZap.Swap({
            router: address(router),
            sellToken: token,
            prefund: 0,
            data: abi.encodeCall(MockRouter.swapExactInput, (token, address(usdg), amountIn))
        });
    }

    function _assertZapEmpty() internal view {
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(nvda.balanceOf(address(zap)), 0);
        assertEq(aapl.balanceOf(address(zap)), 0);
        assertEq(basket.balanceOf(address(zap)), 0);
    }

    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), 0.2e18);
        recipe[1] = IBasketToken.Constituent(address(aapl), 0.15e18);
    }
}
