// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBasketFactory} from "./IBasketFactory.sol";
import {IRouteExecutor} from "./IRouteExecutor.sol";

/// @notice Moves a holder from one basket version to the next in a single transaction.
interface IBasketMigrator is IRouteExecutor {
    event Migrated(
        address indexed from,
        address indexed to,
        address indexed sender,
        address recipient,
        uint256 sharesIn,
        uint256 sharesOut
    );

    error UnknownBasket(address basket);
    error SameBasket(address basket);
    error InsufficientShares(uint256 got, uint256 want);

    function factory() external view returns (IBasketFactory);

    function migrate(
        address from,
        address to,
        uint256 shares,
        uint256 mintShares,
        uint256 minShares,
        Swap[] calldata swaps,
        address recipient,
        uint256 deadline
    ) external returns (uint256 netShares);

    function migrateWithPermit(
        address from,
        address to,
        uint256 shares,
        uint256 mintShares,
        uint256 minShares,
        Swap[] calldata swaps,
        address recipient,
        uint256 deadline,
        Permit calldata permit
    ) external returns (uint256 netShares);

    function pause() external;

    function unpause() external;
}
