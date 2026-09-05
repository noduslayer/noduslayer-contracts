// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// The chain config pins addresses and facts about live contracts. This runs daily against mainnet and
/// fails when any of them has moved: a token that is no longer a contract, a feed that stopped answering,
/// a stock token whose beacon is not the one on record, or the beacon pointing at logic nobody reviewed.
/// A red run here is the runbook's "drift" signal, made concrete.
contract ConfigDriftTest is Test {
    /// ERC-1967's beacon slot: where a BeaconProxy keeps the address it asks for its logic.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    string internal json;
    address[] internal tokens;
    address[] internal feeds;
    string[] internal symbols;

    modifier onFork() {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
        _;
    }

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork("robinhood");
        json = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.json"));
        tokens = vm.parseJsonAddressArray(json, ".stockTokens");
        feeds = vm.parseJsonAddressArray(json, ".stockFeeds");
        symbols = vm.parseJsonStringArray(json, ".stockSymbols");
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid, "config is for another chain");
    }

    function test_Fork_EveryListedTokenIsStillAnEighteenDecimalContract() public onFork {
        for (uint256 i; i < tokens.length; ++i) {
            assertGt(tokens[i].code.length, 0, string.concat("no code at ", symbols[i]));
            assertEq(IERC20Metadata(tokens[i]).decimals(), 18, string.concat("decimals moved: ", symbols[i]));
        }
    }

    /// Every stock token proxies through one beacon, and that beacon's logic is what the audit reviewed.
    function test_Fork_EveryStockTokenStillSitsBehindTheRecordedBeacon() public onFork {
        address beacon = vm.parseJsonAddress(json, ".stockBeacon");
        address logic = vm.parseJsonAddress(json, ".stockBeaconImplementation");
        for (uint256 i; i < tokens.length; ++i) {
            address seen = address(uint160(uint256(vm.load(tokens[i], BEACON_SLOT))));
            assertEq(seen, beacon, string.concat("beacon changed: ", symbols[i]));
        }
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        assertTrue(ok, "beacon does not answer implementation()");
        assertEq(abi.decode(ret, (address)), logic, "the beacon points at new logic: review before relying on it");
    }

    function test_Fork_EveryRecordedFeedStillPrints() public onFork {
        uint256 priced;
        for (uint256 i; i < feeds.length; ++i) {
            if (feeds[i] == address(0)) continue;
            priced++;
            AggregatorV3Interface feed = AggregatorV3Interface(feeds[i]);
            assertEq(feed.decimals(), 8, string.concat("feed decimals moved: ", symbols[i]));
            (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
            assertGt(answer, 0, string.concat("feed answer not positive: ", symbols[i]));
            // Equity feeds are 24/5; a week of silence is a dead feed, not a long weekend.
            assertGt(updatedAt + 7 days, block.timestamp, string.concat("feed silent for a week: ", symbols[i]));
        }
        assertGt(priced, 0, "no feeds configured at all");
    }

    function test_Fork_CounterTokensAreWhatTheConfigSays() public onFork {
        address usdg = vm.parseJsonAddress(json, ".usdg");
        address weth = vm.parseJsonAddress(json, ".weth");
        assertEq(IERC20Metadata(usdg).decimals(), 6, "USDG decimals");
        assertEq(IERC20Metadata(weth).decimals(), 18, "WETH decimals");
        assertGt(weth.code.length, 0);
    }
}
