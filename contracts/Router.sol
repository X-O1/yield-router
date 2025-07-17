// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RouterFactory} from "./RouterFactory.sol";
import {RouterFactoryController} from "./RouterFactoryController.sol";
import "./GlobalErrors.sol";

/**
 * @title Router
 * @notice Routes yield from a user's deposited yield-bearing tokens to addresses granted router access.
 * @dev Only handles deposits and withdrawals in the yield-bearing token (e.g., aUSDC).
 * @dev All external inputs/outputs are in WAD (1e18); internal accounting uses RAY (1e27).
 */
contract Router {
    // ======================= Libraries =======================

    // math helpers for wad and ray units
    using WadRayMath for uint256;

    // ======================= State Variables =======================

    // aave pool interface
    IPool private s_aavePool;
    // aave address provider
    IPoolAddressesProvider private s_addressesProvider;
    // yield-bearing token address (e.g., aUSDC)
    address private s_yieldBarringToken;
    // yield token decimals
    uint256 public s_yieldTokenDecimals;
    // principal token address (e.g., USDC)
    address private s_principalToken;
    // principal token decimals
    uint256 public s_principalTokenDecimals;
    // router owner
    address private s_routerOwner;
    // router factory instance
    RouterFactory private s_routerFactory;
    // factory address
    address private s_routerFactoryAddress;
    // router factory controller instance
    RouterFactoryController private s_factoryController;
    // factory controlleraddress
    address private s_factoryControllerAddress;
    // flag to ensure owner can only be set once
    bool private s_ownerSet;
    // flag to prevent re-initialization
    bool private s_initialized;
    // current state of router
    RouterStatus private s_routerStatus;
    // Ray units
    uint256 private constant RAY = 1e27;

    // maps owner to their balances
    mapping(address owner => OwnerBalances) public s_ownerBalances;
    // maps each address granted router access to their yield allowance limit and tracks how much yield they’ve recieved.
    mapping(address addressGrantedAccess => RouterAccessRecords) public s_routerAccessRecords;

    // ======================= structs =======================

    // balances for owner
    struct OwnerBalances {
        uint256 yieldTokenBalance;
        uint256 indexAdjustedBalance; // ray (1e27)
        uint256 principalBalance; // ray (1e27)
        uint256 yield; // ray (1e27)
    }
    // status and withdrawn balances of addresses granted router access
    struct RouterAccessRecords {
        bool grantedYieldAccess;
        uint256 yieldAllowance; // (in prinicipal value e.g., USDC) (ray (1e27))
    }
    // status of router
    struct RouterStatus {
        bool isActive;
        address currentDestination;
    }
    // ======================= Events =======================

    event Deposit(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Router_Activated(address indexed router);
    event Router_Status_Changed(bool indexed activeStatus, address indexed currentDestination);
    event Yield_Routed(address indexed destination, uint256 indexed amount, uint256 indexed routerFee);

    // ======================= Modifiers =======================

    // restricts access to router owner
    modifier onlyOwner() {
        if (msg.sender != s_routerOwner) revert NOT_OWNER();
        _;
    }

    // resticts access to factory if router is active
    modifier onlyFactory() {
        if (msg.sender != s_routerFactoryAddress) revert NOT_FACTORY();
        _;
    }

    // denies access if router is active
    modifier ifRouterNotActive() {
        if (s_routerStatus.isActive) revert ROUTER_ACTIVE();
        _;
    }
    // denies access if router is not active
    modifier ifRouterActive() {
        if (!s_routerStatus.isActive) revert ROUTER_NOT_ACTIVE();
        _;
    }

    // denies access if router destination is not set
    modifier ifRouterDestinationIsSet() {
        if (s_routerStatus.currentDestination == address(0)) revert ROUTER_DESTIONATION_NOT_SET();
        _;
    }

    // ======================= Initialization =======================

    // initializes the router with factory address, aave provider, and token settings
    function initialize(
        address _factoryControllerAddress,
        address _routerFactoryAddress,
        address _addressProvider,
        address _yieldBarringToken,
        address _principalToken
    ) external {
        if (s_initialized) revert ALREADY_INITIALIZED();
        s_initialized = true;

        s_factoryControllerAddress = _factoryControllerAddress;
        s_factoryController = RouterFactoryController(s_factoryControllerAddress);
        s_routerFactoryAddress = _routerFactoryAddress;
        s_routerFactory = RouterFactory(s_routerFactoryAddress);
        s_addressesProvider = IPoolAddressesProvider(_addressProvider);
        s_aavePool = IPool(s_addressesProvider.getPool());
        s_yieldBarringToken = _yieldBarringToken;
        s_principalToken = _principalToken;
        s_yieldTokenDecimals = ERC20(_yieldBarringToken).decimals();
        s_principalTokenDecimals = ERC20(s_principalToken).decimals();
    }

    // sets the router's owner (only once)
    function setOwner(address _owner) external returns (address) {
        if (s_ownerSet) revert ALREADY_SET();
        s_ownerSet = true;
        s_routerOwner = _owner;
        return s_routerOwner;
    }

    // ======================= Access Control =======================

    // grants or revokes yield access and sets the yield allowance for an address
    function manageRouterAccess(address _account, bool _grantedYieldAccess, uint256 _yieldAllowance) external onlyOwner {
        if (_grantedYieldAccess) {
            if (s_routerAccessRecords[_account].grantedYieldAccess) revert ACCESS_ALREADY_GRANTED();
        }
        if (!_grantedYieldAccess) {
            if (!s_routerAccessRecords[_account].grantedYieldAccess) revert ACCESS_ALREADY_NOT_GRANTED();
        }
        _grantedYieldAccess ? s_routerAccessRecords[_account].grantedYieldAccess = true : s_routerAccessRecords[_account].grantedYieldAccess = false;
        _grantedYieldAccess ? s_routerAccessRecords[_account].yieldAllowance = _yieldAllowance : s_routerAccessRecords[_account].yieldAllowance = 0;
    }

    // ======================= Router Control =======================

    // once activated router yield will be routed autmatically from facotry untill deativated
    // also sets destination of router
    function activateRouter(address _destination) external onlyOwner {
        if (s_ownerBalances[s_routerOwner].indexAdjustedBalance == 0) revert NO_BALANCE_DEPOSIT_REQUIRED();
        if (s_routerStatus.isActive) revert ROUTER_ACTIVE();

        _setRouterDestination(_destination);
        s_routerFactory.addToActiveRouterList(address(this));
        s_routerStatus.isActive = true;

        emit Router_Activated(address(this));
        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.currentDestination);
    }

    // deactivates router and stops any yield being sent out
    function deactivateRouter() external onlyOwner {
        if (!s_routerStatus.isActive) revert ROUTER_NOT_ACTIVE();
        s_routerStatus.isActive = false;
        s_routerStatus.currentDestination = address(0);

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.currentDestination);
    }

    // routes available yield to the destination address and charges a router fee
    function routeYield() external ifRouterDestinationIsSet ifRouterActive onlyFactory returns (uint256) {
        uint256 index = _getLiquidityIndex();
        uint256 yield = _updateYield(index);
        if (yield == 0) revert NO_YIELD();

        address destination = s_routerStatus.currentDestination;
        uint256 yieldAllowance = s_routerAccessRecords[destination].yieldAllowance;

        uint256 indexAdjustedYield = _numDiv(yield, index);
        uint256 indexAdjustedAllowance = _numDiv(yieldAllowance, index);

        uint256 yieldRouteAmount;
        uint256 indexAdjustedRouteAmount;

        if (yieldAllowance <= yield) {
            yieldRouteAmount = yieldAllowance;
            indexAdjustedRouteAmount = indexAdjustedAllowance;
            s_routerAccessRecords[destination].yieldAllowance = 0;
        } else {
            yieldRouteAmount = yield;
            indexAdjustedRouteAmount = indexAdjustedYield;
            s_routerAccessRecords[destination].yieldAllowance -= yieldRouteAmount;
        }

        s_ownerBalances[s_routerOwner].yield -= yieldRouteAmount;
        s_ownerBalances[s_routerOwner].indexAdjustedBalance -= indexAdjustedRouteAmount;

        // updates router status based on updated destination's yield allowance
        _updateRouterStatus(destination);

        uint256 routerFee = _calculateFee(yieldRouteAmount);
        if (yieldRouteAmount < routerFee) revert OVERFLOW_UNDERFLOW();
        uint256 routeAmountAfterFee = yieldRouteAmount - routerFee;
        uint256 poolWithdrawAmount = yieldRouteAmount;

        // WITHDRAW FROM AAVE AND SEND USDC
        if (s_aavePool.withdraw(s_principalToken, poolWithdrawAmount, address(this)) != poolWithdrawAmount) {
            revert POOL_WITHDRAW_FAILED();
        }

        if (!IERC20(s_principalToken).transfer(s_factoryControllerAddress, routerFee)) revert FEE_TRANSFER_FAILED();
        if (!IERC20(s_principalToken).transfer(destination, routeAmountAfterFee)) revert YIELD_TRANSFER_FAILED();

        s_factoryController.addFees(s_principalToken, routerFee);

        emit Yield_Routed(destination, routeAmountAfterFee, routerFee);
        return (routeAmountAfterFee);
    }

    // ======================= Deposit & Withdraw =======================

    // deposits yield-bearing token into router and updates internal balances
    function deposit(uint256 _yieldTokenAmount) external onlyOwner returns (uint256) {
        uint256 index = _getLiquidityIndex();
        uint256 indexAdjustedAmount = _numDiv(_yieldTokenAmount, index);
        uint256 principalAmount = _numMul(_yieldTokenAmount, index);

        if (_yieldTokenAmount > IERC20(s_yieldBarringToken).allowance(msg.sender, address(this))) revert TOKEN_ALLOWANCE();
        if (!IERC20(s_yieldBarringToken).transferFrom(msg.sender, address(this), _yieldTokenAmount)) revert DEPOSIT_FAILED();

        s_ownerBalances[msg.sender].yieldTokenBalance += _yieldTokenAmount;
        s_ownerBalances[msg.sender].indexAdjustedBalance += indexAdjustedAmount;
        s_ownerBalances[msg.sender].principalBalance += principalAmount;

        emit Deposit(msg.sender, s_yieldBarringToken, _yieldTokenAmount);
        return _yieldTokenAmount;
    }

    // withdraws specified principal amount if router is inactive and unlocked
    function withdraw(uint256 _yieldTokenAmount) external onlyOwner ifRouterNotActive returns (uint256) {
        uint256 yieldTokenBalance = s_ownerBalances[s_routerOwner].yieldTokenBalance;
        uint256 indexAdjustedAmount = _numDiv(_yieldTokenAmount, _getLiquidityIndex());
        uint256 principalAmount = _numMul(_yieldTokenAmount, _getLiquidityIndex());

        if (_yieldTokenAmount > yieldTokenBalance) revert INSUFFICIENT_BALANCE();

        s_ownerBalances[msg.sender].yieldTokenBalance -= _yieldTokenAmount;
        s_ownerBalances[msg.sender].indexAdjustedBalance -= indexAdjustedAmount;
        s_ownerBalances[msg.sender].principalBalance -= principalAmount;

        if (!IERC20(s_yieldBarringToken).transfer(msg.sender, _yieldTokenAmount)) revert WITHDRAW_FAILED();

        emit Withdraw(msg.sender, s_yieldBarringToken, _yieldTokenAmount);
        return _yieldTokenAmount;
    }

    // ======================= Private Helpers =======================

    // sets where yield will be routed to after the router is activated
    function _setRouterDestination(address _destination) private {
        if (!s_routerAccessRecords[_destination].grantedYieldAccess) revert ADDRESS_NOT_GRANTED_YIELD_ACCESS();
        if (s_routerStatus.isActive) revert ROUTER_ACTIVE();

        s_routerStatus.currentDestination = _destination;
        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.currentDestination);
    }

    // helper for `activateRouter()` to update router status based on updated destination's yield allowance
    function _updateRouterStatus(address _destination) private {
        uint256 updatedRayRemainingYieldAllowance = s_routerAccessRecords[_destination].yieldAllowance;

        if (updatedRayRemainingYieldAllowance == 0) {
            if (s_routerStatus.isActive) {
                s_routerFactory.removeFromActiveRouterList(address(this));
                s_routerStatus.currentDestination = address(0);
                s_routerStatus.isActive = false;
            }
        }
    }

    // calculates how much yield has accured since deposit
    function _updateYield(uint256 _currentIndex) private returns (uint256) {
        uint256 indexAdjustedBalance = s_ownerBalances[s_routerOwner].indexAdjustedBalance;
        uint256 principalBalance = s_ownerBalances[s_routerOwner].principalBalance;
        uint256 newPricipalBalance = _numMul(indexAdjustedBalance, _currentIndex);

        if (newPricipalBalance > principalBalance) {
            uint256 yield = newPricipalBalance - principalBalance;
            s_ownerBalances[s_routerOwner].yield = yield;
        }
        return s_ownerBalances[s_routerOwner].yield;
    }

    // get current router fee from factory
    function _getCurrentRouterFeePercentage() private view returns (uint256) {
        uint256 routerfee = s_factoryController.getRouterFeePercentage();
        return routerfee;
    }

    function _calculateFee(uint256 _amountBeingRouted) private view returns (uint256) {
        uint256 currentFeePercentage = _getCurrentRouterFeePercentage();
        return _numMul(_amountBeingRouted, currentFeePercentage);
    }

    // fetches aave's v3 pool's current liquidity index
    function _getLiquidityIndex() private view returns (uint256) {
        uint256 currentIndex = uint256(s_aavePool.getReserveData(s_principalToken).liquidityIndex);
        require(currentIndex >= 1e27, INVALID_INDEX());

        // Convert from RAY (1e27) → 1e6
        return currentIndex / 1e21;
    }

    function _numDiv(uint256 _wholeNum, uint256 _partNum) private view returns (uint256) {
        require(_partNum != 0, MUST_BE_GREATER_THAN_0());
        return (_wholeNum * (10 ** s_principalTokenDecimals)) / _partNum;
    }

    function _numMul(uint256 _wholeNum, uint256 _partNum) private view returns (uint256) {
        require(_partNum != 0, MUST_BE_GREATER_THAN_0());
        return (_wholeNum * _partNum) / (10 ** s_principalTokenDecimals);
    }

    // ======================= View Functions =======================

    // return router owner
    function getRouterOwner() external view returns (address) {
        return s_routerOwner;
    }

    // returns whether the router is currently active.
    function getRouterIsActive() external view returns (bool) {
        return s_routerStatus.isActive;
    }

    // returns the current destination address for routed yield.
    function getRouterCurrentDestination() external view returns (address) {
        return s_routerStatus.currentDestination;
    }

    // return owner's index-adjusted balance (ray)
    function getOwnerIndexAdjustedBalance() external view returns (uint256) {
        return s_ownerBalances[s_routerOwner].indexAdjustedBalance;
    }

    // return owner's index-adjusted yield (ray)
    function getOwnerYield() external view returns (uint256) {
        return s_ownerBalances[s_routerOwner].yield;
    }

    // return address's current yield allowance (prinicipal value e.g., USDC) (ray)
    function getYieldAllowance(address _address) external view returns (uint256) {
        return s_routerAccessRecords[_address].yieldAllowance;
    }

    // return owner's deposit principal (ray)
    function getOwnerPrincipalBalance() external view returns (uint256) {
        return s_ownerBalances[s_routerOwner].principalBalance;
    }

    // return router address
    function getAddress() external view returns (address) {
        return address(this);
    }

    // return router current status
    function getRouterStatus() external view returns (bool) {
        return s_routerStatus.isActive;
    }

    // check if an address has been granted router access
    function isAddressGrantedRouterAccess(address _address) external view returns (bool) {
        return s_routerAccessRecords[_address].grantedYieldAccess;
    }

    // get router balanceOf yield barring token
    function getRouterBalance() external view returns (uint256) {
        return IERC20(s_yieldBarringToken).balanceOf(address(this));
    }

    // get the principal value of routers yield barring token balance
    function getRouterBalancePrincipalValue() external view returns (uint256) {
        uint256 yieldTokensBalance = IERC20(s_yieldBarringToken).balanceOf(address(this));
        return _numDiv(yieldTokensBalance, _getLiquidityIndex());
    }
}
