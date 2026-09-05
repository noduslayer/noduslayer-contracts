// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// Mirrors the issuer-controlled pause switch present on Robinhood stock tokens, and their permit support.
contract MockStockToken is ERC20Permit {
    error EnforcedPause();

    bool public paused;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC20Permit(name_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert EnforcedPause();
        super._update(from, to, value);
    }
}
