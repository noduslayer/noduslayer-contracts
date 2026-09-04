// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {TimelockScript} from "./TimelockScript.sol";

/// @notice Schedules the creation of one or more baskets through the timelock, from config/baskets/<name>.json.
///
/// @dev Specs declare target weights, not units. Units are derived from live Chainlink prices when the
///      operation is scheduled, checked against each constituent's depth cap, and pinned in the operation
///      file, so what executes after the delay is exactly the recipe that was reviewed rather than a fresh
///      derivation from wherever prices sit two days later.
///
///      createBasket costs about 2.25M gas per basket (measured in test/BasketFactory.t.sol), so one
///      operation carries at most CHUNK baskets, ten by default, to stay well inside a 32M transaction.
///      Launch the catalogue as several operations.
///
///      Env for schedule: FACTORY, BASKETS (comma-separated spec names), TIMELOCK; optional CONFIG
///      (robinhood-mainnet), CHUNK (10), LABEL (default names the baskets). Other modes: see TimelockScript.
contract CreateBasket is TimelockScript {
    uint256 private constant BPS = 10_000;

    string private chainJson;
    string private spec;

    function run() external returns (bytes32) {
        TimelockController tl = _envTimelock();
        if (!_mode("schedule")) return _stored(tl);

        Operation memory op = _operation(
            vm.envString("BASKETS", ","),
            vm.envAddress("FACTORY"),
            vm.envOr("CONFIG", string("robinhood-mainnet")),
            vm.envOr("CHUNK", uint256(10)),
            vm.envOr("LABEL", string(""))
        );
        return schedule(tl, _envOperation(op));
    }

    /// @notice Schedules the baskets named in `names` as one operation against `factory`.
    function scheduleBaskets(
        TimelockController tl,
        string[] memory names,
        address factory,
        string memory config,
        uint256 chunk,
        string memory label
    ) public returns (bytes32) {
        return schedule(tl, _operation(names, factory, config, chunk, label));
    }

    function _operation(
        string[] memory names,
        address factory,
        string memory config,
        uint256 chunk,
        string memory label
    ) private returns (Operation memory op) {
        require(names.length != 0, "BASKETS required");
        require(names.length <= chunk, "too many baskets for one operation: split BASKETS");

        chainJson = vm.readFile(string.concat(vm.projectRoot(), "/config/", config, ".json"));
        require(vm.parseJsonUint(chainJson, ".chainId") == block.chainid, "config/chain mismatch");

        op.targets = new address[](names.length);
        op.values = new uint256[](names.length);
        op.payloads = new bytes[](names.length);

        string memory named = "create baskets:";
        for (uint256 i; i < names.length; ++i) {
            op.targets[i] = factory;
            op.payloads[i] = _payload(names[i]);
            named = string.concat(named, " ", names[i]);
        }
        op.label = bytes(label).length != 0 ? label : named;
    }

    function _payload(string memory name) private returns (bytes memory) {
        spec = vm.readFile(string.concat(vm.projectRoot(), "/config/baskets/", name, ".json"));
        console2.log(string.concat(name, " (", vm.parseJsonString(spec, ".symbol"), ")"));
        IBasketToken.Constituent[] memory recipe = _buildRecipe();
        return abi.encodeCall(
            BasketFactory.createBasket,
            (
                vm.parseJsonString(spec, ".name"),
                vm.parseJsonString(spec, ".symbol"),
                recipe,
                uint16(vm.parseJsonUint(spec, ".mintFeeBps")),
                uint16(vm.parseJsonUint(spec, ".redeemFeeBps"))
            )
        );
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
