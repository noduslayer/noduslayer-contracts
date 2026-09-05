// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BasketFactory} from "../../src/BasketFactory.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {BasketZap} from "../../src/BasketZap.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";
import {IRouteExecutor} from "../../src/interfaces/IRouteExecutor.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";

/// The V4Quoter this chain runs is Uniswap's current code: no price limit in the single-swap params.
interface IV4Quoter {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IV3SwapRouter {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// A basket leg through Uniswap v4 on Robinhood Chain mainnet, the way the quoter encodes it: the zap prefunds
/// the UniversalRouter, the router settles the swap from that balance, takes the output to the zap and sweeps
/// the remainder back. Runs when FORK_TESTS=true; skipped otherwise.
///
/// The single-swap structs here carry `sqrtPriceLimitX96`. Uniswap removed that field in December 2024 and the
/// V4Quoter deployed on this chain is the newer code, but the UniversalRouter predates the change and decodes
/// ten static words; the quoter mirrors exactly this, so if the router were ever redeployed on the current
/// layout this test would say so before a user's transaction did.
contract UniswapV4RouteForkTest is Test {
    using SafeERC20 for IERC20;

    // UniversalRouter commands and V4Router actions.
    uint8 internal constant CMD_V4_SWAP = 0x10;
    uint8 internal constant CMD_SWEEP = 0x04;
    uint8 internal constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACT_SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant ACT_SETTLE = 0x0b;
    uint8 internal constant ACT_TAKE_ALL = 0x0f;
    address internal constant MSG_SENDER = address(1);
    uint24 internal constant V3_POOL_FEE = 500;

    struct ExactOutputSingleParams {
        IV4Quoter.PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct ExactInputSingleParams {
        IV4Quoter.PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    address internal usdg;
    address internal nvda;
    address internal aapl;
    address internal poolManager;
    address internal universalRouter;
    address internal swapRouter02;
    IV4Quoter internal v4Quoter;
    IV4Quoter.PoolKey internal nvdaPool;

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketToken internal basket;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    modifier onFork() {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
        _;
    }

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("robinhood"));

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.json"));
        string[] memory symbols = vm.parseJsonStringArray(json, ".stockSymbols");
        address[] memory tokens = vm.parseJsonAddressArray(json, ".stockTokens");
        address[] memory feeds = vm.parseJsonAddressArray(json, ".stockFeeds");
        usdg = vm.parseJsonAddress(json, ".usdg");
        uint256 iNvda = _indexOf(symbols, "NVDA");
        uint256 iAapl = _indexOf(symbols, "AAPL");
        nvda = tokens[iNvda];
        aapl = tokens[iAapl];
        poolManager = vm.parseJsonAddress(json, ".uniswap.poolManager");
        universalRouter = vm.parseJsonAddress(json, ".uniswap.universalRouter");
        swapRouter02 = vm.parseJsonAddress(json, ".uniswap.swapRouter02");
        v4Quoter = IV4Quoter(vm.parseJsonAddress(json, ".uniswap.v4Quoter"));
        nvdaPool = _inventoryPool(usdg, nvda);

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        zap = new BasketZap(protocolOwner, factory, treasury, 20, IWETH(vm.parseJsonAddress(json, ".weth")));

        vm.startPrank(protocolOwner);
        registry.list(nvda, feeds[iNvda]);
        registry.list(aapl, feeds[iAapl]);
        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(nvda, 0.2e18);
        recipe[1] = IBasketToken.Constituent(aapl, 0.15e18);
        basket = BasketToken(factory.createBasket("NodusLayer Tech", "TECH", recipe, 10, 10));
        zap.setRouter(universalRouter, true);
        zap.setRouter(swapRouter02, true);
        vm.stopPrank();

        vm.startPrank(poolManager);
        IERC20(usdg).safeTransfer(alice, 5000e6);
        IERC20(nvda).safeTransfer(alice, 10e18);
        IERC20(aapl).safeTransfer(alice, 10e18);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(usdg).approve(address(zap), type(uint256).max);
        IERC20(nvda).approve(address(basket), type(uint256).max);
        IERC20(aapl).approve(address(basket), type(uint256).max);
        basket.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function test_Fork_InventoryPoolIsLiveAndQuotes() public onFork {
        (uint256 amountIn,) = v4Quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: nvdaPool, zeroForOne: true, exactAmount: 0.01e18, hookData: ""})
        );
        console2.log("USDG for 0.01 NVDA through the inventory's first NVDA/USDG pool (6 dec):", amountIn);
        console2.log("  fee", nvdaPool.fee, "tickSpacing", uint256(int256(nvdaPool.tickSpacing)));
        console2.log("  hooks", nvdaPool.hooks);
        assertGt(amountIn, 0.5e6);
        assertLt(amountIn, 20e6);
    }

