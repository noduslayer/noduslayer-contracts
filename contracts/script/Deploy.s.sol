// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketLens} from "../src/BasketLens.sol";
import {BasketZap} from "../src/BasketZap.sol";
import {StockRegistry} from "../src/StockRegistry.sol";

/// @notice Deploys the protocol from config/<CONFIG>.json and stages ownership transfer to OWNER.
/// @dev Env: OWNER (multisig or timelock), TREASURY; optional CONFIG (robinhood-mainnet), ZAP_FEE_BPS (20).
///      Ownership is two-step: OWNER must call acceptOwnership() on the registry, factory and zap.
contract Deploy is Script {
    function run() external {
        string memory json = _config();
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "config/chain mismatch");

        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        uint16 zapFeeBps = uint16(vm.envOr("ZAP_FEE_BPS", uint256(20)));
        address[] memory tokens = vm.parseJsonAddressArray(json, ".stockTokens");
        address[] memory feeds = vm.parseJsonAddressArray(json, ".stockFeeds");
        address[] memory routers = vm.parseJsonAddressArray(json, ".routers");
        require(tokens.length == feeds.length, "config/token-feed length");

        vm.startBroadcast();
        address deployer = msg.sender;

        StockRegistry registry = new StockRegistry(deployer);
        _listInChunks(registry, tokens, feeds);

        BasketFactory factory = new BasketFactory(deployer, registry, treasury);
        BasketZap zap = new BasketZap(deployer, factory, treasury, zapFeeBps);
        for (uint256 i; i < routers.length; ++i) {
            zap.setRouter(routers[i], true);
        }
        BasketLens lens = new BasketLens(registry);

        registry.transferOwnership(owner);
        factory.transferOwnership(owner);
        zap.transferOwnership(owner);
        vm.stopBroadcast();

        console2.log("StockRegistry ", address(registry));
        console2.log("BasketFactory ", address(factory));
        console2.log("BasketZap     ", address(zap));
        console2.log("BasketLens    ", address(lens));
        console2.log("Pending owner ", owner);
    }

    /// @dev Lists the universe in bounded chunks so one oversized calldata blob cannot brick the deploy.
    ///      A feed of `address(0)` lists the token without on-chain pricing, which the protocol allows.
    function _listInChunks(StockRegistry registry, address[] memory tokens, address[] memory feeds) internal {
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

    function _config() internal view returns (string memory) {
        string memory name = vm.envOr("CONFIG", string("robinhood-mainnet"));
        return vm.readFile(string.concat(vm.projectRoot(), "/config/", name, ".json"));
    }
}
