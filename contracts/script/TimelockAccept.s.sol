// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Drives the timelock through accepting ownership of the registry, factory and zap.
/// @dev Ownable2Step needs the incoming owner to call `acceptOwnership` itself, and the incoming owner is
///      the timelock, so the call has to be scheduled and executed like any other governance action.
///      Env: TIMELOCK, REGISTRY, FACTORY, ZAP; MODE (schedule | execute); optional SALT (0).
///      Broadcast by an account holding PROPOSER_ROLE for schedule and EXECUTOR_ROLE for execute.
contract TimelockAccept is Script {
    function run() external {
        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        string memory mode = vm.envString("MODE");

        address[] memory targets = new address[](3);
        targets[0] = vm.envAddress("REGISTRY");
        targets[1] = vm.envAddress("FACTORY");
        targets[2] = vm.envAddress("ZAP");

        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }

        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        if (_is(mode, "schedule")) {
            uint256 delay = timelock.getMinDelay();
            vm.broadcast();
            timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
            console2.log("scheduled batch");
            console2.logBytes32(id);
            console2.log("executable after (seconds from now)", delay);
        } else if (_is(mode, "execute")) {
            require(timelock.isOperationReady(id), "operation not ready");
            vm.broadcast();
            timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
            console2.log("executed batch; timelock now owns registry, factory and zap");
        } else {
            revert("MODE must be schedule or execute");
        }
    }

    function _is(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
