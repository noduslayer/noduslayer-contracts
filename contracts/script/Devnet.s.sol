// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RehearsalFeed} from "./RehearsalFixture.s.sol";

/// @notice A stand-in token for the local devnet: mintable by anyone, with EIP-2612, at any decimals.
/// @dev Never deploy this to mainnet.
contract DevnetToken is ERC20Permit {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) ERC20Permit(name_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Wrapped ether for the local devnet, placed at mainnet's WETH address by script/devnet.sh so the
///         router and quoter, which carry that address as an immutable, find a WETH there. Mainnet's own
///         WETH is an upgradeable proxy whose storage cannot be read out wholesale, so this stands in.
///         Name, symbol and decimals are constants: nothing lives in storage that a bytecode copy would lose.
/// @dev Never deploy this to mainnet.
contract DevnetWETH {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);
    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function name() external pure returns (string memory) {
        return "Wrapped Ether";
    }

    function symbol() external pure returns (string memory) {
        return "WETH";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WETH: balance");
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: send");
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WETH: balance");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, "WETH: allowance");
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }
}

interface IUniswapV3FactoryLike {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3PoolLike {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IWETH9Like {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Holds tokens and pays a pool whatever it asks for when a position is minted.
contract LiquiditySeeder {
    using SafeERC20 for IERC20;

    function seed(address pool, int24 lower, int24 upper, uint128 liquidity) external returns (uint256, uint256) {
        return IUniswapV3PoolLike(pool).mint(address(this), lower, upper, liquidity, "");
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        IUniswapV3PoolLike pool = IUniswapV3PoolLike(msg.sender);
        if (amount0Owed > 0) IERC20(pool.token0()).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) IERC20(pool.token1()).safeTransfer(msg.sender, amount1Owed);
    }
}

/// @notice Stands up a self-contained market on a local anvil: stock tokens and feeds for the symbols asked
///         for, a six-decimal USDG, and Uniswap v3 pools against USDG and WETH with deep liquidity, then
///         writes a chain config the deployment scripts and the quoter read.
///
/// @dev The Uniswap contracts themselves are mainnet's bytecode placed at mainnet's addresses by
///      script/devnet.sh before this runs, so the router and quoter keep the factory and WETH addresses
///      baked into them. A fork of mainnet cannot serve this purpose: the public RPC keeps state for about
///      ten minutes of blocks, and a quote against a fork older than that fails on the first storage slot
///      it has not seen. Never run this against anything but a local node; it checks.
///
///      Env: SYMBOLS and PRICES (comma-separated, aligned; prices in 8 decimals like a Chainlink feed),
///      ETH_PRICE (8 decimals), OUT (config name, default robinhood-devnet).
contract Devnet is Script {
    using SafeERC20 for IERC20;

    /// The full tick range at tick spacing 10, so a pool quotes at any size a test asks for.
    int24 internal constant LOWER = -887_270;
    int24 internal constant UPPER = 887_270;
    uint24 internal constant FEE = 500;
    uint256 internal constant Q96 = 2 ** 96;
    /// Depth per side of every pool, in dollars.
    uint256 internal constant DEPTH_USD = 3_000_000;

    IUniswapV3FactoryLike internal factory;
    address internal weth;
    DevnetToken internal usdg;
    LiquiditySeeder internal seeder;

    function run() external {
        require(block.chainid == 4663 && block.number < 10_000, "devnet only: a local node with chain id 4663");
        string memory mainnet = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.json"));
        factory = IUniswapV3FactoryLike(vm.parseJsonAddress(mainnet, ".uniswap.v3Factory"));
        weth = vm.parseJsonAddress(mainnet, ".weth");
        require(address(factory).code.length > 0 && weth.code.length > 0, "place the Uniswap and WETH bytecode first");

        string[] memory symbols = vm.envString("SYMBOLS", ",");
        uint256[] memory prices = vm.envUint("PRICES", ",");
        uint256 ethPrice = vm.envUint("ETH_PRICE");
        require(symbols.length == prices.length && symbols.length > 0, "SYMBOLS and PRICES must align");

        address[] memory tokens = new address[](symbols.length);
        address[] memory feeds = new address[](symbols.length);

        vm.startBroadcast();
        usdg = new DevnetToken("Global Dollar", "USDG", 6);
        seeder = new LiquiditySeeder();
        usdg.mint(address(seeder), 1e30);
        IWETH9Like(weth).deposit{value: 200_000 ether}();
        IERC20(weth).safeTransfer(address(seeder), 200_000 ether);

        _pool(weth, 18, ethPrice, address(usdg), 6, 1e8);
        for (uint256 i; i < symbols.length; ++i) {
            DevnetToken token = new DevnetToken(string.concat(symbols[i], " (devnet)"), symbols[i], 18);
            token.mint(address(seeder), 1e30);
            tokens[i] = address(token);
            feeds[i] = address(new RehearsalFeed(int256(prices[i])));
            _pool(address(token), 18, prices[i], address(usdg), 6, 1e8);
            _pool(address(token), 18, prices[i], weth, 18, ethPrice);
        }
        vm.stopBroadcast();

        _writeConfig(mainnet, symbols, tokens, feeds);
    }

    /// One side of a pool: the token, its decimals and its dollar price in 8 decimals.
    struct Side {
        address token;
        uint8 decimals;
        uint256 price;
    }

    /// @dev Creates and initialises the pool at the ratio of the two dollar prices, then seeds DEPTH_USD of
    ///      token0, which draws the matching amount of token1.
    function _pool(address a, uint8 decA, uint256 priceA, address b, uint8 decB, uint256 priceB) private {
        Side memory s0 = Side({token: a, decimals: decA, price: priceA});
        Side memory s1 = Side({token: b, decimals: decB, price: priceB});
        if (b < a) (s0, s1) = (s1, s0);

        uint160 sqrtPriceX96 = _sqrtPriceX96(s0, s1);
        address pool = factory.createPool(s0.token, s1.token, FEE);
        IUniswapV3PoolLike(pool).initialize(sqrtPriceX96);
        seeder.seed(pool, LOWER, UPPER, _liquidityFor(s0, sqrtPriceX96));
    }

    /// @dev sqrt(token1 raw units per token0 raw unit) scaled by 2^96, through a 512-bit intermediate.
    function _sqrtPriceX96(Side memory s0, Side memory s1) private pure returns (uint160) {
        uint256 ratioX192 = Math.mulDiv(s0.price * 10 ** s1.decimals, 2 ** 192, s1.price * 10 ** s0.decimals);
        uint256 root = Math.sqrt(ratioX192);
        require(root <= type(uint160).max, "price out of range");
        return uint160(root);
    }

    /// @dev Over the full range amount0 is about L * 2^96 / sqrtP, so L for DEPTH_USD of token0 is
    ///      amount0 * sqrtP / 2^96.
    function _liquidityFor(Side memory s0, uint160 sqrtPriceX96) private pure returns (uint128) {
        uint256 amount0 = DEPTH_USD * 1e8 * 10 ** s0.decimals / s0.price;
        uint256 liquidity = Math.mulDiv(amount0, sqrtPriceX96, Q96);
        require(liquidity <= type(uint128).max, "liquidity overflow");
        return uint128(liquidity);
    }

    function _writeConfig(
        string memory mainnet,
        string[] memory symbols,
        address[] memory tokens,
        address[] memory feeds
    ) private {
        string memory name = vm.envOr("OUT", string("robinhood-devnet"));
        string memory path = string.concat(vm.projectRoot(), "/config/", name, ".json");
        vm.writeFile(path, string.concat(_header(mainnet), _arrays(symbols, tokens, feeds)));
        console2.log("wrote", path);
        console2.log("usdg  ", address(usdg));
        console2.log("seeder", address(seeder));
    }

    function _header(string memory mainnet) private view returns (string memory) {
        string memory zero = vm.toString(address(0));
        string memory router = vm.toString(vm.parseJsonAddress(mainnet, ".uniswap.swapRouter02"));
        string memory quoter = vm.toString(vm.parseJsonAddress(mainnet, ".uniswap.quoterV2"));
        return string.concat(
            "{\n",
            '  "_comment": "Generated by script/Devnet.s.sol for a local anvil. Tokens, feeds and pools are local; the ',
            'Uniswap contracts are mainnet bytecode at mainnet addresses. Never a description of mainnet.",\n',
            '  "chainId": 4663,\n',
            '  "usdg": "',
            vm.toString(address(usdg)),
            '",\n',
            '  "weth": "',
            vm.toString(weth),
            '",\n',
            '  "routers": ["',
            router,
            '"],\n',
            '  "uniswap": {"quoterV2": "',
            quoter,
            '", "swapRouter02": "',
            router,
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
