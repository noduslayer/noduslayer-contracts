// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The two calls the zap needs from wrapped ether: wrap what a caller sent, unwrap what comes back.
interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
