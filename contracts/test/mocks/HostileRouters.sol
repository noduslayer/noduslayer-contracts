// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// Routers that misbehave in the ways an allow-listed router could if it were compromised. Each is honest
/// about one thing — it is a router the zap will call — and dishonest about the rest.

/// Calls back into the contract that called it, with calldata of the attacker's choosing, before doing any
/// swapping. If the guards hold, the callback reverts and so does the whole transaction.
contract ReentrantRouter {
    using Address for address;

    bytes public payload;

    function arm(bytes calldata data) external {
        payload = data;
    }

    function swap() external {
        msg.sender.functionCall(payload);
    }
}

/// Pulls everything it is allowed to pull of the sell token and delivers nothing.
contract GreedyRouter {
    using SafeERC20 for IERC20;

    function swap(address sellToken) external {
        uint256 allowed = IERC20(sellToken).allowance(msg.sender, address(this));
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), allowed);
    }
}

/// Tries to pull a token other than the one the leg sells — a balance the caller happens to hold.
contract ThiefRouter {
    using SafeERC20 for IERC20;

    function swap(address victimToken, uint256 amount) external {
        IERC20(victimToken).safeTransferFrom(msg.sender, address(this), amount);
    }
}

/// Delivers the constituent it was asked for, but keeps a slice: less than the leg promised.
contract ShortRouter {
    using SafeERC20 for IERC20;

    function swap(address quote, address token, uint256 amountIn, uint256 deliver) external {
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).safeTransfer(msg.sender, deliver);
    }
}
