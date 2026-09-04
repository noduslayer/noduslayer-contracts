// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The routing surface shared by every contract that spends a caller's funds through a DEX router.
interface IRouteExecutor {
    /// @param router    Allow-listed router that executes the leg.
    /// @param sellToken Token the leg spends; approved to `router` for the duration of the call.
    /// @param prefund   Amount of `sellToken` transferred to `router` before the call, for routers that
    ///                  settle from their own balance instead of pulling from the caller. Zero for
    ///                  pull-based routers.
    /// @param data      Router calldata produced off-chain.
    struct Swap {
        address router;
        address sellToken;
        uint256 prefund;
        bytes data;
    }

    event RouterUpdated(address indexed router, bool allowed);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error Expired();
    error RouterNotAllowed(address router);
    error InsufficientConstituent(address token, uint256 have, uint256 need);
    error UntrackedToken(address token);
    error ZeroAddress();
    error ZeroAmount();

    function isRouter(address router) external view returns (bool);

    function setRouter(address router, bool allowed) external;

    function sweep(address token, address to) external;
}
