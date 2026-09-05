// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BasketToken} from "../src/BasketToken.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {MockFactory} from "./mocks/MockFactory.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

contract BasketTokenTest is Test {
    uint256 internal constant NVDA_UNITS = 0.2e18;
    uint256 internal constant AAPL_UNITS = 0.15e18;
    uint16 internal constant MINT_FEE_BPS = 10;
    uint16 internal constant REDEEM_FEE_BPS = 10;

    MockFactory internal factory;
    BasketToken internal basket;
    MockStockToken internal nvda;
    MockStockToken internal aapl;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        factory = new MockFactory(protocolOwner, treasury);
        basket = factory.deploy("NodusLayer Tech", "TECH", _recipe(), MINT_FEE_BPS, REDEEM_FEE_BPS);

        nvda.mint(alice, 1000e18);
        aapl.mint(alice, 1000e18);
        vm.startPrank(alice);
        nvda.approve(address(basket), type(uint256).max);
        aapl.approve(address(basket), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- construction

    function test_Constructor_StoresRecipeAndFees() public view {
        IBasketToken.Constituent[] memory stored = basket.constituents();
        assertEq(stored.length, 2);
        assertEq(stored[0].token, address(nvda));
        assertEq(stored[0].units, NVDA_UNITS);
        assertEq(stored[1].token, address(aapl));
        assertEq(stored[1].units, AAPL_UNITS);
        assertEq(basket.factory(), address(factory));
        assertEq(basket.mintFeeBps(), MINT_FEE_BPS);
        assertEq(basket.redeemFeeBps(), REDEEM_FEE_BPS);
        assertEq(basket.feeRecipient(), treasury);
        assertEq(basket.decimals(), 18);
    }

    function test_RevertWhen_RecipeHasSingleConstituent() public {
        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](1);
        recipe[0] = IBasketToken.Constituent(address(nvda), NVDA_UNITS);

        vm.expectRevert(IBasketToken.InvalidRecipe.selector);
        factory.deploy("x", "X", recipe, 0, 0);
    }

    function test_RevertWhen_RecipeExceedsMaxConstituents() public {
        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](17);
        for (uint256 i; i < recipe.length; ++i) {
            recipe[i] = IBasketToken.Constituent(address(new MockStockToken("t", "T")), 1e18);
        }

        vm.expectRevert(IBasketToken.InvalidRecipe.selector);
        factory.deploy("x", "X", recipe, 0, 0);
    }

    function test_RevertWhen_RecipeHasZeroUnits() public {
        IBasketToken.Constituent[] memory recipe = _recipe();
        recipe[1].units = 0;

        vm.expectRevert(IBasketToken.InvalidRecipe.selector);
        factory.deploy("x", "X", recipe, 0, 0);
    }

    function test_RevertWhen_RecipeHasDuplicateToken() public {
        IBasketToken.Constituent[] memory recipe = _recipe();
        recipe[1].token = address(nvda);

        vm.expectRevert(IBasketToken.InvalidRecipe.selector);
        factory.deploy("x", "X", recipe, 0, 0);
    }

    function test_RevertWhen_FeeAboveCap() public {
        vm.expectRevert(IBasketToken.FeeTooHigh.selector);
        factory.deploy("x", "X", _recipe(), 101, 0);
    }

    /// Fee shares go to the factory's treasury, read live, so moving it is one governance action rather
    /// than one per basket.
    function test_FeeRecipient_FollowsTheFactoryTreasury() public {
        assertEq(basket.feeRecipient(), treasury);
        factory.setTreasury(bob);
        assertEq(basket.feeRecipient(), bob);

        vm.prank(alice);
        basket.mint(10e18, alice);
        assertEq(basket.balanceOf(bob), 0.01e18);
        assertEq(basket.balanceOf(treasury), 0);
    }

    // ---------------------------------------------------------------- retirement

    function test_RevertWhen_MintingARetiredBasket() public {
        factory.setRetired(address(basket), true);

        vm.expectRevert(IBasketToken.Retired.selector);
        vm.prank(alice);
        basket.mint(10e18, alice);
    }

    /// Redemption is the one path that must survive everything, retirement included.
    function test_Redeem_SurvivesRetirement() public {
        vm.prank(alice);
        basket.mint(10e18, alice);
        factory.setRetired(address(basket), true);

        vm.prank(alice);
        basket.redeem(5e18, bob);
        assertEq(nvda.balanceOf(bob), 0.999e18);
        assertEq(aapl.balanceOf(bob), 0.74925e18);
    }

    // ---------------------------------------------------------------- mint

    function test_PreviewMint_ReturnsCeilAmountsAndNetShares() public view {
        (uint256[] memory amountsIn, uint256 netShares) = basket.previewMint(10e18);
        assertEq(amountsIn[0], 2e18);
        assertEq(amountsIn[1], 1.5e18);
        assertEq(netShares, 9.99e18);
    }

    function test_Mint_PullsConstituentsAndMintsNetShares() public {
        vm.prank(alice);
        uint256 netShares = basket.mint(10e18, bob);

        assertEq(netShares, 9.99e18);
        assertEq(basket.balanceOf(bob), 9.99e18);
        assertEq(basket.balanceOf(treasury), 0.01e18);
        assertEq(basket.totalSupply(), 10e18);
        assertEq(nvda.balanceOf(address(basket)), 2e18);
        assertEq(aapl.balanceOf(address(basket)), 1.5e18);
        assertEq(nvda.balanceOf(alice), 998e18);
        assertEq(aapl.balanceOf(alice), 998.5e18);
    }

    function test_Mint_EmitsMinted() public {
        vm.expectEmit(address(basket));
        emit IBasketToken.Minted(alice, bob, 10e18, 0.01e18);

        vm.prank(alice);
        basket.mint(10e18, bob);
    }

    function test_Mint_RoundsConstituentAmountsUp() public {
        vm.prank(alice);
        basket.mint(1, bob);

        assertEq(nvda.balanceOf(address(basket)), 1);
        assertEq(aapl.balanceOf(address(basket)), 1);
        assertEq(basket.balanceOf(bob), 1);
    }

    function test_RevertWhen_MintZeroShares() public {
        vm.expectRevert(IBasketToken.ZeroShares.selector);
        vm.prank(alice);
        basket.mint(0, bob);
    }

    // ---------------------------------------------------------------- redeem

    function test_PreviewRedeem_ReturnsFloorAmountsAndNetShares() public view {
        (uint256[] memory amountsOut, uint256 netShares) = basket.previewRedeem(5e18);
        assertEq(amountsOut[0], 0.999e18);
        assertEq(amountsOut[1], 0.74925e18);
        assertEq(netShares, 4.995e18);
    }

    function test_Redeem_BurnsNetSharesAndPaysFloorAmounts() public {
        vm.startPrank(alice);
        basket.mint(10e18, alice);
        uint256[] memory amountsOut = basket.redeem(5e18, bob);
        vm.stopPrank();

        assertEq(amountsOut[0], 0.999e18);
        assertEq(amountsOut[1], 0.74925e18);
        assertEq(nvda.balanceOf(bob), 0.999e18);
        assertEq(aapl.balanceOf(bob), 0.74925e18);
        assertEq(basket.balanceOf(alice), 4.99e18);
        assertEq(basket.balanceOf(treasury), 0.015e18);
        assertEq(basket.totalSupply(), 5.005e18);
    }

    function test_Redeem_EmitsRedeemed() public {
        vm.prank(alice);
        basket.mint(10e18, alice);

        vm.expectEmit(address(basket));
        emit IBasketToken.Redeemed(alice, bob, 5e18, 0.005e18, 0);

        vm.prank(alice);
        basket.redeem(5e18, bob);
    }

    function test_Redeem_RoundsConstituentAmountsDown() public {
        vm.startPrank(alice);
        basket.mint(3, alice);
        uint256[] memory amountsOut = basket.redeem(3, bob);
        vm.stopPrank();

        assertEq(amountsOut[0], 0);
        assertEq(amountsOut[1], 0);
        assertEq(nvda.balanceOf(address(basket)), 1);
        assertEq(basket.totalSupply(), 0);
    }

    function test_RevertWhen_RedeemZeroShares() public {
        vm.expectRevert(IBasketToken.ZeroShares.selector);
        vm.prank(alice);
        basket.redeem(0, bob);
    }

    function test_Redeem_RevertsWhenConstituentIsPaused() public {
        vm.prank(alice);
        basket.mint(10e18, alice);
        nvda.setPaused(true);

        vm.expectRevert(MockStockToken.EnforcedPause.selector);
        vm.prank(alice);
        basket.redeem(5e18, bob);
    }

    // ---------------------------------------------------------------- skip & claim

    function test_RedeemWithSkip_RecordsClaimForSkippedToken() public {
        vm.prank(alice);
        basket.mint(10e18, alice);
        nvda.setPaused(true);

        vm.prank(alice);
        uint256[] memory amountsOut = basket.redeemWithSkip(5e18, bob, 1);

        assertEq(amountsOut[0], 0.999e18);
        assertEq(amountsOut[1], 0.74925e18);
        assertEq(nvda.balanceOf(bob), 0);
        assertEq(aapl.balanceOf(bob), 0.74925e18);
        assertEq(basket.claimable(bob, address(nvda)), 0.999e18);
        assertEq(basket.totalClaimable(address(nvda)), 0.999e18);
        assertEq(nvda.balanceOf(address(basket)), 2e18);
    }

    function test_RedeemWithSkip_EmitsClaimRecorded() public {
        vm.prank(alice);
        basket.mint(10e18, alice);

        vm.expectEmit(address(basket));
        emit IBasketToken.ClaimRecorded(bob, address(nvda), 0.999e18);

        vm.prank(alice);
        basket.redeemWithSkip(5e18, bob, 1);
    }

    function test_Claim_TransfersRecordedAmountOnce() public {
        vm.prank(alice);
        basket.mint(10e18, alice);
        nvda.setPaused(true);
        vm.prank(alice);
        basket.redeemWithSkip(5e18, bob, 1);
        nvda.setPaused(false);

        vm.prank(bob);
        uint256 amount = basket.claim(address(nvda), bob);

        assertEq(amount, 0.999e18);
        assertEq(nvda.balanceOf(bob), 0.999e18);
        assertEq(basket.claimable(bob, address(nvda)), 0);
        assertEq(basket.totalClaimable(address(nvda)), 0);

        vm.expectRevert(IBasketToken.NothingToClaim.selector);
        vm.prank(bob);
        basket.claim(address(nvda), bob);
    }

    function test_RevertWhen_SkipMaskExceedsRecipe() public {
        vm.prank(alice);
        basket.mint(10e18, alice);

        vm.expectRevert(IBasketToken.InvalidSkipMask.selector);
        vm.prank(alice);
        basket.redeemWithSkip(5e18, bob, 1 << 2);
    }

    /// A contract redeeming on a holder's behalf receives the paid legs itself and names the holder as the
    /// claimant, so the frozen leg is owed to the person, not to the contract.
    function test_RedeemWithSkipFor_CreditsTheClaimantNotTheRecipient() public {
        vm.prank(alice);
        basket.mint(10e18, alice);
        aapl.setPaused(true);

        vm.expectEmit(address(basket));
        emit IBasketToken.ClaimRecorded(alice, address(aapl), 0.74925e18);
        vm.prank(alice);
        uint256[] memory amountsOut = basket.redeemWithSkipFor(5e18, bob, alice, 1 << 1);

        assertEq(amountsOut[1], 0.74925e18);
        assertEq(nvda.balanceOf(bob), 0.999e18);
        assertEq(basket.claimable(alice, address(aapl)), 0.74925e18);
        assertEq(basket.claimable(bob, address(aapl)), 0);
    }

    function test_RevertWhen_RedeemWithSkipForNamesNoClaimant() public {
        vm.prank(alice);
        basket.mint(10e18, alice);

        vm.expectRevert(IBasketToken.ZeroAddress.selector);
        vm.prank(alice);
        basket.redeemWithSkipFor(5e18, bob, address(0), 1);
    }

    function test_RevertWhen_RedeemWithSkipForMaskExceedsRecipe() public {
        vm.prank(alice);
        basket.mint(10e18, alice);

        vm.expectRevert(IBasketToken.InvalidSkipMask.selector);
        vm.prank(alice);
        basket.redeemWithSkipFor(5e18, bob, alice, 1 << 2);
    }

    // ---------------------------------------------------------------- fees

    function test_SetFees_ByProtocolOwnerUpdatesValues() public {
        vm.expectEmit(address(basket));
        emit IBasketToken.FeesUpdated(20, 30);

        vm.prank(protocolOwner);
        basket.setFees(20, 30);

        assertEq(basket.mintFeeBps(), 20);
        assertEq(basket.redeemFeeBps(), 30);
        assertEq(basket.feeRecipient(), treasury, "fees move, the recipient does not");
    }

    function test_RevertWhen_SetFeesByStranger() public {
        vm.expectRevert(IBasketToken.Unauthorized.selector);
        vm.prank(alice);
        basket.setFees(20, 30);
    }

    function test_RevertWhen_SetFeesAboveCap() public {
        vm.expectRevert(IBasketToken.FeeTooHigh.selector);
        vm.prank(protocolOwner);
        basket.setFees(0, 101);
    }

    // ---------------------------------------------------------------- remaining branches

    function test_ConstituentCount_ReturnsRecipeLength() public view {
        assertEq(basket.constituentCount(), 2);
    }

    function test_RevertWhen_RecipeHasZeroAddressToken() public {
        IBasketToken.Constituent[] memory recipe = _recipe();
        recipe[0].token = address(0);

        vm.expectRevert(IBasketToken.InvalidRecipe.selector);
        factory.deploy("x", "X", recipe, 0, 0);
    }

    function test_RevertWhen_MintToZeroAddress() public {
        vm.expectRevert(IBasketToken.ZeroAddress.selector);
        vm.prank(alice);
        basket.mint(1e18, address(0));
    }

    function test_RevertWhen_RedeemToZeroAddress() public {
        vm.prank(alice);
        basket.mint(10e18, alice);

        vm.expectRevert(IBasketToken.ZeroAddress.selector);
        vm.prank(alice);
        basket.redeem(1e18, address(0));
    }

    function test_RevertWhen_ClaimToZeroAddress() public {
        vm.expectRevert(IBasketToken.ZeroAddress.selector);
        vm.prank(alice);
        basket.claim(address(nvda), address(0));
    }

    function test_MintAndRedeem_WithZeroFeesMoveNoShareFees() public {
        vm.prank(protocolOwner);
        basket.setFees(0, 0);

        vm.startPrank(alice);
        uint256 netShares = basket.mint(10e18, alice);
        basket.redeem(10e18, bob);
        vm.stopPrank();

        assertEq(netShares, 10e18);
        assertEq(basket.balanceOf(treasury), 0);
        assertEq(basket.totalSupply(), 0);
        assertEq(nvda.balanceOf(bob), 2e18);
    }

    // ---------------------------------------------------------------- invariants

    function testFuzz_BackingCoversSupplyAndClaims(uint96 mintShares, uint96 redeemShares, bool skipNvda) public {
        mintShares = uint96(bound(mintShares, 1, 1000e18));

        vm.startPrank(alice);
        uint256 netShares = basket.mint(mintShares, alice);
        redeemShares = uint96(bound(redeemShares, 0, netShares));
        if (redeemShares > 0) basket.redeemWithSkip(redeemShares, bob, skipNvda ? 1 : 0);
        vm.stopPrank();

        _assertBacked();
    }

    function _assertBacked() internal view {
        IBasketToken.Constituent[] memory recipe = basket.constituents();
        uint256 supply = basket.totalSupply();
        for (uint256 i; i < recipe.length; ++i) {
            uint256 balance = IERC20(recipe[i].token).balanceOf(address(basket));
            uint256 owed = basket.totalClaimable(recipe[i].token);
            assertGe(balance * 1e18, supply * recipe[i].units + owed * 1e18);
        }
    }

    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), NVDA_UNITS);
        recipe[1] = IBasketToken.Constituent(address(aapl), AAPL_UNITS);
    }
}
