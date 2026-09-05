// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BasketToken} from "../../src/BasketToken.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";

/// The parts of BasketFactory a BasketToken reads back: who governs it, where fees go, whether it is retired.
contract MockFactory {
    address public owner;
    address public treasury;
    mapping(address basket => bool) public isRetired;

    constructor(address owner_, address treasury_) {
        owner = owner_;
        treasury = treasury_;
    }

    function deploy(
        string memory name,
        string memory symbol,
        IBasketToken.Constituent[] memory recipe,
        uint16 mintFeeBps,
        uint16 redeemFeeBps
    ) external returns (BasketToken) {
        return new BasketToken(name, symbol, recipe, mintFeeBps, redeemFeeBps);
    }

    function setTreasury(address treasury_) external {
        treasury = treasury_;
    }

    function setRetired(address basket, bool retired) external {
        isRetired[basket] = retired;
    }
}
