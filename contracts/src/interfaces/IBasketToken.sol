// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBasketToken {
    /// @param token Constituent ERC-20.
    /// @param units Constituent base units backing 1e18 shares.
    struct Constituent {
        address token;
        uint256 units;
    }

    event Minted(address indexed sender, address indexed to, uint256 shares, uint256 feeShares);
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256 feeShares, uint256 skipMask);
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed token, address indexed to, uint256 amount);
    event FeesUpdated(uint16 mintFeeBps, uint16 redeemFeeBps, address indexed feeRecipient);

    error InvalidRecipe();
    error FeeTooHigh();
    error ZeroAddress();
    error ZeroShares();
    error Unauthorized();
    error InvalidSkipMask();
    error NothingToClaim();

    function factory() external view returns (address);

    function mintFeeBps() external view returns (uint16);

    function redeemFeeBps() external view returns (uint16);

    function feeRecipient() external view returns (address);

    function constituents() external view returns (Constituent[] memory);

    function constituentCount() external view returns (uint256);

    function claimable(address account, address token) external view returns (uint256);

    function totalClaimable(address token) external view returns (uint256);

    function previewMint(uint256 shares) external view returns (uint256[] memory amountsIn, uint256 netShares);

    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut, uint256 netShares);

    function mint(uint256 shares, address to) external returns (uint256 netShares);

    function redeem(uint256 shares, address to) external returns (uint256[] memory amountsOut);

    function redeemWithSkip(uint256 shares, address to, uint256 skipMask) external returns (uint256[] memory amountsOut);

    function claim(address token, address to) external returns (uint256 amount);

    function setFees(uint16 mintFeeBps_, uint16 redeemFeeBps_, address feeRecipient_) external;
}
