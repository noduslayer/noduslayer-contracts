// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {IBasketToken} from "../src/interfaces/IBasketToken.sol";
import {CreateBasket} from "../script/CreateBasket.s.sol";
import {Govern} from "../script/Govern.s.sol";
import {TimelockAccept} from "../script/TimelockAccept.s.sol";
import {TimelockScript} from "../script/TimelockScript.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// Runs the governance scripts themselves, end to end, against a timelock whose proposer is the address
/// Foundry broadcasts from inside a test. A script nobody has executed is a guess about the runbook.
///
/// The scripts' typed functions are called directly. Only one test goes through `run()`, because `run`
/// reads the process environment, `vm.setEnv` writes it, and tests run in parallel: two tests setting MODE
/// would race. Keep it that way.
contract GovernScriptTest is Test {
    /// forge-std's default sender: what `vm.broadcast()` resolves to when a test calls into a script.
    address internal constant SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    uint256 internal constant DELAY = 2 days;

    /// Operation files land here rather than in governance/ops, which is the real audit trail.
    string internal constant OPS_DIR = "governance/ops-test";
    /// Chain-config prefix. Each test writes its own file under it, so one test removing its file cannot
    /// race another still reading; tests run in parallel and the filesystem is shared.
    string internal constant CONFIG = "_test-govern";

    TimelockController internal timelock;
    StockRegistry internal registry;
    BasketFactory internal factory;
    BasketZap internal zap;
    MockStockToken internal nvda;
    MockStockToken internal aapl;
    MockAggregator internal nvdaFeed;
    MockAggregator internal aaplFeed;

    address internal treasury = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_800_000_000);

        address[] memory who = new address[](1);
        who[0] = SENDER;
        timelock = new TimelockController(DELAY, who, who, address(0));

        nvda = new MockStockToken("NVIDIA", "NVDA");
        aapl = new MockStockToken("Apple", "AAPL");
        nvdaFeed = new MockAggregator(8, 200e8);
        aaplFeed = new MockAggregator(8, 100e8);

        registry = new StockRegistry(address(this));
        registry.list(address(nvda), address(nvdaFeed));
        registry.list(address(aapl), address(aaplFeed));
        factory = new BasketFactory(address(timelock), registry, treasury);
        zap = new BasketZap(address(timelock), factory, treasury, 20);
    }

    // ---------------------------------------------------------------- Govern

    function test_Govern_SchedulesThenExecutesFromTheFile() public {
        Govern g = _govern();
        bytes32 id = g.schedule(timelock, _setFee("zap fee to 30 bps", 30));

        assertTrue(timelock.isOperationPending(id), "scheduled on the timelock");
        assertTrue(vm.exists(g.opPath(id)), "operation file written");
        assertEq(zap.feeBps(), 20, "nothing changes at schedule time");

        vm.expectRevert(bytes("operation not ready: MODE=status shows when"));
        g.execute(timelock, id);

        skip(DELAY);
        g.execute(timelock, id);

        assertEq(zap.feeBps(), 30, "executed what the file described");
        assertTrue(timelock.isOperationDone(id));
        vm.removeFile(g.opPath(id));
    }

    function test_Govern_CancelsAPendingOperation() public {
        Govern g = _govern();
        bytes32 id = g.schedule(timelock, _setFee("zap fee to 30 bps, then cancelled", 30));

        g.cancel(timelock, id);
        assertFalse(timelock.isOperation(id), "a cancelled operation leaves no trace on the timelock");

        skip(DELAY);
        vm.expectRevert(bytes("operation not ready: MODE=status shows when"));
        g.execute(timelock, id);
        assertEq(zap.feeBps(), 20);
        vm.removeFile(g.opPath(id));
    }

    /// The file is the record of what was reviewed. One filed under another id, or edited after the fact,
    /// no longer hashes to its name, and must not execute.
    function test_Govern_RefusesAFileThatDoesNotHashToItsName() public {
        Govern g = _govern();
        bytes32 id = g.schedule(timelock, _setFee("zap fee to 30 bps, tampered", 30));
        bytes32 fake = keccak256("an id the file was not written for");
        vm.copyFile(g.opPath(id), g.opPath(fake));

        skip(DELAY);
        vm.expectRevert(bytes("operation file does not hash to OP: refusing an edited file"));
        g.execute(timelock, fake);

        vm.removeFile(g.opPath(id));
        vm.removeFile(g.opPath(fake));
    }

    function test_Govern_RefusesAFileForAnotherTimelock() public {
        Govern g = _govern();
        bytes32 id = g.schedule(timelock, _setFee("zap fee to 30 bps, wrong timelock", 30));

        address[] memory who = new address[](1);
        who[0] = SENDER;
        TimelockController other = new TimelockController(DELAY, who, who, address(0));

        skip(DELAY);
        vm.expectRevert(bytes("operation file names a different timelock"));
        g.execute(other, id);
        vm.removeFile(g.opPath(id));
    }

    /// The label seeds the salt, so the same label twice is the same operation, which the timelock
    /// refuses. Surfacing that before the broadcast saves the multisig a reverted transaction.
    function test_Govern_RefusesToReuseALabel() public {
        Govern g = _govern();
        bytes32 id = g.schedule(timelock, _setFee("zap fee to 30 bps, reused", 30));

        vm.expectRevert(bytes("operation already scheduled: choose a new LABEL"));
        g.schedule(timelock, _setFee("zap fee to 30 bps, reused", 30));
        vm.removeFile(g.opPath(id));
    }

    function test_Govern_RequiresALabel() public {
        Govern g = _govern();
        vm.expectRevert(bytes("LABEL required: it names the operation and seeds its salt"));
        g.schedule(timelock, _setFee("", 30));
    }

    function test_Govern_BatchesSeveralCallsAtomically() public {
        Govern g = _govern();
        address router = makeAddr("router");

        TimelockScript.Operation memory op;
        op.targets = new address[](2);
        op.targets[0] = address(zap);
        op.targets[1] = address(zap);
        op.values = new uint256[](2);
        op.payloads = new bytes[](2);
        op.payloads[0] = abi.encodeCall(BasketZap.setFee, (25));
        op.payloads[1] = abi.encodeCall(zap.setRouter, (router, true));
        op.label = "fee and router in one operation";
        bytes32 id = g.schedule(timelock, op);

        skip(DELAY);
        g.execute(timelock, id);

        assertEq(zap.feeBps(), 25);
        assertTrue(zap.isRouter(router));
        vm.removeFile(g.opPath(id));
    }

    function test_Govern_StatusReportsEveryState() public {
        Govern g = _govern();
        bytes32 id = g.schedule(timelock, _setFee("zap fee to 30 bps, status", 30));
        g.status(timelock, id); // pending
        skip(DELAY);
        g.status(timelock, id); // ready
        g.execute(timelock, id);
        g.status(timelock, id); // done
        vm.removeFile(g.opPath(id));
    }

    // ---------------------------------------------------------------- TimelockAccept

    function test_TimelockAccept_TakesOwnershipThroughTheFile() public {
        StockRegistry r = new StockRegistry(address(this));
        BasketFactory f = new BasketFactory(address(this), r, treasury);
        BasketZap z = new BasketZap(address(this), f, treasury, 20);
        r.transferOwnership(address(timelock));
        f.transferOwnership(address(timelock));
        z.transferOwnership(address(timelock));

        TimelockAccept s = new TimelockAccept();
        s.setOpsDir(OPS_DIR);
        bytes32 id = s.scheduleAccept(timelock, address(r), address(f), address(z), "");
        assertEq(r.owner(), address(this), "still the deployer's until executed");

        skip(DELAY);
        s.execute(timelock, id);

        assertEq(r.owner(), address(timelock));
        assertEq(f.owner(), address(timelock));
        assertEq(z.owner(), address(timelock));
        vm.removeFile(s.opPath(id));
    }

    // ---------------------------------------------------------------- CreateBasket

    function test_CreateBasket_SchedulesABatchAndExecutesTheStoredRecipe() public {
        _writeChainConfig("-batch");
        _writeSpec("_test-govern-a", "Test A", "TA", 6000, 4000);
        _writeSpec("_test-govern-b", "Test B", "TB", 5000, 5000);

        CreateBasket s = new CreateBasket();
        s.setOpsDir(OPS_DIR);
        string[] memory names = new string[](2);
        names[0] = "_test-govern-a";
        names[1] = "_test-govern-b";
        bytes32 id = s.scheduleBaskets(timelock, names, address(factory), string.concat(CONFIG, "-batch"), 10, "");
        assertEq(factory.baskets().length, 0, "nothing exists until the delay has run");

        // The recipe was priced at schedule time. A price move before execution must not change it: the
        // file, not the feed, is what executes.
        nvdaFeed.set(400e8, block.timestamp);

        skip(DELAY);
        s.execute(timelock, id);

        address[] memory baskets = factory.baskets();
        assertEq(baskets.length, 2);
        assertEq(BasketToken(baskets[0]).symbol(), "TA");
        assertEq(BasketToken(baskets[1]).symbol(), "TB");

        // 60% of a $100 share at $200 is 0.3 NVDA; 40% at $100 is 0.4 AAPL.
        IBasketToken.Constituent[] memory recipe = BasketToken(baskets[0]).constituents();
        assertEq(recipe[0].token, address(nvda));
        assertEq(recipe[0].units, 0.3e18, "units pinned at the scheduled price, not the moved one");
        assertEq(recipe[1].units, 0.4e18);

        vm.removeFile(s.opPath(id));
        vm.removeFile(_configPath("-batch"));
        vm.removeFile(_specPath("_test-govern-a"));
        vm.removeFile(_specPath("_test-govern-b"));
    }

    function test_CreateBasket_RefusesMoreThanOneTransactionShouldCarry() public {
        CreateBasket s = new CreateBasket();
        string[] memory names = new string[](11);
        vm.expectRevert(bytes("too many baskets for one operation: split BASKETS"));
        s.scheduleBaskets(timelock, names, address(factory), CONFIG, 10, "");
    }

    function test_CreateBasket_RefusesAWeightAboveTheDepthCap() public {
        _writeChainConfig("-heavy");
        _writeSpec("_test-govern-heavy", "Heavy", "HV", 9000, 1000); // NVDA is capped at 8000

        CreateBasket s = new CreateBasket();
        s.setOpsDir(OPS_DIR);
        string[] memory names = new string[](1);
        names[0] = "_test-govern-heavy";
        vm.expectRevert(bytes("weight exceeds depth cap: NVDA"));
        s.scheduleBaskets(timelock, names, address(factory), string.concat(CONFIG, "-heavy"), 10, "");

        vm.removeFile(_configPath("-heavy"));
        vm.removeFile(_specPath("_test-govern-heavy"));
    }

    // ---------------------------------------------------------------- the environment adapter

    /// The only test that touches the process environment; see the contract comment.
    function test_Run_ReadsEveryScriptsEnvironment() public {
        vm.setEnv("TIMELOCK", vm.toString(address(timelock)));
        vm.setEnv("OPS_DIR", OPS_DIR);

        // Govern: schedule from TARGETS/CALLDATAS, then execute from OP.
        vm.setEnv("MODE", "schedule");
        vm.setEnv("LABEL", "env: zap fee to 30 bps");
        vm.setEnv("TARGETS", vm.toString(address(zap)));
        vm.setEnv("CALLDATAS", vm.toString(abi.encodeCall(BasketZap.setFee, (30))));
        bytes32 fee = new Govern().run();

        // TimelockAccept: schedule from REGISTRY/FACTORY/ZAP with the default label.
        StockRegistry r = new StockRegistry(address(this));
        r.transferOwnership(address(timelock));
        BasketFactory f = new BasketFactory(address(this), r, treasury);
        f.transferOwnership(address(timelock));
        BasketZap z = new BasketZap(address(this), f, treasury, 20);
        z.transferOwnership(address(timelock));
        vm.setEnv("LABEL", "");
        vm.setEnv("REGISTRY", vm.toString(address(r)));
        vm.setEnv("FACTORY", vm.toString(address(f)));
        vm.setEnv("ZAP", vm.toString(address(z)));
        bytes32 accept = new TimelockAccept().run();

        // CreateBasket: schedule from BASKETS/FACTORY/CONFIG with a label from the environment.
        _writeChainConfig("-env");
        _writeSpec("_test-govern-env", "Env", "ENV", 5000, 5000);
        vm.setEnv("LABEL", "env: create basket");
        vm.setEnv("FACTORY", vm.toString(address(factory)));
        vm.setEnv("CONFIG", string.concat(CONFIG, "-env"));
        vm.setEnv("BASKETS", "_test-govern-env");
        bytes32 create = new CreateBasket().run();

        skip(DELAY);
        vm.setEnv("MODE", "status");
        vm.setEnv("OP", vm.toString(fee));
        new Govern().run();

        vm.setEnv("MODE", "execute");
        new Govern().run();
        vm.setEnv("OP", vm.toString(accept));
        new TimelockAccept().run();
        vm.setEnv("OP", vm.toString(create));
        new CreateBasket().run();

        assertEq(zap.feeBps(), 30);
        assertEq(r.owner(), address(timelock));
        assertEq(BasketToken(factory.baskets()[0]).symbol(), "ENV");

        Govern g = _govern();
        vm.removeFile(g.opPath(fee));
        vm.removeFile(g.opPath(accept));
        vm.removeFile(g.opPath(create));
        vm.removeFile(_configPath("-env"));
        vm.removeFile(_specPath("_test-govern-env"));
    }

    // ---------------------------------------------------------------- helpers

    function _govern() internal returns (Govern g) {
        g = new Govern();
        g.setOpsDir(OPS_DIR);
    }

    function _setFee(string memory label, uint16 bps) internal view returns (TimelockScript.Operation memory op) {
        op.targets = new address[](1);
        op.targets[0] = address(zap);
        op.values = new uint256[](1);
        op.payloads = new bytes[](1);
        op.payloads[0] = abi.encodeCall(BasketZap.setFee, (bps));
        op.label = label;
    }

    function _configPath(string memory suffix) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/config/", CONFIG, suffix, ".json");
    }

    function _specPath(string memory name) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/config/baskets/", name, ".json");
    }

    /// Only the keys CreateBasket reads, pointing at the mocks. NVDA is capped at 80% so a cap breach can
    /// be exercised.
    function _writeChainConfig(string memory suffix) internal {
        vm.writeFile(
            _configPath(suffix),
            string.concat(
                '{"chainId": ',
                vm.toString(block.chainid),
                ', "stockSymbols": ["NVDA", "AAPL"], "stockTokens": ["',
                vm.toString(address(nvda)),
                '", "',
                vm.toString(address(aapl)),
                '"], "stockFeeds": ["',
                vm.toString(address(nvdaFeed)),
                '", "',
                vm.toString(address(aaplFeed)),
                '"], "stockMaxWeightBps": [8000, 8000], "constituentPolicy": {"minWeightBps": 100}}\n'
            )
        );
    }

    function _writeSpec(string memory name, string memory title, string memory symbol, uint256 w0, uint256 w1)
        internal
    {
        vm.writeFile(
            _specPath(name),
            string.concat(
                '{"name": "',
                title,
                '", "symbol": "',
                symbol,
                '", "mintFeeBps": 10, "redeemFeeBps": 10, "navPerShareUsd": 100, ',
                '"symbols": ["NVDA", "AAPL"], "weightsBps": [',
                vm.toString(w0),
                ", ",
                vm.toString(w1),
                "]}\n"
            )
        );
    }
}
