// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {TimelockScript} from "./TimelockScript.sol";

/// @notice Any call, or batch of calls, through the timelock.
///
/// @dev Build the calldata with cast and hand it over; several targets and calldatas, comma-separated in
///      the same order, become one batch that executes atomically or not at all.
///
///      TARGETS=$ZAP CALLDATAS=$(cast calldata "setFee(uint16)" 30) LABEL="zap fee to 30 bps, 2026-09-05" \
///        MODE=schedule forge script script/Govern.s.sol --rpc-url robinhood --sender $MULTISIG
///
///      Env for schedule: TARGETS, CALLDATAS, LABEL; optional VALUES (default: all zero). Every other mode
///      takes OP. See TimelockScript for the rest.
contract Govern is TimelockScript {
    function run() external returns (bytes32) {
        TimelockController tl = _envTimelock();
        if (!_mode("schedule")) return _stored(tl);

        Operation memory op;
        op.targets = vm.envAddress("TARGETS", ",");
        op.payloads = vm.envBytes("CALLDATAS", ",");
        op.values = vm.envOr("VALUES", ",", new uint256[](0));
        if (op.values.length == 0) op.values = new uint256[](op.targets.length);
        return schedule(tl, _envOperation(op));
    }
}
