// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./YieldRouterErrors.sol";
import {IYieldRouter} from "./interfaces/IYieldRouter.sol";

/**
 * @title YieldRouter
 * @notice Routes yield from a user's deposited yield-bearing tokens to permitted addresses.
 * @dev Only handles deposits and withdrawals in the yield-bearing token (e.g., aUSDC).
 * @dev All external inputs/outputs are in WAD (1e18); internal accounting uses RAY (1e27).
 */
contract YieldRouter is IYieldRouter {
    // math helpers for wad and ray units
    using WadRayMath for uint256;
    // aave v3 pool interface

    IPool private i_aaveV3Pool;
    // aave address provider
    IPoolAddressesProvider private i_addressesProvider;
    // yield-bearing token address (e.g., aUSDC)
    address public i_yieldBarringToken;
    // principal token address (e.g., USDC)
    address public i_principalToken;
    // router owner
    address private s_owner;
    // flag to prevent re-initialization
    bool private s_initialized;
    // flag to ensure owner can only be set once
    bool private s_ownerSet;

    // tracks all balances for owner
    struct AccountBalances {
        uint256 indexAdjustedBalance; // ray (1e27)
        uint256 indexAdjustedYield; // ray (1e27)
        uint256 depositPrincipal; // ray (1e27)
    }

    // maps owner to their balances
    mapping(address account => AccountBalances) public s_accountBalances;
    // maps addresses permitted to route yield
    mapping(address account => bool isPermitted) public s_permittedYieldAccess;

    // restricts access to only owner
    modifier onlyOwner() {
        if (msg.sender != s_owner) revert NOT_OWNER();
        _;
    }
    // allows access if caller is owner or permitted

    modifier onlyOwnerAndPermitted() {
        if (!s_permittedYieldAccess[msg.sender] && msg.sender != s_owner) revert NOT_PERMITTED();
        _;
    }

    /// @inheritdoc IYieldRouter
    function initialize(address _addressProvider, address _yieldBarringToken, address _prinicalToken) external {
        if (s_initialized) revert ALREADY_INITIALIZED();
        s_initialized = true;

        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_aaveV3Pool = IPool(i_addressesProvider.getPool());
        i_yieldBarringToken = _yieldBarringToken;
        i_principalToken = _prinicalToken;
    }

    /// @inheritdoc IYieldRouter
    function setOwner(address _owner) external returns (address) {
        if (s_ownerSet) revert ALREADY_SET();
        s_ownerSet = true;
        s_owner = _owner;
        return s_owner;
    }

    /// @inheritdoc IYieldRouter
    function manageYieldAccess(address _account, bool _isPermitted) external onlyOwner {
        _isPermitted ? s_permittedYieldAccess[_account] = true : s_permittedYieldAccess[_account] = false;
    }

    /// @inheritdoc IYieldRouter
    function deposit(address _yieldBarringToken, uint256 _principalTokenAmount) external onlyOwner returns (uint256) {
        if (_yieldBarringToken != i_yieldBarringToken) revert TOKEN_NOT_PERMITTED();
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 indexAdjustedAmount = _wadToRay(_principalTokenAmount).rayDiv(currentIndex);

        if (indexAdjustedAmount > IERC20(_yieldBarringToken).allowance(msg.sender, address(this))) {
            revert TOKEN_ALLOWANCE();
        }
        if (!IERC20(_yieldBarringToken).transferFrom(msg.sender, address(this), _rayToWad(indexAdjustedAmount))) {
            revert DEPOSIT_FAILED();
        }

        s_accountBalances[msg.sender].indexAdjustedBalance += indexAdjustedAmount;
        s_accountBalances[msg.sender].depositPrincipal += _wadToRay(_principalTokenAmount);

        emit Deposit(msg.sender, _yieldBarringToken, _rayToWad(indexAdjustedAmount));
        return _rayToWad(indexAdjustedAmount);
    }

    /// @inheritdoc IYieldRouter
    function withdraw(uint256 _principalTokenAmount) external onlyOwner returns (uint256) {
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 currentIndexAdjustedBalance = s_accountBalances[s_owner].indexAdjustedBalance;
        uint256 indexAdjustedAmount = _wadToRay(_principalTokenAmount).rayDiv(currentIndex);

        if (indexAdjustedAmount > currentIndexAdjustedBalance) revert INSUFFICIENT_BALANCE();

        s_accountBalances[msg.sender].indexAdjustedBalance -= indexAdjustedAmount;
        s_accountBalances[msg.sender].depositPrincipal -= _wadToRay(_principalTokenAmount);

        if (!IERC20(i_yieldBarringToken).transfer(msg.sender, _rayToWad(indexAdjustedAmount))) revert WITHDRAW_FAILED();

        emit Withdraw(msg.sender, i_yieldBarringToken, _rayToWad(indexAdjustedAmount));
        return _rayToWad(indexAdjustedAmount);
    }

    /// @inheritdoc IYieldRouter
    function routeYield(address _destination, uint256 _principalTokenAmount)
        external
        onlyOwnerAndPermitted
        returns (uint256)
    {
        uint256 currentYield = updateYield();
        uint256 rayPrincipalTokenAmount = _wadToRay(_principalTokenAmount);
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 indexAdjustedPrincipalTokenAmount = rayPrincipalTokenAmount.rayDiv(currentIndex);

        if (indexAdjustedPrincipalTokenAmount > currentYield) revert INSUFFICIENT_BALANCE();

        s_accountBalances[s_owner].indexAdjustedYield -= indexAdjustedPrincipalTokenAmount;
        s_accountBalances[s_owner].indexAdjustedBalance -= indexAdjustedPrincipalTokenAmount;

        if (!IERC20(i_yieldBarringToken).transfer(_destination, _rayToWad(indexAdjustedPrincipalTokenAmount))) {
            revert WITHDRAW_FAILED();
        }

        emit Yield_Routed(_destination, i_yieldBarringToken, _rayToWad(indexAdjustedPrincipalTokenAmount));
        return _rayToWad(indexAdjustedPrincipalTokenAmount);
    }

    // calculates how much yield has accured since deposit
    function updateYield() public returns (uint256) {
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 currentIndexAdjustedBalance = s_accountBalances[s_owner].indexAdjustedBalance;
        uint256 newPricipalBalance = currentIndexAdjustedBalance.rayMul(currentIndex);

        uint256 currentPricipalBalance = s_accountBalances[s_owner].depositPrincipal;

        if (newPricipalBalance > currentPricipalBalance) {
            uint256 yield = newPricipalBalance - currentPricipalBalance;
            uint256 indexAdjustedYield = yield.rayDiv(currentIndex);

            s_accountBalances[s_owner].indexAdjustedYield = indexAdjustedYield;
        }

        return s_accountBalances[s_owner].indexAdjustedYield;
    }

    // fetches aave's v3 pool's current liquidity index
    function _getCurrentLiquidityIndex() private view returns (uint256) {
        uint256 currentIndex = uint256(i_aaveV3Pool.getReserveData(i_principalToken).liquidityIndex);
        if (currentIndex < 1e27) revert INVALID_INDEX();
        return currentIndex;
    }

    // WAD units (1e18) => RAY units (1e27)
    function _wadToRay(uint256 _num) private pure returns (uint256) {
        return _num * 1e9;
    }

    // RAY units (1e27) => WAD units (1e18)
    function _rayToWad(uint256 _num) private pure returns (uint256) {
        return _num / 1e9;
    }

    // return router owner
    function getRouterOwner() external view returns (address) {
        return s_owner;
    }

    // return owner's index-adjusted balance (ray)
    function getAccountIndexAdjustedBalance() external view returns (uint256) {
        return s_accountBalances[s_owner].indexAdjustedBalance;
    }

    // return owner's deposit principal (ray)
    function getAccountDepositPrincipal() external view returns (uint256) {
        return s_accountBalances[s_owner].depositPrincipal;
    }

    // update and return owner's index-adjusted yield (ray)
    function getAccountIndexAdjustedYield() external returns (uint256) {
        return updateYield();
    }

    // check if an address is permitted to route yield
    function isAddressPermittedForYieldAccess(address _address) external view returns (bool) {
        return s_permittedYieldAccess[_address];
    }
}
