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
 * @notice Routes all yield from user's deposited yield-barring tokens to any permitted address.
 * @dev Handles deposits and withdrawals in the yield-bearing token only (e.g., aUSDC)
 * @dev Does not manage or take custody of the underlying principal token (e.g., USDC)
 * @dev `index` refers to Aave's liquidity index
 * @dev `indexAdjustedAmount` is computed as `amount / currentIndex`
 */
contract YieldRouter is IYieldRouter {
    using WadRayMath for uint256;

    IPool private i_aaveV3Pool;
    IPoolAddressesProvider private i_addressesProvider;
    address public i_yieldBarringToken;
    address public i_principalToken;
    address private s_owner;
    bool private s_initialized;
    bool private s_ownerSet;

    struct AccountBalances {
        uint256 principalBalance; // wad
        uint256 indexAdjustedBalance; // ray
        uint256 indexAdjustedYield; // ray
    }

    // router owner's balances
    mapping(address account => AccountBalances) public s_accountBalances;
    // accounts granted permission from owner to withdraw yield
    mapping(address account => bool isPermitted) public s_permittedYieldAccess;

    modifier onlyOwner() {
        if (msg.sender != s_owner) revert NOT_OWNER();
        _;
    }

    modifier onlyPermitted() {
        if (!s_permittedYieldAccess[msg.sender]) revert NOT_PERMITTED();
        _;
    }

    modifier onlyOwnerAndPermitted() {
        if (!s_permittedYieldAccess[msg.sender] || msg.sender != s_owner) revert NOT_PERMITTED();
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
    function deposit(address _token, uint256 _amount) external onlyOwner returns (uint256) {
        if (_token != i_yieldBarringToken) revert TOKEN_NOT_PERMITTED();
        if (_amount > IERC20(_token).allowance(msg.sender, address(this))) revert TOKEN_ALLOWANCE();
        if (!IERC20(_token).transferFrom(msg.sender, address(this), _amount)) revert DEPOSIT_FAILED();

        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 indexAdjustedAmount = _toRay(_amount).rayDiv(currentIndex);
        uint256 principalAmount = indexAdjustedAmount.rayMul(currentIndex);
        uint256 wadPrincipalAmount = _fromRay(principalAmount);

        s_accountBalances[msg.sender].indexAdjustedBalance += indexAdjustedAmount;
        s_accountBalances[msg.sender].principalBalance += wadPrincipalAmount;

        emit Deposit(msg.sender, _token, wadPrincipalAmount);
        return wadPrincipalAmount;
    }

    /// @inheritdoc IYieldRouter
    function withdraw(uint256 _amount) external onlyOwner returns (uint256) {
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 currentIndexAdjustedBalance = s_accountBalances[s_owner].indexAdjustedBalance;

        //may just check for amount > contact balance for withdraw ***
        if (_toRay(_amount) > currentIndexAdjustedBalance.rayMul(currentIndex)) revert INSUFFICIENT_BALANCE();

        uint256 indexAdjustedAmount = _toRay(_amount).rayDiv(currentIndex);
        uint256 principalAmount = indexAdjustedAmount.rayMul(currentIndex);
        uint256 wadPrincipalAmount = _fromRay(principalAmount);

        s_accountBalances[msg.sender].indexAdjustedBalance -= indexAdjustedAmount;
        s_accountBalances[msg.sender].principalBalance -= wadPrincipalAmount;

        if (!IERC20(i_yieldBarringToken).transfer(msg.sender, _amount)) revert WITHDRAW_FAILED();

        emit Withdraw(msg.sender, i_yieldBarringToken, wadPrincipalAmount);
        return wadPrincipalAmount;
    }

    /// @inheritdoc IYieldRouter
    function routeYield(address _destination, uint256 _amount) external onlyOwnerAndPermitted returns (uint256) {
        if (_destination != msg.sender) revert CALLER_MUST_BE_DESTINATION();

        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 accountIndexAdjustedYield = _collectYield();

        if (_toRay(_amount) > accountIndexAdjustedYield.rayMul(currentIndex)) revert INSUFFICIENT_BALANCE();

        uint256 indexAdjustedAmount = _toRay(_amount).rayDiv(currentIndex);
        s_accountBalances[s_owner].indexAdjustedYield -= indexAdjustedAmount;

        if (!IERC20(i_yieldBarringToken).transfer(_destination, _amount)) revert WITHDRAW_FAILED();

        emit Yield_Routed(_destination, i_yieldBarringToken, _amount);
        return _amount;
    }

    // calculates how much yield has accured since deposit
    function _collectYield() private returns (uint256) {
        uint256 currentIndex = _getCurrentLiquidityIndex();
        uint256 currentIndexAdjustedBalance = s_accountBalances[s_owner].indexAdjustedBalance;
        uint256 currentPricipalBalance = s_accountBalances[s_owner].principalBalance;

        uint256 newPricipalBalance = currentIndexAdjustedBalance.rayMul(currentIndex);

        if (newPricipalBalance > currentPricipalBalance) {
            uint256 yield = newPricipalBalance - currentPricipalBalance;
            uint256 indexAdjustedYield = yield.rayDiv(currentIndex);

            s_accountBalances[s_owner].principalBalance -= _fromRay(yield);
            s_accountBalances[s_owner].indexAdjustedBalance -= indexAdjustedYield;
            s_accountBalances[s_owner].indexAdjustedYield += indexAdjustedYield;
        }

        return s_accountBalances[s_owner].indexAdjustedYield;
    }

    // fetches aave's v3 pool current liquidity index
    function _getCurrentLiquidityIndex() private view returns (uint256) {
        uint256 currentIndex = uint256(i_aaveV3Pool.getReserveData(i_principalToken).liquidityIndex);
        if (currentIndex < 1e27) revert INVALID_INDEX();
        return currentIndex;
    }

    // converts number to RAY units (1e27)
    function _toRay(uint256 _num) private pure returns (uint256) {
        return _num * 1e27;
    }

    // converts number from RAY units (1e27) to WAD units (1e18)
    function _fromRay(uint256 _num) private pure returns (uint256) {
        return _num / 1e27;
    }

    // gets router owner
    function getRouterOwner() external view returns (address) {
        return s_owner;
    }
}
