// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IBasketZap} from "../src/interfaces/IBasketZap.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// Exercises the governance path the deployment actually uses: a multisig proposes through a
/// TimelockController, which owns the registry, factory and zap.
contract GovernanceTest is Test {
    uint256 internal constant DELAY = 2 days;
    bytes32 internal constant SALT = bytes32(0);

    TimelockController internal timelock;
    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketToken internal basket;
    MockStockToken internal nvda;
    MockStockToken internal aapl;

    address internal multisig = makeAddr("multisig");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        MockAggregator feed = new MockAggregator(8, 100e8);

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        registry = new StockRegistry(address(this));
        factory = new BasketFactory(address(this), registry, treasury);
        zap = new BasketZap(address(this), factory, treasury, 20);

        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        basket = BasketToken(factory.createBasket("Tech", "TECH", _recipe(), 10, 10));

        registry.transferOwnership(address(timelock));
        factory.transferOwnership(address(timelock));
        zap.transferOwnership(address(timelock));
    }

    // ---------------------------------------------------------------- taking ownership

    function test_Timelock_AcceptsOwnershipOfEveryContract() public {
        _acceptOwnership();

        assertEq(registry.owner(), address(timelock));
        assertEq(factory.owner(), address(timelock));
        assertEq(zap.owner(), address(timelock));
    }

    function test_RevertWhen_ExecutingOwnershipBatchBeforeDelay() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _ownershipBatch();

        vm.startPrank(multisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, DELAY);
        vm.warp(block.timestamp + DELAY - 1);

        vm.expectRevert();
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        vm.stopPrank();

        assertEq(registry.owner(), address(this));
    }

    function test_RevertWhen_StrangerSchedules() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _ownershipBatch();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, timelock.PROPOSER_ROLE()
            )
        );
        vm.prank(stranger);
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, DELAY);
    }

    // ---------------------------------------------------------------- governing the protocol

    function test_Timelock_ChangesBasketFeesAfterDelay() public {
        _acceptOwnership();
        bytes memory call = abi.encodeCall(IBasketToken.setFees, (25, 25, treasury));

        vm.startPrank(multisig);
        timelock.schedule(address(basket), 0, call, bytes32(0), SALT, DELAY);
        vm.warp(block.timestamp + DELAY);
        timelock.execute(address(basket), 0, call, bytes32(0), SALT);
        vm.stopPrank();

        assertEq(basket.mintFeeBps(), 25);
        assertEq(basket.redeemFeeBps(), 25);
    }

    function test_Timelock_AllowlistsARouterAfterDelay() public {
        _acceptOwnership();
        address router = makeAddr("router");
        bytes memory call = abi.encodeCall(IBasketZap.setRouter, (router, true));

        vm.startPrank(multisig);
        timelock.schedule(address(zap), 0, call, bytes32(0), SALT, DELAY);
        vm.warp(block.timestamp + DELAY);
        timelock.execute(address(zap), 0, call, bytes32(0), SALT);
        vm.stopPrank();

        assertTrue(zap.isRouter(router));
    }

    function test_Timelock_CancelsAScheduledChange() public {
        _acceptOwnership();
        bytes memory call = abi.encodeCall(IBasketToken.setFees, (100, 100, treasury));

        vm.startPrank(multisig);
        timelock.schedule(address(basket), 0, call, bytes32(0), SALT, DELAY);
        timelock.cancel(timelock.hashOperation(address(basket), 0, call, bytes32(0), SALT));
        vm.warp(block.timestamp + DELAY);

        vm.expectRevert();
        timelock.execute(address(basket), 0, call, bytes32(0), SALT);
        vm.stopPrank();

        assertEq(basket.mintFeeBps(), 10);
    }

    function test_RevertWhen_MultisigCallsProtocolDirectly() public {
        _acceptOwnership();

        vm.expectRevert(IBasketToken.Unauthorized.selector);
        vm.prank(multisig);
        basket.setFees(25, 25, treasury);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, multisig));
        vm.prank(multisig);
        zap.setRouter(makeAddr("router"), true);
    }

    /// Redemption must survive a captured or lost timelock, so it may never sit behind governance.
    function test_RedeemStaysOpenRegardlessOfGovernance() public {
        _acceptOwnership();

        nvda.mint(address(this), 10e18);
        aapl.mint(address(this), 10e18);
        nvda.approve(address(basket), type(uint256).max);
        aapl.approve(address(basket), type(uint256).max);
        basket.mint(10e18, address(this));

        uint256[] memory out = basket.redeem(5e18, address(this));
        assertGt(out[0], 0);
        assertGt(out[1], 0);
    }

    // ---------------------------------------------------------------- helpers

    function _acceptOwnership() internal {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _ownershipBatch();

        vm.startPrank(multisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), SALT, DELAY);
        vm.warp(block.timestamp + DELAY);
        timelock.executeBatch(t, v, p, bytes32(0), SALT);
        vm.stopPrank();
    }

    function _ownershipBatch()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](3);
        targets[0] = address(registry);
        targets[1] = address(factory);
        targets[2] = address(zap);

        values = new uint256[](3);
        payloads = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
    }

    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(address(nvda), 0.2e18);
        recipe[1] = IBasketToken.Constituent(address(aapl), 0.15e18);
    }
}
