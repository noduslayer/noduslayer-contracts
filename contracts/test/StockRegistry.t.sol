// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {StockRegistry} from "../src/StockRegistry.sol";
import {IStockRegistry} from "../src/interfaces/IStockRegistry.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract StockRegistryTest is Test {
    StockRegistry internal registry;
    MockStockToken internal nvda;
    MockAggregator internal nvdaFeed;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        registry = new StockRegistry(owner);
        nvda = new MockStockToken("NVIDIA", "NVDA");
        nvdaFeed = new MockAggregator(8, 230e8);
    }

    function test_List_StoresFeedAndMarksListed() public {
        vm.prank(owner);
        registry.list(address(nvda), address(nvdaFeed));

        assertTrue(registry.isListed(address(nvda)));
        assertEq(registry.feedOf(address(nvda)), address(nvdaFeed));
    }

    function test_List_EmitsListed() public {
        vm.expectEmit(address(registry));
        emit IStockRegistry.Listed(address(nvda), address(nvdaFeed));

        vm.prank(owner);
        registry.list(address(nvda), address(nvdaFeed));
    }

    function test_RevertWhen_ListByNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.list(address(nvda), address(nvdaFeed));
    }

    function test_RevertWhen_ListDuplicate() public {
        vm.startPrank(owner);
        registry.list(address(nvda), address(nvdaFeed));

        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.AlreadyListed.selector, address(nvda)));
        registry.list(address(nvda), address(nvdaFeed));
        vm.stopPrank();
    }

    function test_RevertWhen_ListTokenWithoutCode() public {
        address eoa = makeAddr("eoa");

        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.InvalidToken.selector, eoa));
        vm.prank(owner);
        registry.list(eoa, address(nvdaFeed));
    }

    function test_RevertWhen_ListFeedWithoutCode() public {
        address eoa = makeAddr("eoa");

        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.InvalidFeed.selector, eoa));
        vm.prank(owner);
        registry.list(address(nvda), eoa);
    }

    function test_RevertWhen_ListTokenWithoutDecimals() public {
        address noDecimals = address(new MockAggregatorLessContract());

        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.InvalidToken.selector, noDecimals));
        vm.prank(owner);
        registry.list(noDecimals, address(nvdaFeed));
    }

    function test_RevertWhen_ListFeedWithoutDecimals() public {
        address noDecimals = address(new MockAggregatorLessContract());

        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.InvalidFeed.selector, noDecimals));
        vm.prank(owner);
        registry.list(address(nvda), noDecimals);
    }

    function test_Delist_RemovesListingButKeepsFeed() public {
        vm.startPrank(owner);
        registry.list(address(nvda), address(nvdaFeed));
        registry.delist(address(nvda));
        vm.stopPrank();

        assertFalse(registry.isListed(address(nvda)));
        assertEq(registry.feedOf(address(nvda)), address(nvdaFeed));
        assertEq(registry.tokens().length, 0);
    }

    function test_RevertWhen_DelistUnlisted() public {
        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.NotListed.selector, address(nvda)));
        vm.prank(owner);
        registry.delist(address(nvda));
    }

    function test_SetFeed_ReplacesFeed() public {
        MockAggregator replacement = new MockAggregator(8, 231e8);

        vm.startPrank(owner);
        registry.list(address(nvda), address(nvdaFeed));
        registry.setFeed(address(nvda), address(replacement));
        vm.stopPrank();

        assertEq(registry.feedOf(address(nvda)), address(replacement));
    }

    function test_RevertWhen_SetFeedForUnlisted() public {
        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.NotListed.selector, address(nvda)));
        vm.prank(owner);
        registry.setFeed(address(nvda), address(nvdaFeed));
    }

    function test_SetFeed_StillWorksAfterDelist() public {
        MockAggregator replacement = new MockAggregator(8, 231e8);

        vm.startPrank(owner);
        registry.list(address(nvda), address(nvdaFeed));
        registry.delist(address(nvda));
        registry.setFeed(address(nvda), address(replacement));
        vm.stopPrank();

        assertEq(registry.feedOf(address(nvda)), address(replacement));
        assertFalse(registry.isListed(address(nvda)));
    }

    // ---------------------------------------------------------------- feed-less listings

    function test_List_AcceptsTokenWithoutFeed() public {
        vm.prank(owner);
        registry.list(address(nvda), address(0));

        assertTrue(registry.isListed(address(nvda)));
        assertTrue(registry.known(address(nvda)));
        assertFalse(registry.hasFeed(address(nvda)));
        assertEq(registry.feedOf(address(nvda)), address(0));
    }

    function test_SetFeed_AttachesFeedToTokenListedWithoutOne() public {
        vm.startPrank(owner);
        registry.list(address(nvda), address(0));
        registry.setFeed(address(nvda), address(nvdaFeed));
        vm.stopPrank();

        assertTrue(registry.hasFeed(address(nvda)));
        assertEq(registry.feedOf(address(nvda)), address(nvdaFeed));
    }

    function test_SetFeed_CanDetachABrokenFeed() public {
        vm.startPrank(owner);
        registry.list(address(nvda), address(nvdaFeed));
        registry.setFeed(address(nvda), address(0));
        vm.stopPrank();

        assertFalse(registry.hasFeed(address(nvda)));
    }

    function test_RevertWhen_SetFeedOnNeverListedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStockRegistry.NotListed.selector, address(nvda)));
        vm.prank(owner);
        registry.setFeed(address(nvda), address(nvdaFeed));
    }

    function test_ListMany_ListsEveryTokenInOneCall() public {
        MockStockToken aapl = new MockStockToken("Apple", "AAPL");
        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(aapl);
        feeds[0] = address(nvdaFeed);
        feeds[1] = address(0);

        vm.prank(owner);
        registry.listMany(tokens, feeds);

        assertEq(registry.tokens().length, 2);
        assertTrue(registry.hasFeed(address(nvda)));
        assertFalse(registry.hasFeed(address(aapl)));
    }

    function test_RevertWhen_ListManyLengthMismatch() public {
        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](1);

        vm.expectRevert(IStockRegistry.LengthMismatch.selector);
        vm.prank(owner);
        registry.listMany(tokens, feeds);
    }

    function test_RevertWhen_ListManyByNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.listMany(new address[](0), new address[](0));
    }

    function test_Tokens_ReturnsListedSet() public {
        MockStockToken aapl = new MockStockToken("Apple", "AAPL");

        vm.startPrank(owner);
        registry.list(address(nvda), address(nvdaFeed));
        registry.list(address(aapl), address(nvdaFeed));
        vm.stopPrank();

        address[] memory listed = registry.tokens();
        assertEq(listed.length, 2);
        assertEq(listed[0], address(nvda));
        assertEq(listed[1], address(aapl));
    }
}

/// Has code but exposes no `decimals()`.
contract MockAggregatorLessContract {
    function ping() external pure returns (bool) {
        return true;
    }
}
