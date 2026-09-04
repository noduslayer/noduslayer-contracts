// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IStockRegistry} from "./interfaces/IStockRegistry.sol";

/// @title StockRegistry
/// @notice Canonical set of stock tokens eligible as basket constituents, each optionally paired with a
///         Chainlink feed.
/// @dev Baskets pin their constituents at creation; delisting only prevents new baskets from using a token,
///      and feeds are kept after delisting so existing baskets stay priceable.
///      A feed is optional: minting, redeeming and zapping never read a price, so a token with no feed is a
///      valid constituent. Only `BasketLens` needs one, and it fails loudly for a constituent that lacks it.
///      Listing such a token is therefore a deliberate trade of on-chain NAV for coverage.
contract StockRegistry is IStockRegistry, Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _listed;

    mapping(address token => address feed) public feedOf;
    /// @notice True once a token has ever been listed, so a feed can still be attached after a delisting.
    mapping(address token => bool) public known;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function list(address token, address feed) external onlyOwner {
        _list(token, feed);
    }

    /// @notice Lists a whole universe in one transaction. Pass `address(0)` as a feed to list without one.
    function listMany(address[] calldata tokens_, address[] calldata feeds) external onlyOwner {
        if (tokens_.length != feeds.length) revert LengthMismatch();
        for (uint256 i; i < tokens_.length; ++i) {
            _list(tokens_[i], feeds[i]);
        }
    }

    function delist(address token) external onlyOwner {
        if (!_listed.remove(token)) revert NotListed(token);
        emit Delisted(token);
    }

    /// @dev Allowed for delisted tokens too: live baskets keep pricing through feed migrations.
    ///      Passing `address(0)` detaches a feed that has gone bad.
    function setFeed(address token, address feed) external onlyOwner {
        if (!known[token]) revert NotListed(token);
        _setFeed(token, feed);
        emit FeedUpdated(token, feed);
    }

    function isListed(address token) external view returns (bool) {
        return _listed.contains(token);
    }

    function tokens() external view returns (address[] memory) {
        return _listed.values();
    }

    function hasFeed(address token) external view returns (bool) {
        return feedOf[token] != address(0);
    }

    function _list(address token, address feed) private {
        _requireToken(token);
        if (!_listed.add(token)) revert AlreadyListed(token);
        known[token] = true;
        _setFeed(token, feed);
        emit Listed(token, feed);
    }

    function _setFeed(address token, address feed) private {
        if (feed != address(0)) {
            if (feed.code.length == 0) revert InvalidFeed(feed);
            try AggregatorV3Interface(feed).decimals() returns (uint8) {}
            catch {
                revert InvalidFeed(feed);
            }
        }
        feedOf[token] = feed;
    }

    function _requireToken(address token) private view {
        if (token.code.length == 0) revert InvalidToken(token);
        try IERC20Metadata(token).decimals() returns (uint8) {}
        catch {
            revert InvalidToken(token);
        }
    }
}
