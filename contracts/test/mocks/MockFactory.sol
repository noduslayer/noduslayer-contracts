// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BasketToken} from "../../src/BasketToken.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";

contract MockFactory {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function deploy(
        string memory name,
        string memory symbol,
        IBasketToken.Constituent[] memory recipe,
        uint16 mintFeeBps,
        uint16 redeemFeeBps,
        address feeRecipient
    ) external returns (BasketToken) {
        return new BasketToken(name, symbol, recipe, mintFeeBps, redeemFeeBps, feeRecipient);
    }
}
