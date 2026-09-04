// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Drives one TimelockController operation through its life: schedule, wait, execute or cancel.
///
/// @dev Every governance action after deployment goes through the timelock, and the timelock's proposer is
///      a multisig, which cannot run a Foundry script. So every step does two things: it simulates the call,
///      and it prints the exact transaction the multisig has to submit — to, value, data. Scheduling also
///      writes that transaction into governance/ops/<id>.json next to everything needed to execute or
///      cancel the same operation later.
///
///      Run with `--broadcast` when the proposer is a key Foundry holds: a rehearsal, or a 1-of-1. Otherwise
///      run with `--sender <multisig>` so the simulation passes the role check, and submit the printed
///      transaction from the multisig.
///
///      The operation id commits to the payloads, so what executes is exactly what was scheduled. Execute
///      and cancel read the file rather than rebuilding the payload, which is what keeps that true when the
///      payload was derived from live data, as a basket recipe is.
///
///      `run` on each script is an adapter over the environment: TIMELOCK, MODE (schedule | execute |
///      cancel | status). schedule takes LABEL, which names the operation and seeds its salt, so it has to
///      be new each time; optionally SALT, PREDECESSOR, DELAY (default: the timelock's minimum). The other
///      modes take OP, the operation id. OPS_DIR moves the file directory. The typed functions below do the
///      work and are what the tests, and `forge script --sig`, call directly.
abstract contract TimelockScript is Script {
    struct Operation {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 predecessor;
        bytes32 salt;
        uint256 delay;
        string label;
    }

    /// @notice Where operation files go, relative to the project root.
    string public opsDir = "governance/ops";

    function setOpsDir(string memory dir) public {
        opsDir = dir;
    }

    // ---------------------------------------------------------------- the operation, typed

    /// @notice Schedules `op` and writes its file. An empty salt derives from the label; an empty delay is
    ///         the timelock's minimum. Returns the operation id.
    function schedule(TimelockController tl, Operation memory op) public returns (bytes32 id) {
        require(bytes(op.label).length != 0, "LABEL required: it names the operation and seeds its salt");
        if (op.salt == bytes32(0)) op.salt = keccak256(bytes(op.label));
        if (op.delay == 0) op.delay = tl.getMinDelay();
        require(
            op.targets.length != 0 && op.targets.length == op.payloads.length && op.targets.length == op.values.length,
            "targets, values and payloads must align"
        );

        id = tl.hashOperationBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
        require(!tl.isOperation(id), "operation already scheduled: choose a new LABEL");

        console2.log("schedule:", op.label);
        console2.logBytes32(id);
        _print(address(tl), _scheduleData(op));

        vm.broadcast();
        tl.scheduleBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt, op.delay);

        _write(tl, id, op);
        console2.log("executable at", block.timestamp + op.delay);
    }

    /// @notice Executes the operation the file describes, once the delay has run.
    function execute(TimelockController tl, bytes32 id) public {
        Operation memory op = _load(tl, id);
        require(tl.isOperationReady(id), "operation not ready: MODE=status shows when");
        _print(
            address(tl),
            abi.encodeCall(
                TimelockController.executeBatch, (op.targets, op.values, op.payloads, op.predecessor, op.salt)
            )
        );
        vm.broadcast();
        tl.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
        console2.log("executed:", op.label);
    }

    /// @notice Cancels a pending operation.
    function cancel(TimelockController tl, bytes32 id) public {
        Operation memory op = _load(tl, id);
        require(tl.isOperationPending(id), "operation is not pending");
        _print(address(tl), abi.encodeCall(TimelockController.cancel, (id)));
        vm.broadcast();
        tl.cancel(id);
        console2.log("cancelled:", op.label);
    }

    /// @notice Reports what the chain says about an operation.
    function status(TimelockController tl, bytes32 id) public view {
        Operation memory op = _load(tl, id);
        console2.log("operation:", op.label);
        console2.logBytes32(id);
        if (!tl.isOperation(id)) {
            console2.log("state: unknown to the timelock (never scheduled, or cancelled)");
        } else if (tl.isOperationDone(id)) {
            console2.log("state: done");
        } else if (tl.isOperationReady(id)) {
            console2.log("state: ready to execute");
        } else {
            console2.log("state: pending until", tl.getTimestamp(id));
        }
    }

    // ---------------------------------------------------------------- the environment adapter

    function _mode(string memory want) internal view returns (bool) {
        return keccak256(bytes(vm.envString("MODE"))) == keccak256(bytes(want));
    }

    /// @dev Reads what every mode needs, and returns the timelock.
    function _envTimelock() internal returns (TimelockController) {
        opsDir = vm.envOr("OPS_DIR", opsDir);
        return TimelockController(payable(vm.envAddress("TIMELOCK")));
    }

    /// @dev Fills the scheduling parameters the environment may override.
    function _envOperation(Operation memory op) internal view returns (Operation memory) {
        if (bytes(op.label).length == 0) op.label = vm.envOr("LABEL", string(""));
        op.salt = bytes32(vm.envOr("SALT", uint256(0)));
        op.predecessor = vm.envOr("PREDECESSOR", bytes32(0));
        op.delay = vm.envOr("DELAY", uint256(0));
        return op;
    }

    /// @dev Dispatches the modes that act on a stored operation.
    function _stored(TimelockController tl) internal returns (bytes32 id) {
        id = vm.envBytes32("OP");
        if (_mode("execute")) {
            execute(tl, id);
        } else if (_mode("cancel")) {
            cancel(tl, id);
        } else if (_mode("status")) {
            status(tl, id);
        } else {
            revert("MODE must be schedule, execute, cancel or status");
        }
    }

    // ---------------------------------------------------------------- the operation file

    function opPath(bytes32 id) public view returns (string memory) {
        return string.concat(vm.projectRoot(), "/", opsDir, "/", vm.toString(id), ".json");
    }

    function _write(TimelockController tl, bytes32 id, Operation memory op) private {
        vm.createDir(string.concat(vm.projectRoot(), "/", opsDir), true);

        string memory json = "op";
        vm.serializeBytes32(json, "id", id);
        vm.serializeString(json, "label", op.label);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "timelock", address(tl));
        vm.serializeAddress(json, "targets", op.targets);
        vm.serializeUint(json, "values", op.values);
        vm.serializeBytes(json, "payloads", op.payloads);
        vm.serializeBytes32(json, "predecessor", op.predecessor);
        vm.serializeBytes32(json, "salt", op.salt);
        vm.serializeUint(json, "delay", op.delay);
        vm.serializeUint(json, "createdAt", block.timestamp);
        vm.serializeString(json, "scheduleTx", _txJson("scheduleTx", address(tl), _scheduleData(op)));
        vm.serializeString(
            json,
            "executeTx",
            _txJson(
                "executeTx",
                address(tl),
                abi.encodeCall(
                    TimelockController.executeBatch, (op.targets, op.values, op.payloads, op.predecessor, op.salt)
                )
            )
        );
        string memory out = vm.serializeString(
            json, "cancelTx", _txJson("cancelTx", address(tl), abi.encodeCall(TimelockController.cancel, (id)))
        );

        string memory path = opPath(id);
        vm.writeJson(out, path);
        console2.log("wrote", path);
    }

    function _txJson(string memory key, address to, bytes memory data) private returns (string memory) {
        vm.serializeAddress(key, "to", to);
        vm.serializeUint(key, "value", 0);
        return vm.serializeBytes(key, "data", data);
    }

    /// @dev Reads an operation back and refuses one that does not hash to the id it is filed under: the file
    ///      is the record of what was reviewed, and an edited payload must not execute under the old name.
    function _load(TimelockController tl, bytes32 id) private view returns (Operation memory op) {
        string memory path = opPath(id);
        require(vm.exists(path), "no operation file for OP");
        string memory json = vm.readFile(path);

        op.targets = vm.parseJsonAddressArray(json, ".targets");
        op.values = vm.parseJsonUintArray(json, ".values");
        op.payloads = vm.parseJsonBytesArray(json, ".payloads");
        op.predecessor = vm.parseJsonBytes32(json, ".predecessor");
        op.salt = vm.parseJsonBytes32(json, ".salt");
        op.delay = vm.parseJsonUint(json, ".delay");
        op.label = vm.parseJsonString(json, ".label");

        require(vm.parseJsonAddress(json, ".timelock") == address(tl), "operation file names a different timelock");
        require(
            tl.hashOperationBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt) == id,
            "operation file does not hash to OP: refusing an edited file"
        );
    }

    function _scheduleData(Operation memory op) private pure returns (bytes memory) {
        return abi.encodeCall(
            TimelockController.scheduleBatch, (op.targets, op.values, op.payloads, op.predecessor, op.salt, op.delay)
        );
    }

    function _print(address to, bytes memory data) private pure {
        console2.log("transaction for the multisig:");
        console2.log("  to:    ", to);
        console2.log("  value:  0");
        console2.log("  data:");
        console2.logBytes(data);
    }
}