    function test_Fork_ZapMintWithAV4Leg() public onFork {
        uint256 shares = 0.05e18;
        (uint256[] memory need,) = basket.previewMint(shares);

        (uint256 quoted,) = v4Quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: nvdaPool, zeroForOne: true, exactAmount: uint128(need[0]), hookData: ""
            })
        );
        uint256 cap = quoted + quoted / 100 + 1;

        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = _buyV4(need[0], cap);
        swaps[1] = _buyV3(aapl, need[1], 10e6);

        uint256 usdgBefore = IERC20(usdg).balanceOf(alice);
        vm.prank(alice);
        uint256 netShares = zap.zapMint(address(basket), usdg, cap + 10e6 + 1e6, shares, swaps, bob, block.timestamp);

        uint256 spent = usdgBefore - IERC20(usdg).balanceOf(alice);
        console2.log("USDG spent for 0.05 TECH with NVDA on v4 (6 dec):", spent);
        assertEq(netShares, shares - shares * 10 / 10_000);
        assertEq(basket.balanceOf(bob), netShares);
        // The v4 leg spent about its quote, not its cap: the sweep returned the difference to the zap and
        // the zap refunded it, so alice paid the swaps plus the zap's fee and nothing more.
        assertLt(spent, cap + 10e6);
        assertGt(spent, quoted);
        _assertEmpty(address(zap));
        _assertEmpty(universalRouter);
    }

    function test_Fork_ZapRedeemWithAV4Leg() public onFork {
        vm.prank(alice);
        basket.mint(1e18, alice);

        uint256 shares = 0.5e18;
        (uint256[] memory out,) = basket.previewRedeem(shares);
        (uint256 quoted,) = v4Quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: nvdaPool, zeroForOne: false, exactAmount: uint128(out[0]), hookData: ""
            })
        );

        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](2);
        swaps[0] = _sellV4(out[0], quoted - quoted / 100);
        swaps[1] = _sellV3(aapl, out[1]);

        vm.prank(alice);
        uint256 amountOut = zap.zapRedeem(address(basket), shares, usdg, quoted, swaps, bob, block.timestamp);

        console2.log("USDG received for 0.5 TECH with NVDA on v4 (6 dec):", amountOut);
        assertEq(IERC20(usdg).balanceOf(bob), amountOut);
        assertGt(amountOut, quoted);
        _assertEmpty(address(zap));
        _assertEmpty(universalRouter);
    }

    /// Buys `amountOut` NVDA for at most `cap` USDG: swap, settle from the router's prefunded balance, take
    /// all NVDA to the caller (the zap), then sweep the unspent USDG back to it.
    function _buyV4(uint256 amountOut, uint256 cap) internal view returns (IRouteExecutor.Swap memory) {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactOutputSingleParams({
                poolKey: nvdaPool,
                zeroForOne: true,
                amountOut: uint128(amountOut),
                amountInMaximum: uint128(cap),
                sqrtPriceLimitX96: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(usdg, uint256(0), false);
        params[2] = abi.encode(nvda, amountOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(abi.encodePacked(ACT_SWAP_EXACT_OUT_SINGLE, ACT_SETTLE, ACT_TAKE_ALL), params);
        inputs[1] = abi.encode(usdg, MSG_SENDER, uint256(0));

        return IRouteExecutor.Swap({
            router: universalRouter,
            sellToken: usdg,
            prefund: cap,
            data: abi.encodeWithSignature(
                "execute(bytes,bytes[],uint256)", abi.encodePacked(CMD_V4_SWAP, CMD_SWEEP), inputs, block.timestamp
            )
        });
    }

    /// Sells exactly `amountIn` NVDA, prefunded, for at least `minOut` USDG delivered to the caller.
    function _sellV4(uint256 amountIn, uint256 minOut) internal view returns (IRouteExecutor.Swap memory) {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: nvdaPool,
                zeroForOne: false,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                sqrtPriceLimitX96: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(nvda, uint256(0), false);
        params[2] = abi.encode(usdg, minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE, ACT_TAKE_ALL), params);

        return IRouteExecutor.Swap({
            router: universalRouter,
            sellToken: nvda,
            prefund: amountIn,
            data: abi.encodeWithSignature(
                "execute(bytes,bytes[],uint256)", abi.encodePacked(CMD_V4_SWAP), inputs, block.timestamp
            )
        });
    }

    function _buyV3(address token, uint256 amountOut, uint256 maxIn)
        internal
        view
        returns (IRouteExecutor.Swap memory)
    {
        IV3SwapRouter.ExactOutputSingleParams memory p =
            IV3SwapRouter.ExactOutputSingleParams({
                tokenIn: usdg,
                tokenOut: token,
                fee: V3_POOL_FEE,
                recipient: address(zap),
                amountOut: amountOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            });
        return IRouteExecutor.Swap({
            router: swapRouter02,
            sellToken: usdg,
            prefund: 0,
            data: abi.encodeCall(IV3SwapRouter.exactOutputSingle, (p))
        });
    }

    function _sellV3(address token, uint256 amountIn) internal view returns (IRouteExecutor.Swap memory) {
        // SwapRouter02.exactInputSingle((address,address,uint24,address,uint256,uint256,uint160)).
        bytes memory data = abi.encodeWithSelector(
            0x04e45aaf, token, usdg, V3_POOL_FEE, address(zap), amountIn, uint256(0), uint160(0)
        );
        return IRouteExecutor.Swap({router: swapRouter02, sellToken: token, prefund: 0, data: data});
    }

    /// The inventory's first row for the pair, which cmd/v4pools ranks best by its reference quote.
    function _inventoryPool(address a, address b) internal view returns (IV4Quoter.PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        string memory inv = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.v4pools.json"));
        for (uint256 i; vm.keyExistsJson(inv, string.concat(".pools[", vm.toString(i), "].fee")); ++i) {
            string memory row = string.concat(".pools[", vm.toString(i), "]");
            if (vm.parseJsonAddress(inv, string.concat(row, ".currency0")) != c0) continue;
            if (vm.parseJsonAddress(inv, string.concat(row, ".currency1")) != c1) continue;
            return IV4Quoter.PoolKey({
                currency0: c0,
                currency1: c1,
                fee: uint24(vm.parseJsonUint(inv, string.concat(row, ".fee"))),
                tickSpacing: int24(int256(vm.parseJsonUint(inv, string.concat(row, ".tickSpacing")))),
                hooks: vm.parseJsonAddress(inv, string.concat(row, ".hooks"))
            });
        }
        revert("pair not in the v4 inventory");
    }

    function _assertEmpty(address holder) internal view {
        assertEq(IERC20(usdg).balanceOf(holder), 0, "usdg left behind");
        assertEq(IERC20(nvda).balanceOf(holder), 0, "nvda left behind");
        assertEq(IERC20(aapl).balanceOf(holder), 0, "aapl left behind");
    }

    function _indexOf(string[] memory haystack, string memory needle) internal pure returns (uint256) {
        bytes32 wanted = keccak256(bytes(needle));
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(bytes(haystack[i])) == wanted) return i;
        }
        revert(string.concat("symbol not in config: ", needle));
    }
}
