// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {TimelockScript} from "./TimelockScript.sol";

/// @notice Drives the timelock through accepting ownership of the registry, factory, zap and migrator.
/// @dev Ownable2Step needs the incoming owner to call `acceptOwnership` itself, and the incoming owner is
///      the timelock, so the call has to be scheduled and executed like any other governance action. This
///      is the first operation after deployment, and until it executes the deployer still owns everything.
///      Env for schedule: TIMELOCK, REGISTRY, FACTORY, ZAP, MIGRATOR; optional LABEL. Other modes: see
///      TimelockScript.
contract TimelockAccept is TimelockScript {
    function run() external returns (bytes32) {
        TimelockController tl = _envTimelock();
        if (!_mode("schedule")) return _stored(tl);

        Operation memory op = _operation(
            vm.envAddress("REGISTRY"), vm.envAddress("FACTORY"), vm.envAddress("ZAP"), vm.envAddress("MIGRATOR"), ""
        );
        return schedule(tl, _envOperation(op));
    }

    /// @notice Schedules acceptance for the four owned contracts under one operation.
    function scheduleAccept(
        TimelockController tl,
        address registry,
        address factory,
        address zap,
        address migrator,
        string memory label
    ) public returns (bytes32) {
        return schedule(tl, _operation(registry, factory, zap, migrator, label));
    }

    function _operation(address registry, address factory, address zap, address migrator, string memory label)
        private
        pure
        returns (Operation memory op)
    {
        address[4] memory owned = [registry, factory, zap, migrator];
        op.targets = new address[](4);
        op.values = new uint256[](4);
        op.payloads = new bytes[](4);
        for (uint256 i; i < 4; ++i) {
            op.targets[i] = owned[i];
            op.payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
        op.label = bytes(label).length != 0 ? label : "accept ownership of registry, factory, zap and migrator";
    }
}
