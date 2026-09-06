// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DevnetToken, IUniswapV3FactoryLike, IUniswapV3PoolLike, LiquiditySeeder} from "./Devnet.s.sol";
import {RehearsalFeed} from "./RehearsalFixture.s.sol";

/// @notice Wrapped ether for the testnet: a real wrapper for whoever deposits ether, and mintable so pools can
///         be seeded without an ether balance nobody has on a testnet. Withdrawals pay out only what has been
///         deposited. Never deploy this to mainnet.
contract TestnetWETH is ERC20 {
    constructor() ERC20("Wrapped Ether (testnet)", "WETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: send");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stands up a complete market on Robinhood Chain testnet, which mirrors nothing of mainnet: its own
///         Uniswap v3 (factory, SwapRouter02 and QuoterV2 from the published creation bytecode under
///         script/artifacts, unless V3_FACTORY, SWAP_ROUTER02 and QUOTER_V2 name an existing deployment),
///         stand-in stock tokens and feeds priced from mainnet at run time, a six-decimal USDG, a wrapped
///         ether, and pools with deep liquidity against both. It then writes the chain config the deployment
///         scripts, the quoter and the app read, so the protocol on testnet is deployed and quoted exactly
///         the way mainnet will be, against a market that behaves like mainnet's.
///
/// @dev Env: SYMBOLS and PRICES (comma-separated, aligned; prices in 8 decimals like a Chainlink feed),
///      ETH_PRICE (8 decimals), OUT (config name, default robinhood-testnet). Refuses any chain but 46630.
contract TestnetFixture is Script {
    /// The full tick range at tick spacing 10, so a pool quotes at any size a test asks for.
    int24 internal constant LOWER = -887_270;
    int24 internal constant UPPER = 887_270;
    uint24 internal constant FEE = 500;
    uint256 internal constant Q96 = 2 ** 96;
    /// Depth per side of every pool, in dollars.
    uint256 internal constant DEPTH_USD = 3_000_000;

    IUniswapV3FactoryLike internal factory;
    address internal router;
    address internal quoter;
    TestnetWETH internal weth;
    DevnetToken internal usdg;
    RehearsalFeed internal ethFeed;
    LiquiditySeeder internal seeder;

    function run() external {
        require(block.chainid == 46_630, "testnet only: Robinhood Chain testnet, chain id 46630");
        string[] memory symbols = vm.envString("SYMBOLS", ",");
        uint256[] memory prices = vm.envUint("PRICES", ",");
        uint256 ethPrice = vm.envUint("ETH_PRICE");
        require(symbols.length == prices.length && symbols.length > 0, "SYMBOLS and PRICES must align");

        address[] memory tokens = new address[](symbols.length);
        address[] memory feeds = new address[](symbols.length);

        vm.startBroadcast();
        weth = new TestnetWETH();
        _uniswap();
        usdg = new DevnetToken("Global Dollar (testnet)", "USDG", 6);
        ethFeed = new RehearsalFeed(int256(ethPrice));
        seeder = new LiquiditySeeder();
        usdg.mint(address(seeder), 1e30);
        weth.mint(address(seeder), 1e27);

        _pool(address(weth), 18, ethPrice, address(usdg), 6, 1e8);
        for (uint256 i; i < symbols.length; ++i) {
            DevnetToken token = new DevnetToken(string.concat(symbols[i], " (testnet)"), symbols[i], 18);
            token.mint(address(seeder), 1e30);
            tokens[i] = address(token);
            feeds[i] = address(new RehearsalFeed(int256(prices[i])));
            _pool(address(token), 18, prices[i], address(usdg), 6, 1e8);
            _pool(address(token), 18, prices[i], address(weth), 18, ethPrice);
        }
        vm.stopBroadcast();

        _writeConfig(symbols, tokens, feeds);
    }

    /// @dev An existing Uniswap v3 when the env names one, otherwise a fresh one from the published bytecode.
    ///      The factory's owner is the broadcaster; the router and quoter carry this factory and WETH as
    ///      immutables, which is why they cannot be copied from another chain.
    function _uniswap() private {
        address existing = vm.envOr("V3_FACTORY", address(0));
        if (existing != address(0)) {
            factory = IUniswapV3FactoryLike(existing);
            router = vm.envAddress("SWAP_ROUTER02");
            quoter = vm.envAddress("QUOTER_V2");
            return;
        }
        factory = IUniswapV3FactoryLike(_create(vm.getCode("script/artifacts/uniswap/UniswapV3Factory.json"), ""));
        router = _create(
            vm.getCode("script/artifacts/uniswap/SwapRouter02.json"),
            abi.encode(address(0), address(factory), address(0), address(weth))
        );
        quoter =
            _create(vm.getCode("script/artifacts/uniswap/QuoterV2.json"), abi.encode(address(factory), address(weth)));
    }

    function _create(bytes memory creation, bytes memory args) private returns (address addr) {
        bytes memory code = bytes.concat(creation, args);
        assembly ("memory-safe") {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "deployment failed");
    }

    /// One side of a pool: the token, its decimals and its dollar price in 8 decimals.
    struct Side {
        address token;
        uint8 decimals;
        uint256 price;
    }

    function _pool(address a, uint8 decA, uint256 priceA, address b, uint8 decB, uint256 priceB) private {
        Side memory s0 = Side({token: a, decimals: decA, price: priceA});
        Side memory s1 = Side({token: b, decimals: decB, price: priceB});
        if (b < a) (s0, s1) = (s1, s0);

        uint160 sqrtPriceX96 = _sqrtPriceX96(s0, s1);
        address pool = factory.createPool(s0.token, s1.token, FEE);
        IUniswapV3PoolLike(pool).initialize(sqrtPriceX96);
        seeder.seed(pool, LOWER, UPPER, _liquidityFor(s0, sqrtPriceX96));
    }

    function _sqrtPriceX96(Side memory s0, Side memory s1) private pure returns (uint160) {
        uint256 ratioX192 = Math.mulDiv(s0.price * 10 ** s1.decimals, 2 ** 192, s1.price * 10 ** s0.decimals);
        uint256 root = Math.sqrt(ratioX192);
        require(root <= type(uint160).max, "price out of range");
        return uint160(root);
    }

    function _liquidityFor(Side memory s0, uint160 sqrtPriceX96) private pure returns (uint128) {
        uint256 amount0 = DEPTH_USD * 1e8 * 10 ** s0.decimals / s0.price;
        uint256 liquidity = Math.mulDiv(amount0, sqrtPriceX96, Q96);
        require(liquidity <= type(uint128).max, "liquidity overflow");
        return uint128(liquidity);
    }

    function _writeConfig(string[] memory symbols, address[] memory tokens, address[] memory feeds) private {
        string memory name = vm.envOr("OUT", string("robinhood-testnet"));
        string memory path = string.concat(vm.projectRoot(), "/config/", name, ".json");
        vm.writeFile(path, string.concat(_header(), _arrays(symbols, tokens, feeds)));
        console2.log("wrote", path);
        console2.log("weth   ", address(weth));
        console2.log("usdg   ", address(usdg));
        console2.log("factory", address(factory));
        console2.log("router ", router);
        console2.log("quoter ", quoter);
    }

    function _header() private view returns (string memory) {
        string memory zero = vm.toString(address(0));
        return string.concat(
            "{\n",
            '  "_comment": "Generated by script/TestnetFixture.s.sol on Robinhood Chain testnet. Every token, feed and ',
            "pool is a stand-in deployed by that script, priced from mainnet's feeds at the time; the Uniswap v3 ",
            'contracts are the published bytecode deployed for this purpose. Nothing here describes mainnet.",\n',
            '  "chainId": 46630,\n',
            '  "usdg": "',
            vm.toString(address(usdg)),
            '",\n',
            '  "weth": "',
            vm.toString(address(weth)),
            '",\n',
            '  "ethUsdFeed": "',
            vm.toString(address(ethFeed)),
            '",\n',
            '  "routers": ["',
            vm.toString(router),
            '"],\n',
            '  "uniswap": {"quoterV2": "',
            vm.toString(quoter),
            '", "swapRouter02": "',
            vm.toString(router),
            '", "v3Factory": "',
            vm.toString(address(factory)),
            '", "poolManager": "',
            zero,
            '", "v4Quoter": "',
            zero,
            '"},\n',
            '  "constituentPolicy": {"targetTradeUsd": 5000, "maxDepthShareBps": 100, "minWeightBps": 100, ',
            '"note": "Every pool is seeded with the same depth, so caps are left open."},\n'
        );
    }

    function _arrays(string[] memory symbols, address[] memory tokens, address[] memory feeds)
        private
        pure
        returns (string memory)
    {
        string memory syms;
        string memory toks;
        string memory fds;
        string memory caps;
        for (uint256 i; i < symbols.length; ++i) {
            string memory sep = i == 0 ? "" : ", ";
            syms = string.concat(syms, sep, '"', symbols[i], '"');
            toks = string.concat(toks, sep, '"', vm.toString(tokens[i]), '"');
            fds = string.concat(fds, sep, '"', vm.toString(feeds[i]), '"');
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
}
