// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketLens} from "../src/BasketLens.sol";
import {BasketMigrator} from "../src/BasketMigrator.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {RehearsalFeed, RehearsalToken, RehearsalWETH} from "../script/RehearsalFixture.s.sol";

/// Walks the sequence docs/runbook.md prescribes, in order, against the rehearsal fixture contracts.
///
/// A runbook nobody has executed is a guess. Broadcasting is the one part this cannot cover, but everything
/// the operator does between deploying and holding a live basket is here, including the delay elapsing.
contract RehearsalTest is Test {
    uint256 internal constant DELAY = 2 days;
    bytes32 internal constant SALT = bytes32(0);

    TimelockController internal timelock;
    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketMigrator internal migrator;
    BasketLens internal lens;

    RehearsalToken[6] internal tokens;
    RehearsalFeed[6] internal feeds;
    string[6] internal symbols = ["NVDA", "AAPL", "MSFT", "GOOGL", "AMZN", "TSLA"];
    int256[6] internal prices = [int256(230e8), 328e8, 509e8, 342e8, 231e8, 383e8];

    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = new RehearsalToken(symbols[i], symbols[i]);
            feeds[i] = new RehearsalFeed(prices[i]);
        }
    }

    // ---------------------------------------------------------------- the runbook, in order

    function test_Rehearsal_FollowsTheRunbookEndToEnd() public {
        _deploy();

        // Step 1: the deployer owns nothing once the timelock has accepted.
        assertEq(registry.owner(), address(timelock));
        assertEq(factory.owner(), address(timelock));
        assertEq(zap.owner(), address(timelock));
        assertEq(migrator.owner(), address(timelock));
        assertFalse(zap.paused());
        assertFalse(migrator.paused());

        // Step 2: every constituent is listed and priceable.
        assertEq(registry.tokens().length, tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            assertTrue(registry.hasFeed(address(tokens[i])), symbols[i]);
        }

        // Step 3: a basket is created through the timelock, since createBasket is onlyOwner.
        BasketToken basket = _createBasketViaTimelock();
        assertTrue(factory.isBasket(address(basket)));
        assertEq(lens.unpricedCount(address(basket)), 0);
        (uint256 nav,) = lens.nav(address(basket));
        assertApproxEqRel(nav, 100e18, 0.01e18, "recipe should be worth its target NAV");

        // Step 4: a holder can mint and get out again in kind.
        _mintAndRedeem(basket);
    }

    /// The deployer holds ownership only between deploying and the timelock accepting. Announcing before
    /// that window closes would advertise a protocol one key still controls.
    function test_Rehearsal_DeployerIsStillOwnerBeforeAcceptance() public {
        _deployWithoutAcceptance();

        assertEq(registry.owner(), deployer);
        assertEq(registry.pendingOwner(), address(timelock));

        vm.expectRevert();
        vm.prank(multisig);
        factory.createBasket("Too early", "EARLY", _recipe(), 10, 10);
    }

    /// The delay is the control that matters. A rehearsal that skipped it would prove nothing about it.
    function test_Rehearsal_AcceptanceCannotSkipTheDelay() public {
        _deployWithoutAcceptance();
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _ownershipBatch();

        vm.startPrank(multisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, DELAY);
        skip(DELAY - 1);
        vm.expectRevert();
        timelock.executeBatch(t, v, p, bytes32(0), SALT);

        skip(1);
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        vm.stopPrank();

        assertEq(registry.owner(), address(timelock));
    }

    // ---------------------------------------------------------------- steps

    function _deployWithoutAcceptance() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        vm.startPrank(deployer);
        timelock = new TimelockController(DELAY, proposers, executors, address(0));
        registry = new StockRegistry(deployer);

        address[] memory addrs = new address[](tokens.length);
        address[] memory fs = new address[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            addrs[i] = address(tokens[i]);
            fs[i] = address(feeds[i]);
        }
        registry.listMany(addrs, fs);

        factory = new BasketFactory(deployer, registry, treasury);
        zap = new BasketZap(deployer, factory, treasury, 20, IWETH(address(new RehearsalWETH())));
        migrator = new BasketMigrator(deployer, factory);
        lens = new BasketLens(registry);

        registry.transferOwnership(address(timelock));
        factory.transferOwnership(address(timelock));
        zap.transferOwnership(address(timelock));
        migrator.transferOwnership(address(timelock));
        vm.stopPrank();
    }

    function _deploy() internal {
        _deployWithoutAcceptance();
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _ownershipBatch();

        vm.startPrank(multisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, DELAY);
        skip(DELAY);
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        vm.stopPrank();
    }

    function _createBasketViaTimelock() internal returns (BasketToken) {
        bytes memory call = abi.encodeCall(BasketFactory.createBasket, ("Rehearsal Tech", "RTECH", _recipe(), 10, 10));

        vm.startPrank(multisig);
        timelock.schedule(address(factory), 0, call, bytes32(0), SALT, DELAY);
        skip(DELAY);
        timelock.execute(address(factory), 0, call, bytes32(0), SALT);
        vm.stopPrank();

        address[] memory all = factory.baskets();
        return BasketToken(all[all.length - 1]);
    }

    function _mintAndRedeem(BasketToken basket) internal {
        (uint256[] memory need,) = basket.previewMint(10e18);
        IBasketToken.Constituent[] memory recipe = basket.constituents();

        vm.startPrank(alice);
        for (uint256 i; i < recipe.length; ++i) {
            RehearsalToken(recipe[i].token).mint(alice, need[i]);
            RehearsalToken(recipe[i].token).approve(address(basket), need[i]);
        }
        uint256 netShares = basket.mint(10e18, alice);
        uint256[] memory out = basket.redeem(netShares, alice);
        vm.stopPrank();

        assertEq(netShares, 9.99e18, "mint fee is 10 bps");
        for (uint256 i; i < out.length; ++i) {
            assertGt(out[i], 0, "every leg must pay out");
        }
        assertGt(basket.balanceOf(treasury), 0, "fees accrue to the treasury");
    }

    // ---------------------------------------------------------------- helpers

    /// 30% NVDA, 25% AAPL, 25% GOOGL, 20% MSFT of a 100 USD share, priced from the rehearsal feeds.
    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        uint16[4] memory weights = [3000, 2500, 2500, 2000];
        uint8[4] memory idx = [0, 1, 3, 2];

        recipe = new IBasketToken.Constituent[](4);
        for (uint256 i; i < 4; ++i) {
            uint256 k = idx[i];
            // units = weight * nav / price, with the feed's 8 decimals cancelled out. All multiplication
            // happens before the division, matching CreateBasket.s.sol.
            uint256 units = uint256(weights[i]) * 100e18 * 1e8 / (10_000 * uint256(prices[k]));
            recipe[i] = IBasketToken.Constituent(address(tokens[k]), units);
        }
    }

    function _ownershipBatch()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](4);
        targets[0] = address(registry);
        targets[1] = address(factory);
        targets[2] = address(zap);
        targets[3] = address(migrator);

        values = new uint256[](4);
        payloads = new bytes[](4);
        for (uint256 i; i < 4; ++i) {
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
    }
}
