// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IStockRegistry {
    event Listed(address indexed token, address indexed feed);
    event Delisted(address indexed token);
    event FeedUpdated(address indexed token, address indexed feed);

    error AlreadyListed(address token);
    error NotListed(address token);
    error InvalidToken(address token);
    error InvalidFeed(address feed);
    error LengthMismatch();

    function isListed(address token) external view returns (bool);

    function known(address token) external view returns (bool);

    function hasFeed(address token) external view returns (bool);

    function feedOf(address token) external view returns (address);

    function tokens() external view returns (address[] memory);
}
