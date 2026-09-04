// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketMigrator} from "../src/BasketMigrator.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketMigrator} from "../src/interfaces/IBasketMigrator.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {IRouteExecutor} from "../src/interfaces/IRouteExecutor.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// A recipe is immutable, so rebalancing means issuing a new basket and moving holders across. Doing that
/// through the open market would sell and rebuy every constituent the two baskets share; the migrator trades
/// only the difference.
contract BasketMigratorTest is Test {
    uint256 internal constant NVDA_PRICE = 230e6;
    uint256 internal constant AAPL_PRICE = 328e6;
    uint256 internal constant MSFT_PRICE = 509e6;

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketMigrator internal migrator;
    BasketToken internal v1;
    BasketToken internal v2;

    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockStockToken internal msft;
    MockERC20 internal usdg;
    MockRouter internal router;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        msft = new MockStockToken("Microsoft", "MSFT");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockAggregator feed = new MockAggregator(8, 100e8);

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        migrator = new BasketMigrator(protocolOwner, factory);

        router = new MockRouter();
        router.setPrice(address(nvda), NVDA_PRICE);
        router.setPrice(address(aapl), AAPL_PRICE);
        router.setPrice(address(msft), MSFT_PRICE);
        nvda.mint(address(router), 1000e18);
        aapl.mint(address(router), 1000e18);
        msft.mint(address(router), 1000e18);
        usdg.mint(address(router), 1_000_000e6);

        vm.startPrank(protocolOwner);
        registry.list(address(nvda), address(feed));
        registry.list(address(aapl), address(feed));
        registry.list(address(msft), address(feed));
        // v1 and v2 share NVDA; only the AAPL leg is replaced by MSFT.
        v1 = BasketToken(factory.createBasket("Tech v1", "TECH1", _recipe(address(aapl), 0.15e18), 10, 10));
        v2 = BasketToken(factory.createBasket("Tech v2", "TECH2", _recipe(address(msft), 0.1e18), 10, 10));
        migrator.setRouter(address(router), true);
        vm.stopPrank();

        _giveShares(alice, 10e18);
    }

    // ---------------------------------------------------------------- migrating

    function test_Migrate_MovesAHolderAcrossVersions() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);

        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        uint256 netShares =
            migrator.migrate(address(v1), address(v2), shares, 4.8e18, 4.7e18, _swaps(out[1]), bob, block.timestamp);
        vm.stopPrank();

        assertEq(v2.balanceOf(bob), netShares);
        assertEq(netShares, 4.7952e18, "4.8e18 gross less the 10 bps mint fee");
        assertEq(v1.balanceOf(alice), 4.99e18, "alice held 9.99e18 after the mint fee; only 5e18 migrated");
        _assertMigratorEmpty();
    }

    /// The whole point: a constituent both versions hold is never sold and rebought.
    function test_Migrate_DoesNotTradeTheSharedConstituent() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);

        uint256 routerNvdaBefore = nvda.balanceOf(address(router));

        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        migrator.migrate(address(v1), address(v2), shares, 4.8e18, 0, _swaps(out[1]), bob, block.timestamp);
        vm.stopPrank();

        // The router only ever saw AAPL and MSFT. NVDA went straight from one vault to the other.
        assertEq(nvda.balanceOf(address(router)), routerNvdaBefore, "NVDA must not touch the router");
    }

    function test_Migrate_EmitsMigrated() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);

        vm.recordLogs();
        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        uint256 netShares =
            migrator.migrate(address(v1), address(v2), shares, 4.8e18, 0, _swaps(out[1]), bob, block.timestamp);
        vm.stopPrank();

        // A migration emits a long tail of transfers and approvals, so look for the one that matters
        // rather than assuming it is next.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(migrator) || logs[i].topics[0] != IBasketMigrator.Migrated.selector) {
                continue;
            }
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(v1));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(v2));
            assertEq(address(uint160(uint256(logs[i].topics[3]))), alice);
            (address recipient, uint256 sharesIn, uint256 sharesOut) =
                abi.decode(logs[i].data, (address, uint256, uint256));
            assertEq(recipient, bob);
            assertEq(sharesIn, shares);
            assertEq(sharesOut, netShares);
        }
        assertTrue(found, "Migrated was never emitted");
    }

    function test_Migrate_RefundsSurplusToTheCaller() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);

        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        // Buy more MSFT than the recipe needs; the excess belongs to Alice, not the contract.
        migrator.migrate(address(v1), address(v2), shares, 4e18, 0, _swaps(out[1]), bob, block.timestamp);
        vm.stopPrank();

        assertGt(msft.balanceOf(alice), 0, "surplus MSFT is refunded");
        _assertMigratorEmpty();
    }

    // ---------------------------------------------------------------- guards

    function test_RevertWhen_MigratingBelowTheCallersFloor() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);

        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        vm.expectRevert(abi.encodeWithSelector(IBasketMigrator.InsufficientShares.selector, 4.7952e18, 5e18));
        migrator.migrate(address(v1), address(v2), shares, 4.8e18, 5e18, _swaps(out[1]), bob, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_SourceIsNotAnOfficialBasket() public {
        address fake = makeAddr("fake");
        vm.expectRevert(abi.encodeWithSelector(IBasketMigrator.UnknownBasket.selector, fake));
        vm.prank(alice);
        migrator.migrate(fake, address(v2), 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);
    }

    function test_RevertWhen_TargetIsNotAnOfficialBasket() public {
        address fake = makeAddr("fake");
        vm.expectRevert(abi.encodeWithSelector(IBasketMigrator.UnknownBasket.selector, fake));
        vm.prank(alice);
        migrator.migrate(address(v1), fake, 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);
    }

    /// Migrating a basket into itself would burn the redeem and mint fees for no change in position.
    function test_RevertWhen_MigratingIntoTheSameBasket() public {
        vm.expectRevert(abi.encodeWithSelector(IBasketMigrator.SameBasket.selector, address(v1)));
        vm.prank(alice);
        migrator.migrate(address(v1), address(v1), 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);
    }

    function test_RevertWhen_Expired() public {
        vm.expectRevert(IRouteExecutor.Expired.selector);
        vm.prank(alice);
        migrator.migrate(
            address(v1), address(v2), 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp - 1
        );
    }

    function test_RevertWhen_AmountsAreZero() public {
        vm.startPrank(alice);
        vm.expectRevert(IRouteExecutor.ZeroAmount.selector);
        migrator.migrate(address(v1), address(v2), 0, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);

        vm.expectRevert(IRouteExecutor.ZeroAmount.selector);
        migrator.migrate(address(v1), address(v2), 1e18, 0, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_RecipientIsZero() public {
        vm.expectRevert(IRouteExecutor.ZeroAddress.selector);
        vm.prank(alice);
        migrator.migrate(
            address(v1), address(v2), 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), address(0), block.timestamp
        );
    }

    function test_RevertWhen_RouterIsNotAllowed() public {
        MockRouter rogue = new MockRouter();
        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](1);
        swaps[0] = IRouteExecutor.Swap({
            router: address(rogue),
            sellToken: address(aapl),
            prefund: 0,
            data: abi.encodeCall(MockRouter.swapExactInput, (address(aapl), address(usdg), 1))
        });

        vm.startPrank(alice);
        v1.approve(address(migrator), 5e18);
        vm.expectRevert(abi.encodeWithSelector(IRouteExecutor.RouterNotAllowed.selector, address(rogue)));
        migrator.migrate(address(v1), address(v2), 5e18, 1e18, 0, swaps, bob, block.timestamp);
        vm.stopPrank();
    }

    /// Delta accounting again: a balance sitting in the migrator is not the caller's to claim.
    function test_RevertWhen_MigrationWouldConsumeStrandedBalances() public {
        msft.mint(address(migrator), 100e18);

        vm.startPrank(alice);
        v1.approve(address(migrator), 5e18);
        vm.expectRevert();
        migrator.migrate(address(v1), address(v2), 5e18, 4.9e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);
        vm.stopPrank();

        assertEq(msft.balanceOf(address(migrator)), 100e18, "stranded balance stays for sweep()");
    }

    function test_RevertWhen_MigratingWhilePaused() public {
        vm.prank(protocolOwner);
        migrator.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        migrator.migrate(address(v1), address(v2), 1e18, 1e18, 0, new IRouteExecutor.Swap[](0), bob, block.timestamp);
    }

    // ---------------------------------------------------------------- admin

    function test_RevertWhen_PausedByStranger() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        migrator.pause();
    }

    function test_Sweep_RecoversStrandedValue() public {
        usdg.mint(address(migrator), 42e6);

        vm.prank(protocolOwner);
        migrator.sweep(address(usdg), bob);
        assertEq(usdg.balanceOf(bob), 42e6);
    }

    /// Each deployment keeps its own allow-list, so the zap's list must not silently govern the migrator.
    function test_RouterAllowlistIsIndependentOfOtherDeployments() public {
        BasketMigrator other = new BasketMigrator(protocolOwner, factory);
        assertTrue(migrator.isRouter(address(router)));
        assertFalse(other.isRouter(address(router)));
    }

    function test_Unpause_RestoresMigration() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);

        vm.startPrank(protocolOwner);
        migrator.pause();
        migrator.unpause();
        vm.stopPrank();

        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        migrator.migrate(address(v1), address(v2), shares, 4.8e18, 0, _swaps(out[1]), bob, block.timestamp);
        vm.stopPrank();

        assertGt(v2.balanceOf(bob), 0);
    }

    /// The tracked set is built from both recipes plus every leg's sell token, so a lookup can never miss.
    /// This pins that invariant: reaching UntrackedToken would mean the set and the lookups had diverged.
    function test_TrackedSetCoversEveryTokenALookupWillMake() public {
        uint256 shares = 5e18;
        (uint256[] memory out,) = v1.previewRedeem(shares);
        IRouteExecutor.Swap[] memory swaps = _swaps(out[1]);

        vm.startPrank(alice);
        v1.approve(address(migrator), shares);
        migrator.migrate(address(v1), address(v2), shares, 4.8e18, 0, swaps, bob, block.timestamp);
        vm.stopPrank();

        // Every sell token and both recipes were handled without an UntrackedToken revert.
        assertEq(usdg.balanceOf(address(migrator)), 0);
        assertEq(msft.balanceOf(address(migrator)), 0);
    }

    // ---------------------------------------------------------------- helpers

    function _giveShares(address who, uint256 shares) internal {
        (uint256[] memory need,) = v1.previewMint(shares);
        nvda.mint(who, need[0]);
        aapl.mint(who, need[1]);

        vm.startPrank(who);
        nvda.approve(address(v1), type(uint256).max);
        aapl.approve(address(v1), type(uint256).max);
        v1.mint(shares, who);
        vm.stopPrank();
    }

    /// Sell the AAPL that v1 paid out, then buy the MSFT v2 needs. NVDA is deliberately absent.
    function _swaps(uint256 aaplOut) internal view returns (IRouteExecutor.Swap[] memory swaps) {
        swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = IRouteExecutor.Swap({
            router: address(router),
            sellToken: address(aapl),
            prefund: 0,
            data: abi.encodeCall(MockRouter.swapExactInput, (address(aapl), address(usdg), aaplOut))
        });
        swaps[1] = IRouteExecutor.Swap({
            router: address(router),
            sellToken: address(usdg),
            prefund: 0,
            data: abi.encodeCall(MockRouter.swapExactOutput, (address(usdg), address(msft), 0.48e18))
        });
    }

    function _assertMigratorEmpty() internal view {
        assertEq(nvda.balanceOf(address(migrator)), 0);
        assertEq(aapl.balanceOf(address(migrator)), 0);
        assertEq(msft.balanceOf(address(migrator)), 0);
        assertEq(usdg.balanceOf(address(migrator)), 0);
    }

    function _recipe(address second, uint256 units) internal view returns (IBasketToken.Constituent[] memory r) {
        r = new IBasketToken.Constituent[](2);
        r[0] = IBasketToken.Constituent(address(nvda), 0.2e18);
        r[1] = IBasketToken.Constituent(second, units);
    }
}
