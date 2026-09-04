// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {TimelockScript} from "./TimelockScript.sol";

/// @notice Drives the timelock through accepting ownership of the registry, factory and zap.
/// @dev Ownable2Step needs the incoming owner to call `acceptOwnership` itself, and the incoming owner is
///      the timelock, so the call has to be scheduled and executed like any other governance action. This
///      is the first operation after deployment, and until it executes the deployer still owns everything.
///      Env for schedule: TIMELOCK, REGISTRY, FACTORY, ZAP; optional LABEL. Other modes: see TimelockScript.
contract TimelockAccept is TimelockScript {
    function run() external returns (bytes32) {
        TimelockController tl = _envTimelock();
        if (!_mode("schedule")) return _stored(tl);

        Operation memory op =
            _envOperation(_operation(vm.envAddress("REGISTRY"), vm.envAddress("FACTORY"), vm.envAddress("ZAP"), ""));
        return schedule(tl, op);
    }

    /// @notice Schedules acceptance for the three owned contracts under one operation.
    function scheduleAccept(TimelockController tl, address registry, address factory, address zap, string memory label)
        public
        returns (bytes32)
    {
        return schedule(tl, _operation(registry, factory, zap, label));
    }

    function _operation(address registry, address factory, address zap, string memory label)
        private
        pure
        returns (Operation memory op)
    {
        op.targets = new address[](3);
        op.targets[0] = registry;
        op.targets[1] = factory;
        op.targets[2] = zap;
        op.values = new uint256[](3);
        op.payloads = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            op.payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
        op.label = bytes(label).length != 0 ? label : "accept ownership of registry, factory and zap";
    }
}
