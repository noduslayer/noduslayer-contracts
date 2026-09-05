// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBasketFactory} from "./IBasketFactory.sol";
import {IRouteExecutor} from "./IRouteExecutor.sol";
import {IWETH} from "./IWETH.sol";

interface IBasketZap is IRouteExecutor {
    event ZapMinted(
        address indexed basket,
        address indexed sender,
        address indexed to,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        uint256 netShares,
        uint256 fee
    );
    event ZapRedeemed(
        address indexed basket,
        address indexed sender,
        address indexed to,
        address tokenOut,
        uint256 shares,
        uint256 amountOut,
        uint256 fee
    );
    event FeeUpdated(uint16 feeBps);
    event TreasuryUpdated(address indexed treasury);
    event SweptEther(address indexed to, uint256 amount);

    error UnknownBasket(address basket);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error InsufficientInput(uint256 amountIn, uint256 needed);
    error UnexpectedETH();
    error FeeTooHigh();

    function factory() external view returns (IBasketFactory);

    function weth() external view returns (IWETH);

    function feeBps() external view returns (uint16);

    function treasury() external view returns (address);

    function zapMint(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external returns (uint256 netShares);

    function zapMintWithPermit(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        uint256 deadline,
        Permit calldata permit
    ) external returns (uint256 netShares);

    function zapMintETH(address basket, uint256 shares, Swap[] calldata swaps, address to, uint256 deadline)
        external
        payable
        returns (uint256 netShares);

    function zapRedeem(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function zapRedeemWithSkip(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        uint256 skipMask,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function zapRedeemWithPermit(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 deadline,
        Permit calldata permit
    ) external returns (uint256 amountOut);

    // --- governance surface ---

    function setFee(uint16 feeBps_) external;

    function setTreasury(address treasury_) external;

    function sweepEther(address to) external;

    function pause() external;

    function unpause() external;
}
