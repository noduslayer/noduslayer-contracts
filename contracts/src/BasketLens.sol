// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";
import {IStockRegistry} from "./interfaces/IStockRegistry.sol";

/// @title BasketLens
/// @notice Read-only pricing: Chainlink constituent prices and basket NAV, both as USD scaled to 1e18.
/// @dev Robinhood stock feeds already embed the ERC-8056 corporate-action multiplier and only update
///      during market hours, so `nav(basket)` never reverts on age and returns the oldest feed timestamp
///      for the caller to judge; `nav(basket, maxAge)` enforces a freshness bound.
///      A constituent may be listed without a feed. `quotes` reports those with `priced == false` so a
///      caller can enumerate them, while both `nav` overloads revert rather than return a partial sum that
///      would understate the basket.
contract BasketLens {
    using Math for uint256;

    struct Quote {
        address token;
        uint256 units;
        bool priced;
        uint256 price;
        uint256 updatedAt;
        uint256 value;
    }

    error NoFeed(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);

    uint256 private constant ONE = 1e18;

    IStockRegistry public immutable registry;

    constructor(IStockRegistry registry_) {
        registry = registry_;
    }

    /// @return price18 USD per whole token, 1e18-scaled.
    function price(address token) public view returns (uint256 price18, uint256 updatedAt) {
        if (registry.feedOf(token) == address(0)) revert NoFeed(token);
        (, price18, updatedAt) = _tryPrice(token);
    }

    /// @return ok False when the token has no feed configured; the other values are then zero.
    function _tryPrice(address token) private view returns (bool ok, uint256 price18, uint256 updatedAt) {
        address feed = registry.feedOf(token);
        if (feed == address(0)) return (false, 0, 0);

        (, int256 answer,, uint256 updated,) = AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(token);

        return (true, SafeCast.toUint256(answer).mulDiv(ONE, 10 ** AggregatorV3Interface(feed).decimals()), updated);
    }

    /// @return nav18 USD value backing 1e18 shares.
    /// @return oldestUpdate Earliest `updatedAt` across the basket's feeds.
    function nav(address basket) public view returns (uint256 nav18, uint256 oldestUpdate) {
        Quote[] memory q = quotes(basket);
        oldestUpdate = type(uint256).max;
        for (uint256 i; i < q.length; ++i) {
            if (!q[i].priced) revert NoFeed(q[i].token);
            nav18 += q[i].value;
            if (q[i].updatedAt < oldestUpdate) oldestUpdate = q[i].updatedAt;
        }
    }

    function nav(address basket, uint256 maxAge) external view returns (uint256 nav18) {
        Quote[] memory q = quotes(basket);
        uint256 cutoff = maxAge < block.timestamp ? block.timestamp - maxAge : 0;
        for (uint256 i; i < q.length; ++i) {
            if (!q[i].priced) revert NoFeed(q[i].token);
            if (q[i].updatedAt < cutoff) revert StalePrice(q[i].token, q[i].updatedAt);
            nav18 += q[i].value;
        }
    }

    /// @notice How many of the basket's constituents have no feed, and so make `nav` revert.
    function unpricedCount(address basket) external view returns (uint256 n) {
        Quote[] memory q = quotes(basket);
        for (uint256 i; i < q.length; ++i) {
            if (!q[i].priced) ++n;
        }
    }

    function quotes(address basket) public view returns (Quote[] memory q) {
        IBasketToken.Constituent[] memory recipe = IBasketToken(basket).constituents();
        q = new Quote[](recipe.length);
        for (uint256 i; i < recipe.length; ++i) {
            address token = recipe[i].token;
            (bool ok, uint256 price18, uint256 updatedAt) = _tryPrice(token);
            q[i] = Quote({
                token: token,
                units: recipe[i].units,
                priced: ok,
                price: price18,
                updatedAt: updatedAt,
                value: ok ? recipe[i].units.mulDiv(price18, 10 ** IERC20Metadata(token).decimals()) : 0
            });
        }
    }
}
