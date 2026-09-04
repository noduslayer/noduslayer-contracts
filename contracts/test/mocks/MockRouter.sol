// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Fixed-price venue: `price[token]` is quote base units per 1e18 of `token`.
contract MockRouter {
    using SafeERC20 for IERC20;

    mapping(address token => uint256) public price;

    function setPrice(address token, uint256 quotePer1e18) external {
        price[token] = quotePer1e18;
    }

    function swapExactOutput(address quote, address token, uint256 amountOut) external {
        uint256 amountIn = Math.mulDiv(amountOut, price[token], 1e18, Math.Rounding.Ceil);
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).safeTransfer(msg.sender, amountOut);
    }

    /// Settles from the router's own balance; the caller transfers the quote in beforehand.
    function swapExactOutputPrefunded(address token, uint256 amountOut) external {
        IERC20(token).safeTransfer(msg.sender, amountOut);
    }

    function swapExactInput(address token, address quote, uint256 amountIn) external {
        uint256 amountOut = Math.mulDiv(amountIn, price[token], 1e18);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(quote).safeTransfer(msg.sender, amountOut);
    }
}
