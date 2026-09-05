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
    event BasketRetired(address indexed basket, address indexed successor);
    event TreasuryUpdated(address indexed treasury);

    error TokenNotListed(address token);
    error UnknownBasket(address basket);
    error InvalidSuccessor(address successor);
    error ZeroAddress();

    function owner() external view returns (address);

    function registry() external view returns (IStockRegistry);

    function treasury() external view returns (address);

    function isBasket(address basket) external view returns (bool);

    /// @notice A retired basket takes no new shares; redemption stays open forever.
    function isRetired(address basket) external view returns (bool);

    /// @notice The basket the protocol moved on to, if governance named one when retiring.
    function successorOf(address basket) external view returns (address);

    function baskets() external view returns (address[] memory);

    function createBasket(
        string calldata name,
        string calldata symbol,
        IBasketToken.Constituent[] calldata recipe,
        uint16 mintFeeBps,
        uint16 redeemFeeBps
    ) external returns (address basket);

    function retire(address basket, address successor) external;

    function setTreasury(address treasury_) external;
}
