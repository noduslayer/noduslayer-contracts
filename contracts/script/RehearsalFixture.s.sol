// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A stand-in stock token for deployment rehearsals. Anyone may mint, which is the point.
/// @dev Never deploy this to mainnet. It exists so a rehearsal has tokens to move.
contract RehearsalToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A stand-in for WETH9 with the two functions the zap calls, so `zapMintETH` can be rehearsed.
/// @dev Never deploy this to mainnet, where the canonical WETH is in the chain config.
contract RehearsalWETH is ERC20 {
    constructor() ERC20("Rehearsal Wrapped Ether", "WETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "RehearsalWETH: ether transfer failed");
    }
}

/// @notice A stand-in Chainlink feed with a fixed answer, refreshed to now on every deployment.
/// @dev Never deploy this to mainnet. `set` is unguarded so a rehearsal can move a price.
contract RehearsalFeed {
    int256 private answer;
    uint256 private updatedAt;
    uint80 private round;

    constructor(int256 answer_) {
        set(answer_);
    }

    function set(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
        round++;
    }

    /// @dev A function rather than a public constant so the name matches AggregatorV3Interface exactly.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "rehearsal feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, round);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, round);
    }
}

/// @notice Stands up tokens and feeds for a deployment rehearsal, then writes a chain config for them.
///
/// @dev Robinhood Chain testnet does not mirror mainnet: the stock tokens carry different addresses, several
///      unrelated Uniswap deployments share the same names with no liquidity between them, and there are no
///      canonical Chainlink feeds. A config claiming otherwise would be fiction, so this deploys its own and
///      reports what it actually created.
///
///      What that rehearses: the timelock, two-step ownership, listing the universe in chunks, creating
///      baskets from live feed prices, and minting and redeeming in kind — everything a fork test cannot
///      reach, because it involves real broadcasting, real gas and a real delay elapsing.
///
///      What it does not rehearse: routing. There is no liquidity to route through, so `zapMint` and
///      `zapRedeem` stay covered by the mainnet fork tests.
///
///      Env: OUT (config name, default `robinhood-rehearsal`); optional PRICE_USD_8DP per symbol is not
///      supported — prices come from the table below and are indicative only.
contract RehearsalFixture is Script {
    struct Asset {
        string symbol;
        string name;
        int256 priceUsd8; // 8 decimals, matching a Chainlink USD feed
    }

    function run() external {
        require(block.chainid != 4663, "refusing to deploy rehearsal contracts to mainnet");

        Asset[] memory assets = _assets();
        address[] memory tokens = new address[](assets.length);
        address[] memory feeds = new address[](assets.length);

        vm.startBroadcast();
        for (uint256 i; i < assets.length; ++i) {
            tokens[i] = address(new RehearsalToken(assets[i].name, assets[i].symbol));
            feeds[i] = address(new RehearsalFeed(assets[i].priceUsd8));
        }
        address usdg = address(new RehearsalToken("Rehearsal Global Dollar", "USDG"));
        address weth = address(new RehearsalWETH());
        vm.stopBroadcast();

        _writeConfig(assets, tokens, feeds, usdg, weth);
    }

    /// @dev A deliberately small set. A rehearsal needs enough constituents to exercise a real basket, not
    ///      the whole 194-token universe, and every extra token is gas spent proving nothing new.
    function _assets() private pure returns (Asset[] memory a) {
        a = new Asset[](6);
        a[0] = Asset({symbol: "NVDA", name: "Rehearsal NVIDIA", priceUsd8: 230e8});
        a[1] = Asset({symbol: "AAPL", name: "Rehearsal Apple", priceUsd8: 328e8});
        a[2] = Asset({symbol: "MSFT", name: "Rehearsal Microsoft", priceUsd8: 509e8});
        a[3] = Asset({symbol: "GOOGL", name: "Rehearsal Alphabet", priceUsd8: 342e8});
        a[4] = Asset({symbol: "AMZN", name: "Rehearsal Amazon", priceUsd8: 231e8});
        a[5] = Asset({symbol: "TSLA", name: "Rehearsal Tesla", priceUsd8: 383e8});
    }

    function _writeConfig(
        Asset[] memory assets,
        address[] memory tokens,
        address[] memory feeds,
        address usdg,
        address weth
    ) private {
        string memory name = vm.envOr("OUT", string("robinhood-rehearsal"));
        string memory path = string.concat(vm.projectRoot(), "/config/", name, ".json");

        vm.writeFile(path, string.concat(_header(usdg, weth), _assetArrays(assets, tokens, feeds)));

        console2.log("wrote", path);
        console2.log("usdg ", usdg);
        console2.log("weth ", weth);
        for (uint256 i; i < assets.length; ++i) {
            console2.log(string.concat("  ", assets[i].symbol), tokens[i], feeds[i]);
        }
        console2.log("next: CONFIG=", name);
        console2.log("      forge script script/Deploy.s.sol --rpc-url <testnet> --broadcast");
    }

    function _header(address usdg, address weth) private view returns (string memory) {
        string memory zero = vm.toString(address(0));
        return string.concat(
            "{\n",
            '  "_comment": "Generated by script/RehearsalFixture.s.sol. Every address below is a rehearsal ',
            "contract deployed by that script, not a Robinhood asset. Uniswap addresses are zero and depth ",
            'caps are placeholders: these tokens have no pools.",\n',
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "usdg": "',
            vm.toString(usdg),
            '",\n',
            '  "weth": "',
            vm.toString(weth),
            '",\n',
            '  "routers": [],\n',
            '  "uniswap": {"quoterV2": "',
            zero,
            '", "swapRouter02": "',
            zero,
            '", "v3Factory": "',
            zero,
            '", "poolManager": "',
            zero,
            '", "v4Quoter": "',
            zero,
            '"},\n',
            '  "constituentPolicy": {"targetTradeUsd": 5000, "maxDepthShareBps": 100, "minWeightBps": 100, ',
            '"note": "Placeholder. Rehearsal tokens have no measured depth."},\n'
        );
    }

    function _assetArrays(Asset[] memory assets, address[] memory tokens, address[] memory feeds)
        private
        pure
        returns (string memory)
    {
        string memory syms;
        string memory toks;
        string memory fds;
        string memory caps;
        for (uint256 i; i < assets.length; ++i) {
            string memory sep = i == 0 ? "" : ", ";
            syms = string.concat(syms, sep, '"', assets[i].symbol, '"');
            toks = string.concat(toks, sep, '"', _hex(tokens[i]), '"');
            fds = string.concat(fds, sep, '"', _hex(feeds[i]), '"');
            // Depth cannot be measured for a token with no pools, so the cap is left unconstrained rather
            // than implying a liquidity figure nobody observed.
            caps = string.concat(caps, sep, "10000");
        }
        return string.concat(
            '  "stockSymbols": [',
            syms,
            "],\n",
            '  "stockTokens": [',
            toks,
            "],\n",
            '  "stockFeeds": [',
            fds,
            "],\n",
            '  "stockMaxWeightBps": [',
            caps,
            "]\n}\n"
        );
    }

    function _hex(address a) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 b = bytes20(a);
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 20; ++i) {
            out[2 + i * 2] = alphabet[uint8(b[i]) >> 4];
            out[3 + i * 2] = alphabet[uint8(b[i]) & 0x0f];
        }
        return string(out);
    }
}
