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

    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256);
}

/// Measures what a retail-sized basket purchase actually costs on Robinhood Chain.
contract RetailEconomicsForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant TICKET_USDG = 1000e6;
    uint24 internal constant FEE_LOW = 500;
    uint24 internal constant FEE_MED = 3000;

    address internal usdg;
    address internal pm;
    address internal router;
    string[] internal want = ["NVDA", "AAPL", "GOOGL", "MSFT"];
    uint24[4] internal fees = [FEE_LOW, FEE_LOW, FEE_LOW, FEE_MED];
    address[] internal tokens;

    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    BasketToken internal basket;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("robinhood"));

        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/config/robinhood-mainnet.json"));
        usdg = vm.parseJsonAddress(j, ".usdg");
        pm = vm.parseJsonAddress(j, ".uniswap.poolManager");
        router = vm.parseJsonAddress(j, ".uniswap.swapRouter02");
        string[] memory syms = vm.parseJsonStringArray(j, ".stockSymbols");
        address[] memory toks = vm.parseJsonAddressArray(j, ".stockTokens");
        address[] memory feeds = vm.parseJsonAddressArray(j, ".stockFeeds");

        registry = new StockRegistry(owner);
        factory = new BasketFactory(owner, registry, treasury);
        zap = new BasketZap(owner, factory, treasury, 20, IWETH(vm.parseJsonAddress(j, ".weth")));

        IBasketToken.Constituent[] memory recipe = new IBasketToken.Constituent[](want.length);
        uint256[4] memory units = [uint256(0.1303e18), 0.0764e18, 0.0731e18, 0.0393e18];
        vm.startPrank(owner);
        for (uint256 i; i < want.length; ++i) {
            uint256 k = _indexOf(syms, want[i]);
            tokens.push(toks[k]);
            registry.list(toks[k], feeds[k]);
            recipe[i] = IBasketToken.Constituent(toks[k], units[i]);
        }
        basket = BasketToken(factory.createBasket("NodusLayer Tech", "TECH", recipe, 10, 10));
        zap.setRouter(router, true);
        vm.stopPrank();

        vm.prank(pm);
        IERC20(usdg).safeTransfer(alice, 50_000e6);
        vm.prank(alice);
        IERC20(usdg).approve(address(zap), type(uint256).max);
    }

    function test_Fork_RetailTicketCostBreakdown() public {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);

        // ~$1,000 of a basket whose NAV is ~$100/share
        uint256 shares = 9.5e18;
        (uint256[] memory need,) = basket.previewMint(shares);

        IRouteExecutor.Swap[] memory swaps = new IRouteExecutor.Swap[](want.length);
        for (uint256 i; i < want.length; ++i) {
            swaps[i] = IRouteExecutor.Swap({
                router: router,
                sellToken: usdg,
                prefund: 0,
                data: abi.encodeCall(
                    IV3SwapRouter.exactOutputSingle,
                    (IV3SwapRouter.ExactOutputSingleParams({
                            tokenIn: usdg,
                            tokenOut: tokens[i],
                            fee: fees[i],
                            recipient: address(zap),
                            amountOut: need[i],
                            amountInMaximum: TICKET_USDG,
                            sqrtPriceLimitX96: 0
                        }))
                )
            });
        }

        uint256 before = IERC20(usdg).balanceOf(alice);
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 netShares = zap.zapMint(address(basket), usdg, TICKET_USDG, shares, swaps, alice, block.timestamp);
        uint256 firstGas = g - gasleft();
        uint256 spent = before - IERC20(usdg).balanceOf(alice);

        // Every later buyer of this basket reuses the standing allowance: this is the steady-state cost.
        vm.prank(alice);
        g = gasleft();
        zap.zapMint(address(basket), usdg, TICKET_USDG, shares, swaps, alice, block.timestamp);
        uint256 steadyGas = g - gasleft();

        console2.log("constituents            ", want.length);
        console2.log("gas: first buyer        ", firstGas);
        console2.log("gas: steady state       ", steadyGas);
        console2.log("cost cents: first       ", firstGas * tx.gasprice * 2504 / 1e16);
        console2.log("cost cents: steady      ", steadyGas * tx.gasprice * 2504 / 1e16);
        console2.log("USDG spent (6dp)        ", spent);
        console2.log("shares minted (18dp)    ", netShares);

        assertGt(netShares, 0);
        assertLe(spent, TICKET_USDG);
        assertLt(steadyGas, firstGas);
    }

    function test_Fork_SingleSwapGasBaseline() public {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);

        vm.startPrank(alice);
        IERC20(usdg).approve(router, type(uint256).max);
        uint256 g = gasleft();
        IV3SwapRouter(router)
            .exactOutputSingle(
                IV3SwapRouter.ExactOutputSingleParams({
                    tokenIn: usdg,
                    tokenOut: tokens[0],
                    fee: FEE_LOW,
                    recipient: alice,
                    amountOut: 1e18,
                    amountInMaximum: 1000e6,
                    sqrtPriceLimitX96: 0
                })
            );
        uint256 gasUsed = g - gasleft();
        vm.stopPrank();

        console2.log("gas used (1 plain swap) ", gasUsed);
        console2.log("gas cost (USD cents)    ", gasUsed * tx.gasprice * 2504 / 1e16);
    }

    function _indexOf(string[] memory h, string memory n) internal pure returns (uint256) {
        bytes32 want_ = keccak256(bytes(n));
        for (uint256 i; i < h.length; ++i) {
            if (keccak256(bytes(h[i])) == want_) return i;
        }
        revert("symbol missing");
    }
}
