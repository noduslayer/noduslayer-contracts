// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketMigrator} from "../src/BasketMigrator.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketFactory} from "../src/interfaces/IBasketFactory.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IBasketZap} from "../src/interfaces/IBasketZap.sol";
import {IRouteExecutor} from "../src/interfaces/IRouteExecutor.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// The zap's second surface: the fee charged on what was spent rather than sent, exits that skip a frozen
/// leg, permits in place of approvals, ether in place of a token, and baskets the protocol has retired.
contract ZapFeaturesTest is Test {
    uint16 internal constant FEE_BPS = 20;
    uint256 internal constant NVDA_PRICE = 230e6;
    uint256 internal constant AAPL_PRICE = 328e6;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketMigrator internal migrator;
    BasketToken internal basket;
    BasketToken internal successor;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockERC20 internal usdg;
    MockWETH internal weth;
    MockRouter internal router;
    MockRouter internal ethRouter;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    uint256 internal alicePk = 0xA11CE;
    address internal alice = vm.addr(0xA11CE);
    address internal bob = makeAddr("bob");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        weth = new MockWETH();
        MockAggregator feed = new MockAggregator(8, 100e8);

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        zap = new BasketZap(protocolOwner, factory, treasury, FEE_BPS, IWETH(address(weth)));
        migrator = new BasketMigrator(protocolOwner, factory);

        // USDG-priced venue and an ether-priced one: NVDA 0.1 ETH, AAPL 0.05 ETH.
        router = new MockRouter();
        router.setPrice(address(nvda), NVDA_PRICE);
        router.setPrice(address(aapl), AAPL_PRICE);
        ethRouter = new MockRouter();
        ethRouter.setPrice(address(nvda), 0.1e18);
        ethRouter.setPrice(address(aapl), 0.05e18);
        for (uint256 i; i < 2; ++i) {
            MockRouter r = i == 0 ? router : ethRouter;
            nvda.mint(address(r), 1000e18);
            aapl.mint(address(r), 1000e18);
        }
        usdg.mint(address(router), 1_000_000e6);

        vm.startPrank(protocolOwner);
        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        basket = BasketToken(factory.createBasket("NodusLayer Tech", "TECH", _recipe(0.2e18, 0.15e18), 10, 10));
        successor = BasketToken(factory.createBasket("NodusLayer Tech v2", "TECH2", _recipe(0.25e18, 0.1e18), 10, 10));
        zap.setRouter(address(router), true);
        zap.setRouter(address(ethRouter), true);
        migrator.setRouter(address(router), true);
        vm.stopPrank();

        usdg.mint(alice, 10_000e6);
        vm.deal(alice, 10 ether);
    }

    // ---------------------------------------------------------------- fee on what was spent

    /// The swaps cost 952 USDG of the 1,000 sent. The fee is 20 bps of 952, not of 1,000, and the rest of
    /// the 1,000 comes back untaxed.
    function test_Fee_IsChargedOnTheSpendNotTheInput() public {
        _approveZap();
        vm.prank(alice);
        zap.zapMint(
            address(basket),
            address(usdg),
            1000e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp
        );

        assertEq(usdg.balanceOf(treasury), 1_904_000, "20 bps of 952 USDG");
        assertEq(usdg.balanceOf(alice), 10_000e6 - 952e6 - 1_904_000, "spend plus fee on the spend, nothing else");
        assertEq(usdg.balanceOf(address(zap)), 0);
    }

    /// Sending exactly the spend leaves nothing to pay the fee from. The quote service sizes the input as
    /// spend plus fee; a caller who does not is told what would have been enough.
    function test_RevertWhen_InputCoversTheSwapsButNotTheFee() public {
        _approveZap();
        vm.expectRevert(abi.encodeWithSelector(IBasketZap.InsufficientInput.selector, 952e6, 952e6 + 1_904_000));
        vm.prank(alice);
        zap.zapMint(
            address(basket),
            address(usdg),
            952e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp
        );
    }

    function test_Fee_InputSizedAsSpendPlusFeeLeavesNothingBehind() public {
        _approveZap();
        vm.prank(alice);
        zap.zapMint(
            address(basket),
            address(usdg),
            952e6 + 1_904_000,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp
        );

        assertEq(usdg.balanceOf(alice), 10_000e6 - 952e6 - 1_904_000);
        assertEq(usdg.balanceOf(address(zap)), 0);
    }

    // ---------------------------------------------------------------- exiting around a frozen leg

    /// The issuer freezes NVDA. zapRedeem cannot move it and reverts; zapRedeemWithSkip sells the AAPL,
    /// pays out, and leaves the NVDA claimable by the holder — not by the zap — once it thaws.
    function test_ZapRedeemWithSkip_ExitsAroundAFrozenLegAndCreditsTheHolder() public {
        _seedShares();
        nvda.setPaused(true);

        vm.expectRevert();
        vm.prank(alice);
        zap.zapRedeem(
            address(basket), 5e18, address(usdg), 0, _sellOnly(address(aapl), 0.74925e18), bob, block.timestamp
        );

        vm.prank(alice);
        uint256 out = zap.zapRedeemWithSkip(
            address(basket), 5e18, address(usdg), 0, 1, _sellOnly(address(aapl), 0.74925e18), bob, block.timestamp
        );

        // 0.74925 AAPL at 328 is 245.754 USDG, less 20 bps.
        assertEq(out, 245_754_000 - 491_508);
        assertEq(usdg.balanceOf(bob), out);
        assertEq(basket.claimable(bob, address(nvda)), 0.999e18, "the frozen leg belongs to the recipient");
        assertEq(basket.claimable(address(zap), address(nvda)), 0, "and not to the zap");
        assertEq(nvda.balanceOf(address(zap)), 0);

        nvda.setPaused(false);
        vm.prank(bob);
        basket.claim(address(nvda), bob);
        assertEq(nvda.balanceOf(bob), 0.999e18);
    }

    function test_RevertWhen_SkipMaskNamesAConstituentTheBasketLacks() public {
        _seedShares();
        vm.expectRevert(IBasketToken.InvalidSkipMask.selector);
        vm.prank(alice);
        zap.zapRedeemWithSkip(
            address(basket), 5e18, address(usdg), 0, 4, new IRouteExecutor.Swap[](0), bob, block.timestamp
        );
    }

    // ---------------------------------------------------------------- permits

    function test_ZapMintWithPermit_NeedsNoPriorApproval() public {
        assertEq(usdg.allowance(alice, address(zap)), 0);
        IRouteExecutor.Permit memory p = _permit(usdg, address(zap), 1000e6, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 netShares = zap.zapMintWithPermit(
            address(basket),
            address(usdg),
            1000e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp,
            p
        );

        assertEq(netShares, 9.99e18);
        assertEq(basket.balanceOf(bob), 9.99e18);
        assertEq(usdg.allowance(alice, address(zap)), 0, "the whole permit is pulled");
        assertEq(usdg.balanceOf(alice), 10_000e6 - 952e6 - 1_904_000, "and the unspent part is transferred back");
    }

    /// Anyone who sees a permit can submit it first. The call must still go through, or a stranger could
    /// block every permit-based mint by racing it.
    function test_ZapMintWithPermit_SurvivesAFrontRunPermit() public {
        IRouteExecutor.Permit memory p = _permit(usdg, address(zap), 1000e6, block.timestamp + 1 hours);
        usdg.permit(alice, address(zap), p.value, p.deadline, p.v, p.r, p.s);
        assertEq(usdg.allowance(alice, address(zap)), 1000e6, "front-run permit already applied");

        vm.prank(alice);
        zap.zapMintWithPermit(
            address(basket),
            address(usdg),
            1000e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp,
            p
        );
        assertEq(basket.balanceOf(bob), 9.99e18);
    }

    function test_RevertWhen_PermitIsForTooLittle() public {
        IRouteExecutor.Permit memory p = _permit(usdg, address(zap), 500e6, block.timestamp + 1 hours);
        vm.expectRevert();
        vm.prank(alice);
        zap.zapMintWithPermit(
            address(basket),
            address(usdg),
            1000e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp,
            p
        );
    }

    function test_ZapRedeemWithPermit_SpendsSharesOnASignature() public {
        _seedShares();
        vm.prank(alice);
        basket.approve(address(zap), 0);
        IRouteExecutor.Permit memory p = _permit(basket, address(zap), 5e18, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 out = zap.zapRedeemWithPermit(
            address(basket), 5e18, address(usdg), 0, _redeemSwaps(0.999e18, 0.74925e18), bob, block.timestamp, p
        );
        assertEq(out, 474_572_952);
        assertEq(usdg.balanceOf(bob), out);
    }

    function test_MigrateWithPermit_MovesSharesOnASignature() public {
        _seedShares();
        assertEq(basket.allowance(alice, address(migrator)), 0);
        IRouteExecutor.Permit memory p = _permit(basket, address(migrator), 5e18, block.timestamp + 1 hours);

        // Five TECH shares pay out 0.999 NVDA and 0.74925 AAPL; TECH2 wants 0.25 NVDA and 0.1 AAPL per share.
        // 3.99 shares of it need 0.9975 NVDA and 0.399 AAPL: the surplus AAPL is refunded, nothing traded.
        vm.prank(alice);
        uint256 netShares = migrator.migrateWithPermit(
            address(basket),
            address(successor),
            5e18,
            3.99e18,
            3.9e18,
            new IRouteExecutor.Swap[](0),
            bob,
            block.timestamp,
            p
        );
        assertEq(successor.balanceOf(bob), netShares);
        assertGt(aapl.balanceOf(alice), 0, "the leg the new recipe needs less of comes back");
    }

    // ---------------------------------------------------------------- ether

    function test_ZapMintETH_WrapsBuysAndRefundsTheRestAsEther() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 netShares = zap.zapMintETH{value: 1 ether}(
            address(basket), 10e18, _mintSwaps(ethRouter, address(weth), 2e18, 1.5e18), bob, block.timestamp
        );

        // 2 NVDA at 0.1 and 1.5 AAPL at 0.05 is 0.275 ETH spent; 20 bps of that is the fee.
        uint256 spent = 0.275 ether;
        uint256 fee = spent * FEE_BPS / 10_000;
        assertEq(netShares, 9.99e18);
        assertEq(weth.balanceOf(treasury), fee, "fee in wrapped ether");
        assertEq(alice.balance, before - spent - fee, "the remainder came back as ether");
        assertEq(address(zap).balance, 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    function test_RevertWhen_EtherArrivesFromAnyoneButWETH() public {
        vm.expectRevert(IBasketZap.UnexpectedETH.selector);
        vm.prank(alice);
        (bool ok,) = address(zap).call{value: 1 ether}("");
        ok;
    }

    function test_RevertWhen_ZapMintETHSendsNothing() public {
        vm.expectRevert(IRouteExecutor.ZeroAmount.selector);
        vm.prank(alice);
        zap.zapMintETH{value: 0}(address(basket), 10e18, new IRouteExecutor.Swap[](0), bob, block.timestamp);
    }

    function test_RevertWhen_ConstructedWithoutWETH() public {
        vm.expectRevert(IRouteExecutor.ZeroAddress.selector);
        new BasketZap(protocolOwner, factory, treasury, FEE_BPS, IWETH(address(0)));
    }

    // ---------------------------------------------------------------- retirement

    function test_RetiredBasket_RefusesNewSharesEverywhereAndStillRedeems() public {
        _seedShares();
        vm.prank(protocolOwner);
        factory.retire(address(basket), address(successor));

        assertTrue(factory.isRetired(address(basket)));
        assertEq(factory.successorOf(address(basket)), address(successor));

        // In kind, through the zap, and as a migration target: no new shares.
        vm.expectRevert(IBasketToken.Retired.selector);
        vm.prank(alice);
        basket.mint(1e18, alice);

        _approveZap();
        vm.expectRevert(abi.encodeWithSelector(IRouteExecutor.BasketRetired.selector, address(basket)));
        vm.prank(alice);
        zap.zapMint(
            address(basket),
            address(usdg),
            1000e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            bob,
            block.timestamp
        );

        vm.startPrank(alice);
        successor.approve(address(migrator), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IRouteExecutor.BasketRetired.selector, address(basket)));
        migrator.migrate(
            address(successor), address(basket), 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp
        );
        vm.stopPrank();

        // Out is always open: in kind, through the zap, and into the successor.
        vm.startPrank(alice);
        basket.redeem(1e18, alice);
        zap.zapRedeem(
            address(basket), 1e18, address(usdg), 0, _redeemSwaps(0.1998e18, 0.14985e18), bob, block.timestamp
        );
        basket.approve(address(migrator), type(uint256).max);
        migrator.migrate(
            address(basket),
            address(successor),
            1e18,
            0.79e18,
            0.7e18,
            new IRouteExecutor.Swap[](0),
            alice,
            block.timestamp
        );
        vm.stopPrank();
        assertGt(successor.balanceOf(alice), 0);
    }

    function test_Retire_ValidatesItsArguments() public {
        vm.startPrank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(IBasketFactory.UnknownBasket.selector, bob));
        factory.retire(bob, address(0));

        vm.expectRevert(abi.encodeWithSelector(IBasketFactory.InvalidSuccessor.selector, address(basket)));
        factory.retire(address(basket), address(basket));

        vm.expectRevert(abi.encodeWithSelector(IBasketFactory.InvalidSuccessor.selector, bob));
        factory.retire(address(basket), bob);

        factory.retire(address(successor), address(0));
        vm.expectRevert(abi.encodeWithSelector(IBasketFactory.InvalidSuccessor.selector, address(successor)));
        factory.retire(address(basket), address(successor));
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(alice);
        factory.retire(address(basket), address(0));
    }

    function test_Retire_EmitsAndCanNameNoSuccessor() public {
        vm.expectEmit(address(factory));
        emit IBasketFactory.BasketRetired(address(basket), address(0));
        vm.prank(protocolOwner);
        factory.retire(address(basket), address(0));
        assertEq(factory.successorOf(address(basket)), address(0));
    }

    // ---------------------------------------------------------------- helpers

    function _approveZap() internal {
        vm.startPrank(alice);
        usdg.approve(address(zap), type(uint256).max);
        basket.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function _seedShares() internal {
        _approveZap();
        vm.prank(alice);
        zap.zapMint(
            address(basket),
            address(usdg),
            1000e6,
            10e18,
            _mintSwaps(router, address(usdg), 2e18, 1.5e18),
            alice,
            block.timestamp
        );
    }

    function _permit(ERC20Permit token, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (IRouteExecutor.Permit memory p)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, value, token.nonces(alice), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        return IRouteExecutor.Permit({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    function _mintSwaps(MockRouter r, address quote, uint256 nvdaOut, uint256 aaplOut)
        internal
        view
        returns (IRouteExecutor.Swap[] memory swaps)
    {
        swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = IRouteExecutor.Swap(
            address(r), quote, 0, abi.encodeCall(MockRouter.swapExactOutput, (quote, address(nvda), nvdaOut))
        );
        swaps[1] = IRouteExecutor.Swap(
            address(r), quote, 0, abi.encodeCall(MockRouter.swapExactOutput, (quote, address(aapl), aaplOut))
        );
    }

    function _redeemSwaps(uint256 nvdaIn, uint256 aaplIn) internal view returns (IRouteExecutor.Swap[] memory swaps) {
        swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = _sell(address(nvda), nvdaIn);
        swaps[1] = _sell(address(aapl), aaplIn);
    }

    function _sellOnly(address token, uint256 amountIn) internal view returns (IRouteExecutor.Swap[] memory swaps) {
        swaps = new IRouteExecutor.Swap[](1);
        swaps[0] = _sell(token, amountIn);
    }

    function _sell(address token, uint256 amountIn) internal view returns (IRouteExecutor.Swap memory) {
        return IRouteExecutor.Swap(
            address(router), token, 0, abi.encodeCall(MockRouter.swapExactInput, (token, address(usdg), amountIn))
        );
    }

    function _recipe(uint256 nvdaUnits, uint256 aaplUnits)
        internal
        view
        returns (IBasketToken.Constituent[] memory recipe)
    {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), nvdaUnits);
        recipe[1] = IBasketToken.Constituent(address(aapl), aaplUnits);
    }
}
