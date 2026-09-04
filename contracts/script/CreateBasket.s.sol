// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";

/// @notice Creates a basket from config/baskets/<BASKET>.json, which declares target weights rather than
///         raw units. Units are derived from live Chainlink prices at creation so a stale spec cannot ship
///         a mispriced recipe, and each weight is checked against the depth-derived cap in the chain config.
/// @dev Env: FACTORY, BASKET; optional CONFIG (robinhood-mainnet). Broadcast by the factory owner.
contract CreateBasket is Script {
    uint256 private constant BPS = 10_000;

    string private chainJson;
    string private spec;

    function run() external {
        string memory root = vm.projectRoot();
        chainJson =
            vm.readFile(string.concat(root, "/config/", vm.envOr("CONFIG", string("robinhood-mainnet")), ".json"));
        spec = vm.readFile(string.concat(root, "/config/baskets/", vm.envString("BASKET"), ".json"));
        require(vm.parseJsonUint(chainJson, ".chainId") == block.chainid, "config/chain mismatch");

        IBasketToken.Constituent[] memory recipe = _buildRecipe();

        vm.startBroadcast();
        address basket = BasketFactory(vm.envAddress("FACTORY"))
            .createBasket(
                vm.parseJsonString(spec, ".name"),
                vm.parseJsonString(spec, ".symbol"),
                recipe,
                uint16(vm.parseJsonUint(spec, ".mintFeeBps")),
                uint16(vm.parseJsonUint(spec, ".redeemFeeBps"))
            );
        vm.stopBroadcast();

        console2.log("Basket", basket);
    }

    function _buildRecipe() private view returns (IBasketToken.Constituent[] memory recipe) {
        string[] memory symbols = vm.parseJsonStringArray(spec, ".symbols");
        uint256[] memory weights = vm.parseJsonUintArray(spec, ".weightsBps");
        require(symbols.length == weights.length, "spec/length mismatch");

        recipe = new IBasketToken.Constituent[](symbols.length);
        uint256 total;
        for (uint256 i; i < symbols.length; ++i) {
            recipe[i] = _constituent(symbols[i], weights[i]);
            total += weights[i];
        }
        require(total == BPS, "weights must sum to 10000");
    }

    function _constituent(string memory symbol, uint256 weightBps)
        private
        view
        returns (IBasketToken.Constituent memory)
    {
        uint256 k = _indexOf(vm.parseJsonStringArray(chainJson, ".stockSymbols"), symbol);
        uint256 cap = vm.parseJsonUintArray(chainJson, ".stockMaxWeightBps")[k];
        require(weightBps >= vm.parseJsonUint(chainJson, ".constituentPolicy.minWeightBps"), "weight below floor");
        require(weightBps <= cap, string.concat("weight exceeds depth cap: ", symbol));

        address feed = vm.parseJsonAddressArray(chainJson, ".stockFeeds")[k];
        require(feed != address(0), string.concat("no on-chain feed, cannot derive units: ", symbol));
        uint256 nav = vm.parseJsonUint(spec, ".navPerShareUsd") * 1e18;
        uint256 units = _units(feed, weightBps, nav);
        console2.log(string.concat("  ", symbol, ": weightBps / capBps / units"), weightBps, cap, units);

        return IBasketToken.Constituent(vm.parseJsonAddressArray(chainJson, ".stockTokens")[k], units);
    }

    /// @dev units = (weight * nav) / price, with the Chainlink answer normalised out of its own decimals.
    function _units(address feed, uint256 weightBps, uint256 nav) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, "feed answer not positive");
        require(updatedAt + 7 days > block.timestamp, "feed too stale to price a new basket");

        uint256 price = SafeCast.toUint256(answer);
        uint256 scale = 10 ** AggregatorV3Interface(feed).decimals();
        return Math.mulDiv(weightBps * nav, scale, BPS * price);
    }

    function _indexOf(string[] memory haystack, string memory needle) private pure returns (uint256) {
        bytes32 wanted = keccak256(bytes(needle));
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(bytes(haystack[i])) == wanted) return i;
        }
        revert(string.concat("symbol not in chain config: ", needle));
    }
}
