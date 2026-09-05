// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {RouteExecutor} from "./RouteExecutor.sol";
import {IBasketFactory} from "./interfaces/IBasketFactory.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";
import {IBasketZap} from "./interfaces/IBasketZap.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title BasketZap
/// @notice Turns one token into basket shares and back in a single transaction: swaps chosen off-chain buy
///         the constituents, the vault mints against them, and whatever the swaps did not spend comes
///         back. The reverse sells the redeemed constituents into one token. Ether works too, wrapped on
///         the way in and unwrapped on the way out, and an EIP-2612 signature folds the approval into the
///         same transaction.
/// @dev Holds nothing between transactions and accounts only in deltas, so a balance already sitting here
///      can neither fund a caller's mint nor be paid out as a caller's proceeds. The fee is charged on what
///      the swaps actually spent, not on what the caller sent: the unspent slippage allowance comes back,
///      and taxing it would charge for money returned.
contract BasketZap is IBasketZap, RouteExecutor, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FEE_BPS = 50;
    uint256 private constant BPS = 10_000;

    IBasketFactory public immutable factory;
    IWETH public immutable weth;

    address public treasury;
    uint16 public feeBps;

    constructor(address initialOwner, IBasketFactory factory_, address treasury_, uint16 feeBps_, IWETH weth_)
        Ownable(initialOwner)
    {
        if (address(factory_) == address(0) || address(weth_) == address(0)) revert ZeroAddress();
        factory = factory_;
        weth = weth_;
        _setTreasury(treasury_);
        _setFee(feeBps_);
    }

    /// @dev Only wrapped ether may send ether here, and only while a mint is unwrapping a refund. Ether can
    ///      still be forced in without a call, so `sweepEther` exists beside `sweep`.
    receive() external payable {
        if (msg.sender != address(weth)) revert UnexpectedETH();
    }

    // ------------------------------------------------------------------ mint

    function zapMint(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 netShares) {
        _checkMint(basket, amountIn, shares, deadline);
        return _zapMint(basket, tokenIn, amountIn, shares, swaps, to, false);
    }

    function zapMintWithPermit(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        uint256 deadline,
        Permit calldata permit
    ) external nonReentrant whenNotPaused returns (uint256 netShares) {
        _checkMint(basket, amountIn, shares, deadline);
        _usePermit(tokenIn, permit);
        return _zapMint(basket, tokenIn, amountIn, shares, swaps, to, false);
    }

    function zapMintETH(address basket, uint256 shares, Swap[] calldata swaps, address to, uint256 deadline)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 netShares)
    {
        _checkMint(basket, msg.value, shares, deadline);
        return _zapMint(basket, address(weth), msg.value, shares, swaps, to, true);
    }

    // ------------------------------------------------------------------ redeem

    function zapRedeem(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _checkRedeem(basket, shares, to, deadline);
        return _zapRedeem(basket, shares, tokenOut, minAmountOut, swaps, to, 0);
    }

    /// @notice zapRedeem with a constituent the issuer has frozen left out of the route. The paid legs are
    ///         sold as usual; the skipped leg is credited to `to` on the basket, to claim once it thaws.
    function zapRedeemWithSkip(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        uint256 skipMask,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _checkRedeem(basket, shares, to, deadline);
        return _zapRedeem(basket, shares, tokenOut, minAmountOut, swaps, to, skipMask);
    }

    function zapRedeemWithPermit(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 deadline,
        Permit calldata permit
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _checkRedeem(basket, shares, to, deadline);
        _usePermit(basket, permit);
        return _zapRedeem(basket, shares, tokenOut, minAmountOut, swaps, to, 0);
    }

    // ------------------------------------------------------------------ admin

    function setFee(uint16 feeBps_) external onlyOwner {
        _setFee(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    /// @notice Recovers ether that reached the contract without a call. Nothing else can hold ether here:
    ///         a refund is unwrapped and forwarded within the same transaction.
    function sweepEther(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        Address.sendValue(payable(to), amount);
        emit SweptEther(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ internals

    /// @dev The input lands after the snapshot, so it counts as gained: a caller's own money is what the
    ///      swaps may spend, a balance already here is not. `native` marks ether wrapped for the call, whose
    ///      unspent remainder goes back as ether.
    function _zapMint(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        bool native
    ) private returns (uint256 netShares) {
        uint256 fee;
        {
            address[] memory tracked = _tracked(IBasketToken(basket).constituents(), tokenIn, swaps);
            uint256[] memory opening = _snapshot(tracked);

            if (native) weth.deposit{value: amountIn}();
            else IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

            _execute(swaps, tracked, opening);
            _stageConstituents(basket, shares, opening);
            netShares = IBasketToken(basket).mint(shares, to);
            fee = _settleInput(tokenIn, amountIn, native, tracked, opening);
        }
        emit ZapMinted(basket, msg.sender, to, tokenIn, amountIn, shares, netShares, fee);
    }

    /// @dev Takes the fee on what the swaps spent, then returns every tracked surplus to the caller — the
    ///      input's remainder as ether when it arrived as ether.
    function _settleInput(
        address tokenIn,
        uint256 amountIn,
        bool native,
        address[] memory tracked,
        uint256[] memory opening
    ) private returns (uint256 fee) {
        uint256 openingIn = opening[_indexOf(tracked, tokenIn)];
        fee = _takeInputFee(tokenIn, amountIn, openingIn);
        _refundDelta(tracked, opening, native ? tokenIn : address(0));
        if (native) _refundEther(openingIn);
    }

    function _zapRedeem(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 skipMask
    ) private returns (uint256 amountOut) {
        address[] memory tracked = _tracked(IBasketToken(basket).constituents(), tokenOut, swaps);
        uint256[] memory opening = _snapshot(tracked);

        IERC20(basket).safeTransferFrom(msg.sender, address(this), shares);
        // What came out is measured from balances, not from the return value.
        // slither-disable-start unused-return
        if (skipMask == 0) IBasketToken(basket).redeem(shares, address(this));
        else IBasketToken(basket).redeemWithSkipFor(shares, address(this), to, skipMask);
        // slither-disable-end unused-return

        _execute(swaps, tracked, opening);

        uint256 fee;
        (amountOut, fee) = _settle(tokenOut, opening[_indexOf(tracked, tokenOut)], minAmountOut, to);
        _refundDelta(tracked, opening);

        emit ZapRedeemed(basket, msg.sender, to, tokenOut, shares, amountOut, fee);
    }

    /// @dev Verifies this call's swaps produced enough of every constituent and makes it spendable by the
    ///      basket. `opening` holds the entry balances, so a constituent already sitting in the contract
    ///      cannot satisfy the requirement.
    ///      The allowance is left at max because it is only reachable while this contract is `msg.sender`.
    function _stageConstituents(address basket, uint256 shares, uint256[] memory opening) private {
        IBasketToken.Constituent[] memory recipe = IBasketToken(basket).constituents();
        // slither-disable-next-line unused-return
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

    /// @dev Charges the fee on what the swaps spent and takes it from what they left unspent, so the caller
    ///      has to send the spend plus the fee on it — the quote service sizes the input accordingly — and
    ///      is refunded the rest. Charging the input itself would tax the slippage allowance that comes back.
    function _takeInputFee(address tokenIn, uint256 amountIn, uint256 opening) private returns (uint256 fee) {
        uint256 left = _gained(tokenIn, opening);
        uint256 spent = left >= amountIn ? 0 : amountIn - left;
        fee = spent * feeBps / BPS;
        if (fee > left) revert InsufficientInput(amountIn, spent + fee);
        if (fee != 0) IERC20(tokenIn).safeTransfer(treasury, fee);
    }

    /// @dev Unwraps what the call left of the caller's ether and returns it as ether.
    function _refundEther(uint256 openingWeth) private {
        uint256 surplus = _gained(address(weth), openingWeth);
        if (surplus != 0) {
            weth.withdraw(surplus);
            Address.sendValue(payable(msg.sender), surplus);
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

    function _checkMint(address basket, uint256 amountIn, uint256 shares, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!factory.isBasket(basket)) revert UnknownBasket(basket);
        if (factory.isRetired(basket)) revert BasketRetired(basket);
        if (amountIn == 0 || shares == 0) revert ZeroAmount();
    }

    function _checkRedeem(address basket, uint256 shares, address to, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!factory.isBasket(basket)) revert UnknownBasket(basket);
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
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
