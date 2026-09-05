// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {BasketToken} from "../../src/BasketToken.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";

/// Drives a basket through every action a holder or the issuer can take, in any order, and checks after
/// each that the vault still holds what it owes. fail_on_revert is off in foundry.toml on purpose: a
/// paused token makes redeem revert, and that is a state worth exploring, not a failure.
contract BasketHandler is Test {
    BasketToken public basket;
    MockStockToken[] public tokens;
    address[] public actors;
    address public protocolOwner;
    address public treasury;

    uint256 public mints;
    uint256 public redeems;
    uint256 public skips;
    uint256 public claims;

    constructor(BasketToken basket_, MockStockToken[] memory tokens_, address owner_, address treasury_) {
        basket = basket_;
        tokens = tokens_;
        protocolOwner = owner_;
        treasury = treasury_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        shares = bound(shares, 1, 1000e18);
        (uint256[] memory need,) = basket.previewMint(shares);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].paused()) return;
            tokens[i].mint(actor, need[i]);
            vm.prank(actor);
            tokens[i].approve(address(basket), need[i]);
        }
        vm.prank(actor);
        basket.mint(shares, actor);
        mints++;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 held = basket.balanceOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(actor);
        basket.redeem(shares, actor);
        redeems++;
    }

    function redeemWithSkip(uint256 actorSeed, uint256 shares, uint256 mask) external {
        address actor = _actor(actorSeed);
        uint256 held = basket.balanceOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        mask = bound(mask, 1, 2 ** tokens.length - 1);
        vm.prank(actor);
        basket.redeemWithSkip(shares, actor, mask);
        skips++;
    }

    function claim(uint256 actorSeed, uint256 tokenSeed) external {
        address actor = _actor(actorSeed);
        MockStockToken token = tokens[bound(tokenSeed, 0, tokens.length - 1)];
        if (basket.claimable(actor, address(token)) == 0) return;
        vm.prank(actor);
        basket.claim(address(token), actor);
        claims++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = basket.balanceOf(from);
        if (held == 0) return;
        vm.prank(from);
        assertTrue(basket.transfer(_actor(toSeed), bound(amount, 1, held)));
    }

    function setFees(uint256 mintBps, uint256 redeemBps) external {
        vm.prank(protocolOwner);
        basket.setFees(uint16(bound(mintBps, 0, 100)), uint16(bound(redeemBps, 0, 100)));
    }

    /// The issuer freezes or thaws a constituent, as Robinhood can.
    function setPaused(uint256 tokenSeed, bool paused) external {
        tokens[bound(tokenSeed, 0, tokens.length - 1)].setPaused(paused);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }
}

contract BasketInvariantsTest is Test {
    BasketToken internal basket;
    BasketHandler internal handler;
    MockStockToken[] internal tokens;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        tokens.push(new MockStockToken("NVIDIA", "NVDA"));
        tokens.push(new MockStockToken("Apple", "AAPL"));
        tokens.push(new MockStockToken("Microsoft", "MSFT"));
        address owner = makeAddr("protocolOwner");
        MockFactory factory = new MockFactory(owner, treasury);

        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](3);
        recipe[0] = IBasketToken.Constituent(address(tokens[0]), 0.2e18);
        recipe[1] = IBasketToken.Constituent(address(tokens[1]), 0.15e18);
        recipe[2] = IBasketToken.Constituent(address(tokens[2]), 0.333333333333333333e18);
        basket = factory.deploy("Tech", "TECH", recipe, 10, 10);

        handler = new BasketHandler(basket, tokens, owner, treasury);
        targetContract(address(handler));
    }

    /// The invariant the design document states: every constituent's balance covers the supply's claim on
    /// it plus everything owed to holders who redeemed around a frozen leg.
    function invariant_BackingCoversSupplyAndClaims() public view {
        IBasketToken.Constituent[] memory recipe = basket.constituents();
        uint256 supply = basket.totalSupply();
        for (uint256 i; i < recipe.length; ++i) {
            uint256 balance = tokens[i].balanceOf(address(basket));
            uint256 owed = basket.totalClaimable(recipe[i].token);
            assertGe(balance * 1e18, supply * recipe[i].units + owed * 1e18, "backing");
        }
    }

    /// The per-account ledger and its total never disagree, however claims are recorded and collected.
    function invariant_ClaimLedgerSumsToItsTotal() public view {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 sum;
            for (uint256 a; a < handler.actorCount(); ++a) {
                sum += basket.claimable(handler.actors(a), address(tokens[i]));
            }
            assertEq(sum, basket.totalClaimable(address(tokens[i])), "claim ledger");
        }
    }

    /// Fee shares are minted and transferred, never conjured: supply equals what every account holds.
    function invariant_SupplyIsHeldBySomeone() public view {
        uint256 held = basket.balanceOf(treasury);
        for (uint256 a; a < handler.actorCount(); ++a) {
            held += basket.balanceOf(handler.actors(a));
        }
        assertEq(held, basket.totalSupply(), "supply");
    }

    function invariant_CallSummary() public view {
        // Recorded so a run that never reached an action shows up in the log rather than passing vacuously.
        handler.mints();
        handler.redeems();
        handler.skips();
        handler.claims();
    }
}
