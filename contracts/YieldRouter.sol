// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {ScaledBalanceTokenBase} from "@aave-v3-core/protocol/tokenization/base/ScaledBalanceTokenBase.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import "./YieldRouterErrors.sol";

// creates vaults for each account per yield barring token to hold tokens and route its yield.
// one factory for each yield barring token. YieldRouterFactoryAUSDC YieldRouterFactoryAUSDT
// using ERC-1167 clones from open zeppelin for cheap vault creation
// deposits and withdrawls are done in the yield barring token only.
// yield routers do not manage the principle token
// index = aave's liquidity index
// index adjusted = amount / current index
contract YieldRouter {
    using WadRayMath for uint256;

    IPool private immutable i_aaveV3Pool;
    IPoolAddressesProvider private immutable i_addressesProvideer;
    address public immutable i_yieldBarringToken;
    address public immutable i_prinicalToken;
    address public s_owner;

    struct AccountBalances {
        uint256 principalBalance; // wad
        uint256 indexAdjustedBalance; // ray
        uint256 indexAdjustedYield; // ray
    }

    // accounts granted permission from owner to withdraw yield
    mapping(address account => AccountBalances) public s_accountBalances;
    mapping(address account => bool isPermitted) public s_permittedYieldAccess;

    event Deposit(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Yield_Routed(address indexed destination, address indexed token, uint256 indexed amount);

    constructor(address _addressProvider, address _yieldBarringToken, address _prinicalToken) {
        i_addressesProvideer = IPoolAddressesProvider(_addressProvider);
        i_aaveV3Pool = IPool(i_addressesProvideer.getPool());
        i_yieldBarringToken = _yieldBarringToken;
        i_prinicalToken = _prinicalToken;
    }

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

    function initialize() external returns (address) {
        if (s_owner != address(0)) revert ALREADY_INITIALIZED();
        s_owner = msg.sender;
        return s_owner;
    }

    function deposit(address _token, uint256 _amount) external onlyOwner returns (uint256) {
        if (_token != i_yieldBarringToken) revert TOKEN_NOT_ALLOWED();
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

    // allows owner and permitted addresses to withdraw collected yield to a chosen address
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

    // manages addresses permitted to withdraw from yield balance
    function manageYieldAccess(address _account, bool _isPermitted) external onlyOwner {
        _isPermitted ? s_permittedYieldAccess[_account] = true : s_permittedYieldAccess[_account] = false;
    }

    function _getCurrentLiquidityIndex() private view returns (uint256) {
        uint256 currentIndex = uint256(i_aaveV3Pool.getReserveData(i_prinicalToken).liquidityIndex);
        if (currentIndex < 1e27) revert INVALID_INDEX();
        return currentIndex;
    }

    function _toRay(uint256 _num) private pure returns (uint256) {
        return _num * 1e27;
    }

    function _fromRay(uint256 _num) private pure returns (uint256) {
        return _num / 1e27;
    }
}
