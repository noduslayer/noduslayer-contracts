// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBasketToken} from "./IBasketToken.sol";
import {IStockRegistry} from "./IStockRegistry.sol";

interface IBasketFactory {
    event BasketCreated(
        address indexed basket,
        string name,
        string symbol,
        IBasketToken.Constituent[] recipe,
        uint16 mintFeeBps,
        uint16 redeemFeeBps
    );
    event TreasuryUpdated(address indexed treasury);

    error TokenNotListed(address token);
    error ZeroAddress();

    function owner() external view returns (address);

    function registry() external view returns (IStockRegistry);

    function treasury() external view returns (address);

    function isBasket(address basket) external view returns (bool);

    function baskets() external view returns (address[] memory);

    function createBasket(
        string calldata name,
        string calldata symbol,
        IBasketToken.Constituent[] calldata recipe,
        uint16 mintFeeBps,
        uint16 redeemFeeBps
    ) external returns (address basket);

    function setTreasury(address treasury_) external;
}
