// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBasketFactory} from "./interfaces/IBasketFactory.sol";
import {IBasketToken} from "./interfaces/IBasketToken.sol";

/// @title BasketToken
/// @notice Fully collateralised basket of stock tokens with a fixed recipe. Shares are minted and redeemed
///         in kind against exact constituent amounts; the vault never trades and has no owner.
/// @dev Mint rounds constituent amounts up and redeem rounds them down, so for every constituent
///      `balance * 1e18 >= totalSupply * units + totalClaimable * 1e18` holds at all times.
///      Fees are settled in shares and therefore stay backed; they go to the factory's treasury, read live,
///      so moving the treasury is one governance action rather than one per basket. Redeem can never be
///      paused and survives the basket's retirement; if the issuer freezes a constituent, holders exit the
///      rest via `redeemWithSkip` and collect the frozen leg later.
contract BasketToken is IBasketToken, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE_BPS = 100;
    uint256 public constant MIN_CONSTITUENTS = 2;
    uint256 public constant MAX_CONSTITUENTS = 16;

    uint256 private constant BPS = 10_000;
    uint256 private constant ONE = 1e18;

    address public immutable factory;

    uint16 public mintFeeBps;
    uint16 public redeemFeeBps;

    Constituent[] private _constituents;

    mapping(address token => uint256 amount) public totalClaimable;
    mapping(address account => mapping(address token => uint256 amount)) public claimable;

    modifier onlyProtocol() {
        _checkProtocol();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        Constituent[] memory recipe,
        uint16 mintFeeBps_,
        uint16 redeemFeeBps_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        uint256 n = recipe.length;
        if (n < MIN_CONSTITUENTS || n > MAX_CONSTITUENTS) revert InvalidRecipe();
        for (uint256 i; i < n; ++i) {
            if (recipe[i].token == address(0) || recipe[i].units == 0) revert InvalidRecipe();
            for (uint256 j; j < i; ++j) {
                if (recipe[j].token == recipe[i].token) revert InvalidRecipe();
            }
            _constituents.push(recipe[i]);
        }
        factory = msg.sender;
        _setFees(mintFeeBps_, redeemFeeBps_);
    }

    // ------------------------------------------------------------------ mint / redeem

    function mint(uint256 shares, address to) external nonReentrant returns (uint256 netShares) {
        if (shares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        if (IBasketFactory(factory).isRetired(address(this))) revert Retired();

        uint256 n = _constituents.length;
        for (uint256 i; i < n; ++i) {
            Constituent memory c = _constituents[i];
            IERC20(c.token).safeTransferFrom(msg.sender, address(this), shares.mulDiv(c.units, ONE, Math.Rounding.Ceil));
        }

        uint256 feeShares = shares * mintFeeBps / BPS;
        netShares = shares - feeShares;
        _mint(to, netShares);
        if (feeShares != 0) _mint(feeRecipient(), feeShares);

        emit Minted(msg.sender, to, shares, feeShares);
    }

    function redeem(uint256 shares, address to) external nonReentrant returns (uint256[] memory amountsOut) {
        return _redeem(shares, to, to, 0);
    }

    function redeemWithSkip(uint256 shares, address to, uint256 skipMask)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        if (skipMask >> _constituents.length != 0) revert InvalidSkipMask();
        return _redeem(shares, to, to, skipMask);
    }

    function redeemWithSkipFor(uint256 shares, address to, address claimant, uint256 skipMask)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        if (skipMask >> _constituents.length != 0) revert InvalidSkipMask();
        return _redeem(shares, to, claimant, skipMask);
    }

    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        delete claimable[msg.sender][token];
        totalClaimable[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit Claimed(msg.sender, token, to, amount);
    }

    // ------------------------------------------------------------------ fees

    function setFees(uint16 mintFeeBps_, uint16 redeemFeeBps_) external onlyProtocol {
        _setFees(mintFeeBps_, redeemFeeBps_);
    }

    // ------------------------------------------------------------------ views

    function feeRecipient() public view returns (address) {
        return IBasketFactory(factory).treasury();
    }

    function constituents() external view returns (Constituent[] memory) {
        return _constituents;
    }

    function constituentCount() external view returns (uint256) {
        return _constituents.length;
    }

    function previewMint(uint256 shares) external view returns (uint256[] memory amountsIn, uint256 netShares) {
        amountsIn = _amounts(shares, Math.Rounding.Ceil);
        netShares = shares - shares * mintFeeBps / BPS;
    }

    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut, uint256 netShares) {
        netShares = shares - shares * redeemFeeBps / BPS;
        amountsOut = _amounts(netShares, Math.Rounding.Floor);
    }

    // ------------------------------------------------------------------ internals

    function _redeem(uint256 shares, address to, address claimant, uint256 skipMask)
        private
        returns (uint256[] memory amountsOut)
    {
        if (shares == 0) revert ZeroShares();
        if (to == address(0) || claimant == address(0)) revert ZeroAddress();

        uint256 feeShares = shares * redeemFeeBps / BPS;
        uint256 netShares = shares - feeShares;
        if (feeShares != 0) _transfer(msg.sender, feeRecipient(), feeShares);
        _burn(msg.sender, netShares);

        uint256 n = _constituents.length;
        amountsOut = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 amount = netShares.mulDiv(_constituents[i].units, ONE);
            amountsOut[i] = amount;
            if (amount != 0 && _skipped(skipMask, i)) {
                address token = _constituents[i].token;
                claimable[claimant][token] += amount;
                totalClaimable[token] += amount;
                emit ClaimRecorded(claimant, token, amount);
            }
        }
        emit Redeemed(msg.sender, to, shares, feeShares, skipMask);

        for (uint256 i; i < n; ++i) {
            if (amountsOut[i] != 0 && !_skipped(skipMask, i)) {
                IERC20(_constituents[i].token).safeTransfer(to, amountsOut[i]);
            }
        }
    }

    function _amounts(uint256 shares, Math.Rounding rounding) private view returns (uint256[] memory amounts) {
        uint256 n = _constituents.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amounts[i] = shares.mulDiv(_constituents[i].units, ONE, rounding);
        }
    }

    function _skipped(uint256 skipMask, uint256 index) private pure returns (bool) {
        return (skipMask >> index) & 1 == 1;
    }

    function _checkProtocol() private view {
        if (msg.sender != IBasketFactory(factory).owner()) revert Unauthorized();
    }

    function _setFees(uint16 mintFeeBps_, uint16 redeemFeeBps_) private {
        if (mintFeeBps_ > MAX_FEE_BPS || redeemFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        emit FeesUpdated(mintFeeBps_, redeemFeeBps_);
    }
}
