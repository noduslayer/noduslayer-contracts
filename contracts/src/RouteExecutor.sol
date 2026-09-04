// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IBasketToken} from "./interfaces/IBasketToken.sol";
import {IRouteExecutor} from "./interfaces/IRouteExecutor.sol";

/// @title RouteExecutor
/// @notice Runs off-chain-chosen swaps against an allow-listed router set, accounting only in deltas.
/// @dev Shared by every contract that spends a caller's funds through a router. The accounting is the
///      security-critical part — a call may only spend, require or refund what it created, so a balance
///      already sitting in the contract is untouchable — and duplicating it per contract is how a fix ends
///      up applied to one and not the other.
///
///      Each deployment keeps its own allow-list. Sharing one would mean a paused or replaced peer could
///      disable routing everywhere, so governance maintains them separately; the runbook says so.
abstract contract RouteExecutor is IRouteExecutor, Ownable2Step {
    using SafeERC20 for IERC20;
    using Address for address;

    mapping(address router => bool) public isRouter;

    function setRouter(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = allowed;
        emit RouterUpdated(router, allowed);
    }

    /// @notice Recovers value a route left behind. With delta accounting nothing else can reach it.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    /// @dev Approves a (sellToken, router) pair once and keeps it live only while consecutive legs share it,
    ///      so a four-leg route pays one approval instead of eight. The allowance never outlives the call,
    ///      and covers only what this call produced of that token, so a route cannot spend a balance that
    ///      was already sitting here.
    function _execute(Swap[] calldata swaps, address[] memory tracked, uint256[] memory opening) internal {
        address openToken;
        address openRouter;

        for (uint256 i; i < swaps.length; ++i) {
            Swap calldata leg = swaps[i];
            if (!isRouter[leg.router]) revert RouterNotAllowed(leg.router);

            if (leg.sellToken != openToken || leg.router != openRouter) {
                _closeApproval(openToken, openRouter);
                openToken = leg.sellToken;
                openRouter = leg.router;
            }
            // Re-approved per leg: an earlier leg in the same group has already spent part of the delta.
            uint256 spendable = _gained(openToken, opening[_indexOf(tracked, openToken)]);
            IERC20(openToken).forceApprove(openRouter, spendable);

            if (leg.prefund != 0) {
                if (leg.prefund > spendable) revert InsufficientConstituent(openToken, spendable, leg.prefund);
                IERC20(openToken).safeTransfer(openRouter, leg.prefund);
            }
            leg.router.functionCall(leg.data);
        }

        _closeApproval(openToken, openRouter);
    }

    /// @dev The recipe tokens followed by `extra`, which is omitted when the recipe already contains it.
    ///      Keeping one entry per token means a refund pass cannot pay the same balance out twice.
    function _tracked(IBasketToken.Constituent[] memory recipe, address extra, Swap[] calldata swaps)
        internal
        pure
        returns (address[] memory tokens)
    {
        address[] memory scratch = new address[](recipe.length + 1 + swaps.length);
        uint256 n;
        for (uint256 i; i < recipe.length; ++i) {
            n = _push(scratch, n, recipe[i].token);
        }
        n = _push(scratch, n, extra);
        // Sell tokens are tracked too, so a route's intermediate hop is refunded rather than stranded.
        for (uint256 i; i < swaps.length; ++i) {
            n = _push(scratch, n, swaps[i].sellToken);
        }

        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = scratch[i];
        }
    }

    function _push(address[] memory set, uint256 n, address token) internal pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (set[i] == token) return n;
        }
        set[n] = token;
        return n + 1;
    }

    /// @dev Unreachable by construction: callers build `tokens` from every recipe and every leg's sell
    ///      token before any lookup happens. The revert exists so a future caller that forgets one fails
    ///      loudly instead of measuring a delta against a balance nobody snapshotted.
    function _indexOf(address[] memory tokens, address token) internal pure returns (uint256) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return i;
        }
        revert UntrackedToken(token);
    }

    function _snapshot(address[] memory tokens) internal view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    /// @dev What this call added to the contract's holding of `token`. Clamped at zero because a token that
    ///      is both the input and a constituent falls below its opening balance when the fee is paid out.
    function _gained(address token, uint256 opening) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        return balance > opening ? balance - opening : 0;
    }

    function _refundDelta(address[] memory tokens, uint256[] memory opening) internal {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 surplus = _gained(tokens[i], opening[i]);
            if (surplus != 0) IERC20(tokens[i]).safeTransfer(msg.sender, surplus);
        }
    }

    function _closeApproval(address token, address router) internal {
        if (token != address(0)) IERC20(token).forceApprove(router, 0);
    }
}
