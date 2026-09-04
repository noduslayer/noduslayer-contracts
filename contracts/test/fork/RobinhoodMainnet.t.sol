// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BasketFactory} from "../../src/BasketFactory.sol";
import {BasketLens} from "../../src/BasketLens.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {BasketZap} from "../../src/BasketZap.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";
import {IBasketZap} from "../../src/interfaces/IBasketZap.sol";

interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// Runs against Robinhood Chain mainnet when FORK_TESTS=true; skipped otherwise.
contract RobinhoodMainnetForkTest is Test {
    using SafeERC20 for IERC20;

    uint24 internal constant POOL_FEE = 500;

    address internal usdg;
    address internal nvda;
    address internal aapl;
    address internal poolManager;
    address internal swapRouter02;

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketLens internal lens;
    BasketToken internal basket;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    modifier onFork() {
        _skipUnlessFork();
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
        swapRouter02 = vm.parseJsonAddress(json, ".uniswap.swapRouter02");

        registry = new StockRegistry(protocolOwner);
        factory = new BasketFactory(protocolOwner, registry, treasury);
        zap = new BasketZap(protocolOwner, factory, treasury, 20);
        lens = new BasketLens(registry);

        vm.startPrank(protocolOwner);
        registry.list(nvda, feeds[iNvda]);
        registry.list(aapl, feeds[iAapl]);
        basket = BasketToken(factory.createBasket("NodusLayer Tech", "TECH", _recipe(), 10, 10));
        zap.setRouter(swapRouter02, true);
        vm.stopPrank();

        vm.startPrank(poolManager);
        IERC20(nvda).safeTransfer(alice, 10e18);
        IERC20(aapl).safeTransfer(alice, 10e18);
        IERC20(usdg).safeTransfer(alice, 5000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(nvda).approve(address(basket), type(uint256).max);
        IERC20(aapl).approve(address(basket), type(uint256).max);
        IERC20(usdg).approve(address(zap), type(uint256).max);
        basket.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function test_Fork_ConstituentsAreCanonicalRobinhoodTokens() public onFork {
        assertEq(IERC20Metadata(nvda).name(), unicode"NVIDIA • Robinhood Token");
        assertEq(IERC20Metadata(aapl).name(), unicode"Apple • Robinhood Token");
        assertEq(IERC20Metadata(nvda).decimals(), 18);
        assertEq(IERC20Metadata(usdg).decimals(), 6);
    }

    function test_Fork_MintAndRedeemInKindWithRealTokens() public onFork {
        vm.startPrank(alice);
        uint256 netShares = basket.mint(10e18, alice);
        uint256[] memory amountsOut = basket.redeem(5e18, bob);
        vm.stopPrank();

        assertEq(netShares, 9.99e18);
        assertEq(IERC20(nvda).balanceOf(address(basket)), 2e18 - amountsOut[0]);
        assertEq(IERC20(nvda).balanceOf(bob), 0.999e18);
        assertEq(IERC20(aapl).balanceOf(bob), 0.74925e18);
        assertEq(basket.balanceOf(alice), 4.99e18);
    }

    function test_Fork_LensPricesBasketFromChainlink() public onFork {
        (uint256 nav, uint256 oldestUpdate) = lens.nav(address(basket));
        console2.log("NAV per share (USD 1e18):", nav);
        console2.log("oldest feed update:", oldestUpdate);
        assertGt(nav, 50e18);
        assertLt(nav, 300e18);
        assertGt(oldestUpdate, block.timestamp - 7 days);
    }

    function test_Fork_ZapMintThroughUniswapV3() public onFork {
        uint256 shares = 0.05e18;
        (uint256[] memory need,) = basket.previewMint(shares);

        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](2);
        swaps[0] = _buy(nvda, need[0], 10e6);
        swaps[1] = _buy(aapl, need[1], 10e6);

        uint256 usdgBefore = IERC20(usdg).balanceOf(alice);
        vm.prank(alice);
        uint256 netShares = zap.zapMint(address(basket), usdg, 20e6, shares, swaps, bob, block.timestamp);

        uint256 spent = usdgBefore - IERC20(usdg).balanceOf(alice);
        console2.log("USDG spent for 0.05 TECH (6 dec):", spent);
        assertEq(netShares, shares - shares * 10 / 10_000);
        assertEq(basket.balanceOf(bob), netShares);
        assertLt(spent, 20e6);
        assertGt(spent, 3e6);
        _assertZapEmpty();
    }

    function test_Fork_ZapRedeemThroughUniswapV3() public onFork {
        vm.prank(alice);
        basket.mint(1e18, alice);

        uint256 shares = 0.5e18;
        (uint256[] memory out,) = basket.previewRedeem(shares);
        IBasketZap.Swap[] memory swaps = new IBasketZap.Swap[](2);
        swaps[0] = _sell(nvda, out[0]);
        swaps[1] = _sell(aapl, out[1]);

        vm.prank(alice);
        uint256 amountOut = zap.zapRedeem(address(basket), shares, usdg, 40e6, swaps, bob, block.timestamp);

        console2.log("USDG received for 0.5 TECH (6 dec):", amountOut);
        assertEq(IERC20(usdg).balanceOf(bob), amountOut);
        assertGt(amountOut, 40e6);
        _assertZapEmpty();
    }

    function _buy(address token, uint256 amountOut, uint256 maxIn) internal view returns (IBasketZap.Swap memory) {
        IV3SwapRouter.ExactOutputSingleParams memory p = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: usdg,
            tokenOut: token,
            fee: POOL_FEE,
            recipient: address(zap),
            amountOut: amountOut,
            amountInMaximum: maxIn,
            sqrtPriceLimitX96: 0
        });
        return IBasketZap.Swap({
            router: swapRouter02,
            sellToken: usdg,
            prefund: 0,
            data: abi.encodeCall(IV3SwapRouter.exactOutputSingle, (p))
        });
    }

    function _sell(address token, uint256 amountIn) internal view returns (IBasketZap.Swap memory) {
        IV3SwapRouter.ExactInputSingleParams memory p = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: usdg,
            fee: POOL_FEE,
            recipient: address(zap),
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        return IBasketZap.Swap({
            router: swapRouter02,
            sellToken: token,
            prefund: 0,
            data: abi.encodeCall(IV3SwapRouter.exactInputSingle, (p))
        });
    }

    function _indexOf(string[] memory haystack, string memory needle) internal pure returns (uint256) {
        bytes32 wanted = keccak256(bytes(needle));
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(bytes(haystack[i])) == wanted) return i;
        }
        revert(string.concat("symbol not in config: ", needle));
    }

    function _skipUnlessFork() internal {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
    }

    function _assertZapEmpty() internal view {
        assertEq(IERC20(usdg).balanceOf(address(zap)), 0);
        assertEq(IERC20(nvda).balanceOf(address(zap)), 0);
        assertEq(IERC20(aapl).balanceOf(address(zap)), 0);
    }

    function _recipe() internal view returns (IBasketToken.Constituent[] memory recipe) {
        recipe = new IBasketToken.Constituent[](2);
        recipe[0] = IBasketToken.Constituent(nvda, 0.2e18);
        recipe[1] = IBasketToken.Constituent(aapl, 0.15e18);
    }
}
