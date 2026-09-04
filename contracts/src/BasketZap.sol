// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBasketFactory} from "./interfaces/IBasketFactory.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";
import {IBasketZap} from "./interfaces/IBasketZap.sol";
import {RouteExecutor} from "./RouteExecutor.sol";

/// @title BasketZap
/// @notice Single-transaction entry and exit for baskets: swaps an input token into the exact constituent
///         amounts through allow-listed routers and mints, or redeems and sells the constituents back.
/// @dev Routing is decided off-chain; this contract only enforces the router allow-list, exact-output
///      backing, the caller's minimum output and the deadline.
///      All accounting is done in deltas against a snapshot taken on entry, so a call can only ever spend,
///      require or refund value that it created. Anything already sitting in the contract — an intermediate
///      hop token a route touched, or a misdirected transfer — stays put and is recoverable only by `sweep`.
contract BasketZap is IBasketZap, RouteExecutor, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FEE_BPS = 50;
    uint256 private constant BPS = 10_000;

    IBasketFactory public immutable factory;

    address public treasury;
    uint16 public feeBps;

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

    // ------------------------------------------------------------------ internals

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
