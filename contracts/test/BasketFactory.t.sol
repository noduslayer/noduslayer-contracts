// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketFactory} from "../src/interfaces/IBasketFactory.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IStockRegistry} from "../src/interfaces/IStockRegistry.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

contract BasketFactoryTest is Test {
    StockRegistry internal registry;
    BasketFactory internal factory;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockAggregator internal feed;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        feed = new MockAggregator(8, 100e8);
        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);

        vm.startPrank(protocolOwner);
        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        vm.stopPrank();
    }

    function test_Constructor_StoresRegistryAndTreasury() public view {
        assertEq(address(factory.registry()), address(registry));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.owner(), protocolOwner);
    }

    function test_CreateBasket_DeploysRegisteredBasket() public {
        vm.prank(protocolOwner);
        address created = factory.createBasket("NodusLayer Tech", "TECH", _recipe(), 10, 10);

        assertTrue(factory.isBasket(created));
        address[] memory all = factory.baskets();
        assertEq(all.length, 1);
        assertEq(all[0], created);

        BasketToken basket = BasketToken(created);
        assertEq(basket.name(), "NodusLayer Tech");
        assertEq(basket.symbol(), "TECH");
        assertEq(basket.factory(), address(factory));
        assertEq(basket.feeRecipient(), treasury);
        assertEq(basket.mintFeeBps(), 10);
        assertEq(basket.constituents().length, 2);
    }

    function test_CreateBasket_EmitsBasketCreated() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(address(factory));
        emit IBasketFactory.BasketCreated(predicted, "NodusLayer Tech", "TECH", _recipe(), 10, 10);

        vm.prank(protocolOwner);
        factory.createBasket("NodusLayer Tech", "TECH", _recipe(), 10, 10);
    }

    function test_RevertWhen_CreateBasketByStranger() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.createBasket("x", "X", _recipe(), 10, 10);
    }

    function test_RevertWhen_ConstituentNotListed() public {
        vm.prank(protocolOwner);
        registry.delist(address(aapl));

        vm.expectRevert(abi.encodeWithSelector(IBasketFactory.TokenNotListed.selector, address(aapl)));
        vm.prank(protocolOwner);
        factory.createBasket("x", "X", _recipe(), 10, 10);
    }

    /// Baskets read the treasury from the factory, so one change moves every basket's fee recipient.
    function test_SetTreasury_MovesEveryBasketsFeeRecipient() public {
        vm.startPrank(protocolOwner);
        address existing = factory.createBasket("x", "X", _recipe(), 10, 10);
        factory.setTreasury(stranger);
        address created = factory.createBasket("y", "Y", _recipe(), 10, 10);
        vm.stopPrank();

        assertEq(factory.treasury(), stranger);
        assertEq(BasketToken(existing).feeRecipient(), stranger);
        assertEq(BasketToken(created).feeRecipient(), stranger);
    }

    function test_Retire_MarksTheBasketAndItsSuccessor() public {
        vm.startPrank(protocolOwner);
        address old = factory.createBasket("x", "X", _recipe(), 10, 10);
        address next = factory.createBasket("y", "Y", _recipe(), 10, 10);

        vm.expectEmit(address(factory));
        emit IBasketFactory.BasketRetired(old, next);
        factory.retire(old, next);
        vm.stopPrank();

        assertTrue(factory.isRetired(old));
        assertFalse(factory.isRetired(next));
        assertEq(factory.successorOf(old), next);
        assertTrue(factory.isBasket(old), "a retired basket is still an official basket");
    }

    function test_RevertWhen_RetireByStranger() public {
        vm.prank(protocolOwner);
        address basket = factory.createBasket("x", "X", _recipe(), 10, 10);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.retire(basket, address(0));
    }

    function test_RevertWhen_SetTreasuryToZero() public {
        vm.expectRevert(IBasketFactory.ZeroAddress.selector);
        vm.prank(protocolOwner);
        factory.setTreasury(address(0));
    }

    function test_FactoryOwner_GovernsBasketFees() public {
        vm.prank(protocolOwner);
        BasketToken basket = BasketToken(factory.createBasket("x", "X", _recipe(), 10, 10));

        vm.prank(protocolOwner);
        basket.setFees(25, 25);
        assertEq(basket.mintFeeBps(), 25);

        vm.expectRevert(IBasketToken.Unauthorized.selector);
        vm.prank(stranger);
        basket.setFees(0, 0);
    }

    function test_RevertWhen_ConstructedWithoutRegistry() public {
        vm.expectRevert(IBasketFactory.ZeroAddress.selector);
        new BasketFactory(protocolOwner, IStockRegistry(address(0)), treasury);
    }

    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), 0.2e18);
        recipe[1] = IBasketToken.Constituent(address(aapl), 0.15e18);
    }
}
