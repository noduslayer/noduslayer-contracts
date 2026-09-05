// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RouteExecutor} from "./RouteExecutor.sol";
import {IBasketFactory} from "./interfaces/IBasketFactory.sol";
import {IBasketMigrator} from "./interfaces/IBasketMigrator.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";

/// @title BasketMigrator
/// @notice Moves a holder from one basket version to the next in one transaction, trading only the
///         difference between the two recipes.
/// @dev A recipe is immutable, so rebalancing means issuing a new basket and moving holders across. Doing
///      that on the open market would sell every constituent of the old basket and rebuy every constituent
///      of the new one, paying fees and spread twice on everything the two versions share. Here the shared
///      legs never leave the contract: they come out of one vault and go straight into the other, and the
///      caller supplies swaps only for what actually changed.
///
///      It charges no fee of its own. The two baskets already take a redeem fee on the way out and a mint
///      fee on the way in; a third would tax holders for following a rebalance the protocol asked them to.
///      Moving out of a retired basket is the expected use; moving into one is refused.
contract BasketMigrator is IBasketMigrator, RouteExecutor, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBasketFactory public immutable factory;

    constructor(address initialOwner, IBasketFactory factory_) Ownable(initialOwner) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @param shares      Shares of `from` to redeem.
    /// @param mintShares  Gross shares of `to` to mint; the caller receives this less the mint fee.
    /// @param minShares   Floor on what the recipient actually receives.
    function migrate(
        address from,
        address to,
        uint256 shares,
        uint256 mintShares,
        uint256 minShares,
        Swap[] calldata swaps,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 netShares) {
        _check(from, to, shares, mintShares, recipient, deadline);
        return _migrate(from, to, shares, mintShares, minShares, swaps, recipient);
    }

    function migrateWithPermit(
        address from,
        address to,
        uint256 shares,
        uint256 mintShares,
        uint256 minShares,
        Swap[] calldata swaps,
        address recipient,
        uint256 deadline,
        Permit calldata permit
    ) external nonReentrant whenNotPaused returns (uint256 netShares) {
        _check(from, to, shares, mintShares, recipient, deadline);
        _usePermit(from, permit);
        return _migrate(from, to, shares, mintShares, minShares, swaps, recipient);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _migrate(
        address from,
        address to,
        uint256 shares,
        uint256 mintShares,
        uint256 minShares,
        Swap[] calldata swaps,
        address recipient
    ) private returns (uint256 netShares) {
        address[] memory tracked = _trackedForPair(from, to, swaps);
        uint256[] memory opening = _snapshot(tracked);

        IERC20(from).safeTransferFrom(msg.sender, address(this), shares);
        // slither-disable-next-line unused-return
        IBasketToken(from).redeem(shares, address(this));

        _execute(swaps, tracked, opening);

        _stage(to, mintShares, tracked, opening);
        netShares = IBasketToken(to).mint(mintShares, recipient);
        if (netShares < minShares) revert InsufficientShares(netShares, minShares);

        _refundDelta(tracked, opening);

        emit Migrated(from, to, msg.sender, recipient, shares, netShares);
    }

    function _check(address from, address to, uint256 shares, uint256 mintShares, address recipient, uint256 deadline)
        private
        view
    {
        if (block.timestamp > deadline) revert Expired();
        if (from == to) revert SameBasket(from);
        if (!factory.isBasket(from)) revert UnknownBasket(from);
        if (!factory.isBasket(to)) revert UnknownBasket(to);
        if (factory.isRetired(to)) revert BasketRetired(to);
        if (shares == 0 || mintShares == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
    }

    /// @dev Both recipes plus every swap's sell token, deduplicated, so a constituent shared by the two
    ///      versions is tracked once and a hop token cannot be stranded.
    function _trackedForPair(address from, address to, Swap[] calldata swaps)
        private
        view
        returns (address[] memory tokens)
    {
        IBasketToken.Constituent[] memory a = IBasketToken(from).constituents();
        IBasketToken.Constituent[] memory b = IBasketToken(to).constituents();

        address[] memory scratch = new address[](a.length + b.length + swaps.length);
        // slither-disable-next-line uninitialized-local
        uint256 n;
        for (uint256 i; i < a.length; ++i) {
            n = _push(scratch, n, a[i].token);
        }
        for (uint256 i; i < b.length; ++i) {
            n = _push(scratch, n, b[i].token);
        }
        for (uint256 i; i < swaps.length; ++i) {
            n = _push(scratch, n, swaps[i].sellToken);
        }

        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = scratch[i];
        }
    }

    /// @dev Verifies this call produced enough of every target constituent and approves the vault to take
    ///      it. Measured against `opening`, so a balance already sitting here cannot satisfy the mint.
    function _stage(address to, uint256 mintShares, address[] memory tracked, uint256[] memory opening) private {
        IBasketToken.Constituent[] memory recipe = IBasketToken(to).constituents();
        // slither-disable-next-line unused-return
        (uint256[] memory amountsIn,) = IBasketToken(to).previewMint(mintShares);

        for (uint256 i; i < recipe.length; ++i) {
            IERC20 token = IERC20(recipe[i].token);
            uint256 have = _gained(address(token), opening[_indexOf(tracked, address(token))]);
            if (have < amountsIn[i]) revert InsufficientConstituent(address(token), have, amountsIn[i]);
            if (token.allowance(address(this), to) < amountsIn[i]) {
                token.forceApprove(to, type(uint256).max);
            }
        }
    }
}
