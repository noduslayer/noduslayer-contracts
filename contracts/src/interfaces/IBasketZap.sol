// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBasketZap {
    /// @param router    Allow-listed router that executes the leg.
    /// @param sellToken Token the leg spends; approved to `router` for the duration of the call.
    /// @param prefund   Amount of `sellToken` transferred to `router` before the call, for routers that settle
    ///                  from their own balance instead of pulling from the caller. Zero for pull-based routers.
    /// @param data      Router calldata produced off-chain.
    struct Swap {
        address router;
        address sellToken;
        uint256 prefund;
        bytes data;
    }

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
    event RouterUpdated(address indexed router, bool allowed);
    event FeeUpdated(uint16 feeBps);
    event TreasuryUpdated(address indexed treasury);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error Expired();
    error UnknownBasket(address basket);
    error RouterNotAllowed(address router);
    error InsufficientConstituent(address token, uint256 have, uint256 need);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error FeeTooHigh();
    error ZeroAddress();
    error ZeroAmount();

    function feeBps() external view returns (uint16);

    function treasury() external view returns (address);

    function isRouter(address router) external view returns (bool);

    function zapMint(
        address basket,
        address tokenIn,
        uint256 amountIn,
        uint256 shares,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external returns (uint256 netShares);

    function zapRedeem(
        address basket,
        uint256 shares,
        address tokenOut,
        uint256 minAmountOut,
        Swap[] calldata swaps,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
