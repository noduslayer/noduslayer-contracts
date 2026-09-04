// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {BasketToken} from "./BasketToken.sol";
import {IBasketFactory} from "./interfaces/IBasketFactory.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";
import {IStockRegistry} from "./interfaces/IStockRegistry.sol";

/// @title BasketFactory
/// @notice Deploys curated baskets whose constituents are all listed in the stock registry and records
///         them so peripheral contracts can distinguish official baskets from look-alikes.
/// @dev The factory owner doubles as protocol governor for fee changes on every basket it deployed.
contract BasketFactory is IBasketFactory, Ownable2Step {
    IStockRegistry public immutable registry;
    address public treasury;

    address[] private _baskets;
    mapping(address basket => bool) public isBasket;

    constructor(address initialOwner, IStockRegistry registry_, address treasury_) Ownable(initialOwner) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        _setTreasury(treasury_);
    }

    function createBasket(
        string calldata name,
        string calldata symbol,
        IBasketToken.Constituent[] calldata recipe,
        uint16 mintFeeBps,
        uint16 redeemFeeBps
    ) external onlyOwner returns (address basket) {
        for (uint256 i; i < recipe.length; ++i) {
            if (!registry.isListed(recipe[i].token)) revert TokenNotListed(recipe[i].token);
        }

        basket = address(new BasketToken(name, symbol, recipe, mintFeeBps, redeemFeeBps, treasury));
        isBasket[basket] = true;
        _baskets.push(basket);

        emit BasketCreated(basket, name, symbol, recipe, mintFeeBps, redeemFeeBps);
    }

    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    function baskets() external view returns (address[] memory) {
        return _baskets;
    }

    function owner() public view override(Ownable, IBasketFactory) returns (address) {
        return super.owner();
    }

    function _setTreasury(address treasury_) private {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }
}
