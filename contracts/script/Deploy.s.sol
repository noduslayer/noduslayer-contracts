// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketLens} from "../src/BasketLens.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";

/// @notice Deploys the protocol from config/<CONFIG>.json behind a timelock.
/// @dev Env: MULTISIG (proposer and executor on the timelock), TREASURY (fee recipient).
///      Optional: CONFIG (robinhood-mainnet), ZAP_FEE_BPS (20), TIMELOCK_MIN_DELAY (172800),
///      TIMELOCK (reuse an existing controller instead of deploying one), LIST_CHUNK (50).
///      Ownership is staged, not final: the timelock must accept it, which `TimelockAccept.s.sol` drives.
contract Deploy is Script {
    struct Deployment {
        address timelock;
        address registry;
        address factory;
        address zap;
        address lens;
    }

    function run() external returns (Deployment memory d) {
        string memory json = _config();
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "config/chain mismatch");

        address multisig = vm.envAddress("MULTISIG");
        address treasury = vm.envAddress("TREASURY");
        require(multisig != address(0) && treasury != address(0), "MULTISIG and TREASURY required");

        address[] memory tokens = vm.parseJsonAddressArray(json, ".stockTokens");
        address[] memory feeds = vm.parseJsonAddressArray(json, ".stockFeeds");
        address[] memory routers = vm.parseJsonAddressArray(json, ".routers");
        require(tokens.length == feeds.length, "config/token-feed length");

        vm.startBroadcast();
        address deployer = msg.sender;

        d.timelock = _timelock(multisig);

        StockRegistry registry = new StockRegistry(deployer);
        _listInChunks(registry, tokens, feeds);

        BasketFactory factory = new BasketFactory(deployer, registry, treasury);
        BasketZap zap = new BasketZap(deployer, factory, treasury, uint16(vm.envOr("ZAP_FEE_BPS", uint256(20))));
        for (uint256 i; i < routers.length; ++i) {
            zap.setRouter(routers[i], true);
        }

        d.registry = address(registry);
        d.factory = address(factory);
        d.zap = address(zap);
        d.lens = address(new BasketLens(registry));

        registry.transferOwnership(d.timelock);
        factory.transferOwnership(d.timelock);
        zap.transferOwnership(d.timelock);
        vm.stopBroadcast();

        _report(d, multisig, treasury, tokens.length);
    }

    /// @dev A fresh controller grants the multisig proposer, canceller and executor, and no admin role,
    ///      so the timelock is self-administered from block one and cannot be reconfigured out of band.
    function _timelock(address multisig) private returns (address) {
        address existing = vm.envOr("TIMELOCK", address(0));
        if (existing != address(0)) return existing;

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        uint256 delay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));
        return address(new TimelockController(delay, proposers, executors, address(0)));
    }

    /// @dev Lists the universe in bounded chunks so one oversized calldata blob cannot brick the deploy.
    ///      A feed of `address(0)` lists the token without on-chain pricing, which the protocol allows.
    function _listInChunks(StockRegistry registry, address[] memory tokens, address[] memory feeds) private {
        uint256 chunk = vm.envOr("LIST_CHUNK", uint256(50));
        for (uint256 start; start < tokens.length; start += chunk) {
            uint256 size = tokens.length - start < chunk ? tokens.length - start : chunk;
            address[] memory t = new address[](size);
            address[] memory f = new address[](size);
            for (uint256 i; i < size; ++i) {
                t[i] = tokens[start + i];
                f[i] = feeds[start + i];
            }
            registry.listMany(t, f);
        }
    }

    function _report(Deployment memory d, address multisig, address treasury, uint256 listed) private pure {
        console2.log("TimelockController", d.timelock);
        console2.log("StockRegistry     ", d.registry);
        console2.log("BasketFactory     ", d.factory);
        console2.log("BasketZap         ", d.zap);
        console2.log("BasketLens        ", d.lens);
        console2.log("multisig          ", multisig);
        console2.log("treasury          ", treasury);
        console2.log("tokens listed     ", listed);
        console2.log("next: run TimelockAccept.s.sol with MODE=schedule, wait the delay, then MODE=execute");
    }

    function _config() private view returns (string memory) {
        string memory name = vm.envOr("CONFIG", string("robinhood-mainnet"));
        return vm.readFile(string.concat(vm.projectRoot(), "/config/", name, ".json"));
    }
}
