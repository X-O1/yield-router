// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IYieldRouter} from "./interfaces/IYieldRouter.sol";
import "./YieldRouterErrors.sol";

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
    // flag to ensure only one permitted address is routing yield at a time
    RouterStatus private s_routerStatus;

    // tracks all balances for owner
    struct OwnerBalances {
        uint256 indexAdjustedBalance; // ray (1e27)
        uint256 indexAdjustedYield; // ray (1e27)
        uint256 principalValue; // ray (1e27)
    }

    // tracks status and withdrawn balances of addresses permitted yield access
    struct PermittedAddressData {
        bool isPermitted;
        uint256 amountPermitted;
        uint256 amountWithdrawn;
    }

    struct RouterStatus {
        bool isActive;
        bool isLocked;
    }

    // maps owner to their balances
    mapping(address owner => OwnerBalances) public s_accountBalances;
    // maps each permitted address to their yield withdrawal limit and tracks how much yield they’ve withdrawn.
    mapping(address permittedAddress => PermittedAddressData) public s_permittedAddressData;
    // maps locked principal amounts to current status
    mapping(uint256 amount => bool isLocked) public s_lockedAmounts;

    // restricts access to router owner
    modifier onlyOwner() {
        if (msg.sender != s_owner) revert NOT_OWNER();
        _;
    }
    // restricts access to owner or permitted address
    modifier onlyOwnerAndPermitted() {
        if (!s_permittedAddressData[msg.sender].isPermitted && msg.sender != s_owner) revert NOT_PERMITTED();
        _;
    }
    // denies access if router is active
    modifier ifRouterNotActive() {
        if (s_routerStatus.isActive) revert ROUTER_ACTIVE();
        _;
    }
    // denies access if router is locked
    modifier ifRouterNotLocked() {
        if (s_routerStatus.isLocked) revert ROUTER_LOCKED();
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

    // deactivates router
    // principal balance can NOT be withdrawn if yield router is active
    function deactivateRouter() public onlyOwner ifRouterNotLocked {
        if (!s_routerStatus.isActive) revert ROUTER_NOT_ACTIVE();
        s_routerStatus.isActive = false;

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked);
    }

    // // locks router in active status until a chosen amount of acrrued yield has been reached
    function lockRouter() private onlyOwner {
        if (s_routerStatus.isLocked) revert ROUTER_LOCKED();
        s_routerStatus.isLocked = true;

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked);
    }

    /// @inheritdoc IYieldRouter
    function manageRouterAccess(address _account, bool _isPermitted, uint256 _amountPermitted) external onlyOwner {
        _isPermitted ? s_permittedAddressData[_account].isPermitted = true : s_permittedAddressData[_account].isPermitted = false;
        s_permittedAddressData[_account].amountPermitted = _amountPermitted;
    }

    /// @inheritdoc IYieldRouter
    function routeYield(
        address _destination,
        uint256 _amountOfYieldInPrincipalValue,
        bool _lockRouter // === LOCKS OWNER'S FUNDS UNTIL PERMITTED ADDRESS WITHDRAWS MAX PERMMITED AMOUNT OF YIELD  === (Must be called by OWNER — input is ignored otherwise)
    ) external onlyOwnerAndPermitted ifRouterNotActive returns (uint256) {
        s_routerStatus.isActive = true;

        if (msg.sender == s_owner) {
            if (_lockRouter) lockRouter();
        }
        if (!s_permittedAddressData[_destination].isPermitted) revert DESTINATION_ADDRESS_NOT_PERMMITTED();
        if (msg.sender != s_owner) {
            if (_amountOfYieldInPrincipalValue > _getYieldAmountAvailableForPermittedAddress(msg.sender)) revert NOT_PERMITTED_AMOUNT();
        }

        uint256 currentYield = _updateYield();
        uint256 rayAmountOfYield = _wadToRay(_amountOfYieldInPrincipalValue);
        uint256 indexAdjustedPrincipalAmount = rayAmountOfYield.rayDiv(_getCurrentLiquidityIndex());

        if (indexAdjustedPrincipalAmount > currentYield) revert INSUFFICIENT_BALANCE();

        s_accountBalances[s_owner].indexAdjustedYield -= indexAdjustedPrincipalAmount;
        s_accountBalances[s_owner].indexAdjustedBalance -= indexAdjustedPrincipalAmount;
        s_permittedAddressData[msg.sender].amountWithdrawn += indexAdjustedPrincipalAmount;

        _getYieldAmountAvailableForPermittedAddress(msg.sender) == 0 ? s_routerStatus.isActive = false : s_routerStatus.isActive = true;

        if (_lockRouter) {
            _getYieldAmountAvailableForPermittedAddress(msg.sender) == 0 ? s_routerStatus.isLocked = false : s_routerStatus.isLocked = true;
        }

        if (!IERC20(i_yieldBarringToken).transfer(_destination, _rayToWad(indexAdjustedPrincipalAmount))) revert WITHDRAW_FAILED();

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked);
        emit Yield_Routed(_destination, i_yieldBarringToken, _rayToWad(indexAdjustedPrincipalAmount), s_routerStatus.isActive);

        return _rayToWad(indexAdjustedPrincipalAmount);
    }

    /// @inheritdoc IYieldRouter
    function deposit(address _yieldBarringToken, uint256 _amountInPrincipalValue) external onlyOwner returns (uint256) {
        if (_yieldBarringToken != i_yieldBarringToken) revert TOKEN_NOT_PERMITTED();
        uint256 indexAdjustedPrincipalAmount = _wadToRay(_amountInPrincipalValue).rayDiv(_getCurrentLiquidityIndex());

        if (indexAdjustedPrincipalAmount > IERC20(_yieldBarringToken).allowance(msg.sender, address(this))) revert TOKEN_ALLOWANCE();
        if (!IERC20(_yieldBarringToken).transferFrom(msg.sender, address(this), _rayToWad(indexAdjustedPrincipalAmount))) revert DEPOSIT_FAILED();

        s_accountBalances[msg.sender].indexAdjustedBalance += indexAdjustedPrincipalAmount;
        s_accountBalances[msg.sender].principalValue += _wadToRay(_amountInPrincipalValue);

        emit Deposit(msg.sender, _yieldBarringToken, _rayToWad(indexAdjustedPrincipalAmount));
        return _rayToWad(indexAdjustedPrincipalAmount);
    }

    /// @inheritdoc IYieldRouter
    function withdraw(uint256 _amountInPrincipalValue) external onlyOwner ifRouterNotActive ifRouterNotLocked returns (uint256) {
        uint256 currentIndexAdjustedBalance = s_accountBalances[s_owner].indexAdjustedBalance;
        uint256 indexAdjustedPrincipalAmount = _wadToRay(_amountInPrincipalValue).rayDiv(_getCurrentLiquidityIndex());

        if (indexAdjustedPrincipalAmount > currentIndexAdjustedBalance) revert INSUFFICIENT_BALANCE();

        s_accountBalances[msg.sender].indexAdjustedBalance -= indexAdjustedPrincipalAmount;
        s_accountBalances[msg.sender].principalValue -= _wadToRay(_amountInPrincipalValue);

        if (!IERC20(i_yieldBarringToken).transfer(msg.sender, _rayToWad(indexAdjustedPrincipalAmount))) revert WITHDRAW_FAILED();

        emit Withdraw(msg.sender, i_yieldBarringToken, _rayToWad(indexAdjustedPrincipalAmount));
        return _rayToWad(indexAdjustedPrincipalAmount);
    }

    // calculates how much yield has accured since deposit
    function _updateYield() private returns (uint256) {
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 currentIndexAdjustedBalance = s_accountBalances[s_owner].indexAdjustedBalance;
        uint256 newPricipalBalance = currentIndexAdjustedBalance.rayMul(currentIndex);

        uint256 currentPricipalBalance = s_accountBalances[s_owner].principalValue;

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

    // converts WAD units (1e18) into RAY units (1e27)
    function _wadToRay(uint256 _num) private pure returns (uint256) {
        return _num * 1e9;
    }

    // converts RAY units (1e27) into WAD units (1e18)
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
        return s_accountBalances[s_owner].principalValue;
    }

    // update and return owner's index-adjusted yield (ray)
    function getAccountIndexAdjustedYield() external returns (uint256) {
        return _updateYield();
    }

    // check if an address is permitted to route yield
    function isAddressPermittedForYieldAccess(address _address) external view returns (bool) {
        return s_permittedAddressData[_address].isPermitted;
    }

    // check permitted address withdraw limit status
    function _getYieldAmountAvailableForPermittedAddress(address _permittedAddress) internal view returns (uint256) {
        uint256 maxAmount = s_permittedAddressData[_permittedAddress].amountPermitted;
        uint256 withdrawnAmount = s_permittedAddressData[_permittedAddress].amountWithdrawn;
        uint256 availableAmount;

        if (withdrawnAmount > 0 && withdrawnAmount < maxAmount) {
            availableAmount = maxAmount - withdrawnAmount;
            return availableAmount;
        } else {
            return maxAmount;
        }
    }
}
