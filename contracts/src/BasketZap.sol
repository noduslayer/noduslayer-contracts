// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBasketFactory} from "./interfaces/IBasketFactory.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";
import {IBasketZap} from "./interfaces/IBasketZap.sol";

/// @title BasketZap
/// @notice Single-transaction entry and exit for baskets: swaps an input token into the exact constituent
///         amounts through allow-listed routers and mints, or redeems and sells the constituents back.
/// @dev Routing is decided off-chain; this contract only enforces the router allow-list, exact-output
///      backing, the caller's minimum output and the deadline.
///      All accounting is done in deltas against a snapshot taken on entry, so a call can only ever spend,
///      require or refund value that it created. Anything already sitting in the contract — an intermediate
///      hop token a route touched, or a misdirected transfer — stays put and is recoverable only by `sweep`.
contract BasketZap is IBasketZap, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant MAX_FEE_BPS = 50;
    uint256 private constant BPS = 10_000;

    IBasketFactory public immutable factory;

    address public treasury;
    uint16 public feeBps;
    mapping(address router => bool) public isRouter;

    constructor(address initialOwner, IBasketFactory factory_, address treasury_, uint16 feeBps_)
        Ownable(initialOwner)
    {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
        _setTreasury(treasury_);
        _setFee(feeBps_);
    }

    // ------------------------------------------------------------------ user entry points

    function zapMint(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 netShares) {
        _checkDeadline(deadline);
        _checkBasket(basket);
        if (amountIn == 0 || shares == 0) revert ZeroAmount();

        address[] memory tracked = _tracked(IBasketToken(basket).constituents(), tokenIn, swaps);
        uint256[] memory opening = _snapshot(tracked);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 fee = amountIn * feeBps / BPS;
        if (fee != 0) IERC20(tokenIn).safeTransfer(treasury, fee);

        _execute(swaps, tracked, opening);

        _stageConstituents(basket, shares, opening);
        netShares = IBasketToken(basket).mint(shares, to);
        _refundDelta(tracked, opening);

        emit ZapMinted(basket, msg.sender, to, tokenIn, amountIn, shares, netShares, fee);
    }

    function zapRedeem(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _checkDeadline(deadline);
        _checkBasket(basket);
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        address[] memory tracked = _tracked(IBasketToken(basket).constituents(), tokenOut, swaps);
        uint256[] memory opening = _snapshot(tracked);

        IERC20(basket).safeTransferFrom(msg.sender, address(this), shares);
        IBasketToken(basket).redeem(shares, address(this));

        _execute(swaps, tracked, opening);

        uint256 fee;
        (amountOut, fee) = _settle(tokenOut, opening[_indexOf(tracked, tokenOut)], minAmountOut, to);
        _refundDelta(tracked, opening);

        emit ZapRedeemed(basket, msg.sender, to, tokenOut, shares, amountOut, fee);
    }

    // ------------------------------------------------------------------ admin

    function setRouter(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = allowed;
        emit RouterUpdated(router, allowed);
    }

    function setFee(uint16 feeBps_) external onlyOwner {
        _setFee(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recovers tokens stranded by a route that left value behind after the caller's refund.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Approves a (sellToken, router) pair once and keeps it live only while consecutive legs share it,
    ///      so a four-leg route pays one approval instead of eight. The allowance never outlives the call,
    ///      and covers only what this call produced of that token, so a route cannot spend a balance that
    ///      was already sitting here.
    function _execute(Swap[] calldata swaps, address[] memory tracked, uint256[] memory opening) private {
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

    /// @dev Verifies this call's swaps produced enough of every constituent and makes it spendable by the
    ///      basket. `opening` holds the entry balances, so a constituent already sitting in the contract
    ///      cannot satisfy the requirement.
    ///      The allowance is left at max because it is only reachable while this contract is `msg.sender`.
    function _stageConstituents(address basket, uint256 shares, uint256[] memory opening) private {
        IBasketToken.Constituent[] memory recipe = IBasketToken(basket).constituents();
        (uint256[] memory amountsIn,) = IBasketToken(basket).previewMint(shares);

        for (uint256 i; i < recipe.length; ++i) {
            IERC20 token = IERC20(recipe[i].token);
            uint256 have = _gained(address(token), opening[i]);
            if (have < amountsIn[i]) revert InsufficientConstituent(address(token), have, amountsIn[i]);
            if (token.allowance(address(this), basket) < amountsIn[i]) {
                token.forceApprove(basket, type(uint256).max);
            }
        }
    }

    /// @dev Pays out what this call produced of `tokenOut`, after the protocol fee.
    function _settle(address tokenOut, uint256 opening, uint256 minAmountOut, address to)
        private
        returns (uint256 amountOut, uint256 fee)
    {
        uint256 gross = _gained(tokenOut, opening);
        fee = gross * feeBps / BPS;
        amountOut = gross - fee;
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        if (fee != 0) IERC20(tokenOut).safeTransfer(treasury, fee);
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }

    /// @dev The recipe tokens followed by `extra`, which is omitted when the recipe already contains it.
    ///      Keeping one entry per token means a refund pass cannot pay the same balance out twice.
    function _tracked(IBasketToken.Constituent[] memory recipe, address extra, Swap[] calldata swaps)
        private
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

    function _push(address[] memory set, uint256 n, address token) private pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (set[i] == token) return n;
        }
        set[n] = token;
        return n + 1;
    }

    function _indexOf(address[] memory tokens, address token) private pure returns (uint256) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return i;
        }
        revert UntrackedToken(token);
    }

    function _snapshot(address[] memory tokens) private view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    /// @dev What this call added to the contract's holding of `token`. Clamped at zero because a token that
    ///      is both the input and a constituent falls below its opening balance when the fee is paid out.
    function _gained(address token, uint256 opening) private view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        return balance > opening ? balance - opening : 0;
    }

    function _refundDelta(address[] memory tokens, uint256[] memory opening) private {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 surplus = _gained(tokens[i], opening[i]);
            if (surplus != 0) IERC20(tokens[i]).safeTransfer(msg.sender, surplus);
        }
    }

    function _closeApproval(address token, address router) private {
        if (token != address(0)) IERC20(token).forceApprove(router, 0);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
    }

    function _checkBasket(address basket) private view {
        if (!factory.isBasket(basket)) revert UnknownBasket(basket);
    }

    function _setFee(uint16 feeBps_) private {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
    }

    function _setTreasury(address treasury_) private {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }
}
