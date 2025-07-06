// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
import "./RouterErrors.sol";

/**
 * @title Router
 * @notice Routes yield from a user's deposited yield-bearing tokens to addresses granted router access.
 * @dev Only handles deposits and withdrawals in the yield-bearing token (e.g., aUSDC).
 * @dev All external inputs/outputs are in WAD (1e18); internal accounting uses RAY (1e27).
 */
contract Router is IRouter {
    // math helpers for wad and ray units
    using WadRayMath for uint256;

    // aave pool interface
    IPool private i_aavePool;
    // aave address provider
    IPoolAddressesProvider private i_addressesProvider;
    // yield-bearing token address (e.g., aUSDC)
    address public i_yieldBarringToken;
    // principal token address (e.g., USDC)
    address public i_principalToken;
    // router owner
    address private s_owner;
    // router factory owner
    address private s_factoryOwner;
    // factory address
    address private s_factoryAddress;
    // flag to ensure owner can only be set once
    bool private s_ownerSet;
    // flag to ensure factory owner can only be set once
    bool private s_factoryOwnerSet;
    // flag to prevent re-initialization
    bool private s_initialized;
    // current state of router
    RouterStatus private s_routerStatus;
    // previous scanned router address
    address private s_previousRouterAddress;
    // previous scanned router instance
    // Router private s_previousRouterContract = Router(s_previousRouterAddress);
    // address of the prev scanned router
    address private s_prevRouterScanned;
    // status of the prev scanned router
    bool private s_prevRouterStatus;

    // balances for owner
    struct OwnerBalances {
        uint256 principalBalance; // ray (1e27)
        uint256 indexAdjustedBalance; // ray (1e27)
        uint256 principalYield; // ray (1e27)
    }

    // status and withdrawn balances of addresses granted router access
    struct RouterAccessRecords {
        bool grantedYieldAccess;
        uint256 principalYieldAllowance; // (in prinicipal value e.g., USDC) (ray (1e27))
    }

    // status of router
    struct RouterStatus {
        bool isActive;
        bool isLocked;
        address currentDestination;
    }

    // maps owner to their balances
    mapping(address owner => OwnerBalances) public s_ownerBalances;

    // maps each address granted router access to their yield allowance limit and tracks how much yield they’ve recieved.
    mapping(address addressGrantedAccess => RouterAccessRecords) public s_routerAccessRecords;

    // restricts access to router factory owner
    modifier onlyFactoryOwner() {
        if (msg.sender != s_factoryOwner) revert NOT_FACTORY_OWNER();
        _;
    }
    // restricts access to router owner
    modifier onlyOwner() {
        if (msg.sender != s_owner) revert NOT_OWNER();
        _;
    }
    // denies access if router is active
    modifier ifRouterNotActive() {
        if (s_routerStatus.isActive) revert ROUTER_ACTIVE();
        _;
    }

    // denies access if router is not active
    // ensures only owner can call the router while its inactive once active any can call
    modifier ifRouterActive() {
        if (msg.sender != s_owner)
            if (!s_routerStatus.isActive) revert ROUTER_ACTIVE();
        _;
    }
    // denies access if router is locked
    modifier ifRouterNotLocked() {
        if (s_routerStatus.isLocked) revert ROUTER_LOCKED();
        _;
    }
    // denies access if router destination is not set
    modifier ifRouterDestinationIsSet() {
        if (s_routerStatus.currentDestination == address(0)) revert ROUTER_DESTIONATION_NOT_SET();
        _;
    }

    /// @inheritdoc IRouter
    function initialize(
        address _factoryAddress,
        address _previousRouter,
        address _addressProvider,
        address _yieldBarringToken,
        address _prinicalToken
    ) external {
        if (s_initialized) revert ALREADY_INITIALIZED();
        s_initialized = true;

        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_aavePool = IPool(i_addressesProvider.getPool());
        i_yieldBarringToken = _yieldBarringToken;
        i_principalToken = _prinicalToken;
        s_previousRouterAddress = _previousRouter;
        s_factoryAddress = _factoryAddress;
    }

    /// @inheritdoc IRouter
    function setOwner(address _owner) external returns (address) {
        if (s_ownerSet) revert ALREADY_SET();
        s_ownerSet = true;
        s_owner = _owner;
        return s_owner;
    }

    /// @inheritdoc IRouter
    function setFactoryOwner(address _factoryOwner) external returns (address) {
        if (s_factoryOwnerSet) revert ALREADY_SET();
        s_factoryOwnerSet = true;
        s_factoryOwner = _factoryOwner;
        return s_factoryOwner;
    }

    /// @inheritdoc IRouter
    function manageRouterAccess(address _account, bool _grantedYieldAccess, uint256 _principalYieldAllowance) external onlyOwner {
        if (_grantedYieldAccess) {
            if (s_routerAccessRecords[_account].grantedYieldAccess) revert ACCESS_ALREADY_GRANTED();
        }
        if (!_grantedYieldAccess) {
            if (!s_routerAccessRecords[_account].grantedYieldAccess) revert ACCESS_ALREADY_NOT_GRANTED();
        }
        _grantedYieldAccess ? s_routerAccessRecords[_account].grantedYieldAccess = true : s_routerAccessRecords[_account].grantedYieldAccess = false;

        _grantedYieldAccess
            ? s_routerAccessRecords[_account].principalYieldAllowance = _wadToRay(_principalYieldAllowance)
            : s_routerAccessRecords[_account].principalYieldAllowance = 0;
    }

    /// @inheritdoc IRouter
    function setRouterDestination(address _destination) external onlyOwner {
        if (!s_routerAccessRecords[_destination].grantedYieldAccess) revert ADDRESS_NOT_GRANTED_YIELD_ACCESS();
        if (s_routerStatus.isActive) revert ROUTER_ACTIVE();

        s_routerStatus.currentDestination = _destination;
        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked, s_routerStatus.currentDestination);
    }

    /// @inheritdoc IRouter
    function deactivateRouter() external onlyOwner ifRouterNotLocked {
        if (!s_routerStatus.isActive) revert ROUTER_NOT_ACTIVE();
        s_routerStatus.isActive = false;

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked, s_routerStatus.currentDestination);
    }

    // === LOCKS ALL OF OWNER'S FUNDS UNTIL DESTINATION ADDRESS RECIEVES MAX YIELD ALLOWANCE ===
    /// @inheritdoc IRouter
    function lockRouter() public onlyOwner {
        if (!s_routerStatus.isActive) revert ROUTER_MUST_BE_ACTIVE_TO_LOCK();
        if (s_routerStatus.isLocked) revert ROUTER_LOCKED();
        s_routerStatus.isLocked = true;

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked, s_routerStatus.currentDestination);
    }

    /// @inheritdoc IRouter
    function emergencyRouterShutDown() external onlyFactoryOwner {
        if (!s_routerStatus.isLocked) revert ROUTER_NOT_LOCKED();
        s_routerStatus.isLocked = false;
        s_routerStatus.isActive = false;
        s_routerStatus.currentDestination = address(0);

        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked, s_routerStatus.currentDestination);
    }

    /// @inheritdoc IRouter
    function activateRouter() external ifRouterDestinationIsSet ifRouterActive returns (uint256) {
        s_routerStatus.isActive = true;

        uint256 index = _getLiquidityIndex();
        address destination = s_routerStatus.currentDestination;

        uint256 principalYield = _updatePrincipalYield(index);
        if (principalYield == 0) revert NO_YIELD();
        uint256 principalYieldAllowance = s_routerAccessRecords[destination].principalYieldAllowance;
        uint256 indexAdjustedPrincipalYield = principalYield.rayDiv(index);
        uint256 indexAdjustedPrincipalYieldAllowance = principalYieldAllowance.rayDiv(index);

        uint256 finalPrincipalYieldRouteAmount;
        uint256 finalIndexAdjustedRouteAmount;

        if (principalYieldAllowance <= principalYield) {
            finalPrincipalYieldRouteAmount = principalYieldAllowance;
            finalIndexAdjustedRouteAmount = indexAdjustedPrincipalYieldAllowance;

            s_routerAccessRecords[destination].principalYieldAllowance = 0;
        }

        if (principalYieldAllowance > principalYield) {
            finalPrincipalYieldRouteAmount = principalYield;
            finalIndexAdjustedRouteAmount = indexAdjustedPrincipalYield;

            s_routerAccessRecords[destination].principalYieldAllowance -= finalPrincipalYieldRouteAmount;
        }

        s_ownerBalances[s_owner].principalYield -= finalPrincipalYieldRouteAmount;
        s_ownerBalances[s_owner].indexAdjustedBalance -= finalIndexAdjustedRouteAmount;

        // updates router status based on updated destination's yield allowance
        _updateRouterStatus(destination);

        uint256 wadFinalRouteAmount = _rayToWad(finalIndexAdjustedRouteAmount);
        if (!IERC20(i_yieldBarringToken).transfer(destination, wadFinalRouteAmount)) revert WITHDRAW_FAILED();
        endRouterScan();
        scanAndActivatePreviousRouters();

        emit Router_Activated(destination, i_yieldBarringToken, wadFinalRouteAmount, s_routerStatus.isActive);
        emit Router_Status_Changed(s_routerStatus.isActive, s_routerStatus.isLocked, destination);

        return principalYield;
    }

    /// @inheritdoc IRouter
    function deposit(address _yieldBarringToken, uint256 _amountInPrincipalValue) external onlyOwner returns (uint256) {
        if (_yieldBarringToken != i_yieldBarringToken) revert TOKEN_NOT_PERMITTED();
        uint256 indexAdjustedPrincipalAmount = _wadToRay(_amountInPrincipalValue).rayDiv(_getLiquidityIndex());

        if (indexAdjustedPrincipalAmount > IERC20(_yieldBarringToken).allowance(msg.sender, address(this))) revert TOKEN_ALLOWANCE();
        if (!IERC20(_yieldBarringToken).transferFrom(msg.sender, address(this), _rayToWad(indexAdjustedPrincipalAmount))) revert DEPOSIT_FAILED();

        s_ownerBalances[msg.sender].indexAdjustedBalance += indexAdjustedPrincipalAmount;
        s_ownerBalances[msg.sender].principalBalance += _wadToRay(_amountInPrincipalValue);

        emit Deposit(msg.sender, _yieldBarringToken, _rayToWad(indexAdjustedPrincipalAmount));
        return _rayToWad(indexAdjustedPrincipalAmount);
    }

    /// @inheritdoc IRouter
    function withdraw(uint256 _amountInPrincipalValue) external onlyOwner ifRouterNotActive ifRouterNotLocked returns (uint256) {
        uint256 currentIndexAdjustedBalance = s_ownerBalances[s_owner].indexAdjustedBalance;
        uint256 indexAdjustedPrincipalAmount = _wadToRay(_amountInPrincipalValue).rayDiv(_getLiquidityIndex());

        if (indexAdjustedPrincipalAmount > currentIndexAdjustedBalance) revert INSUFFICIENT_BALANCE();

        s_ownerBalances[msg.sender].indexAdjustedBalance -= indexAdjustedPrincipalAmount;
        s_ownerBalances[msg.sender].principalBalance -= _wadToRay(_amountInPrincipalValue);

        if (!IERC20(i_yieldBarringToken).transfer(msg.sender, _rayToWad(indexAdjustedPrincipalAmount))) revert WITHDRAW_FAILED();

        emit Withdraw(msg.sender, i_yieldBarringToken, _rayToWad(indexAdjustedPrincipalAmount));
        return _rayToWad(indexAdjustedPrincipalAmount);
    }

    // helper for `activateRouter()` to update router status based on updated destination's yield allowance
    function _updateRouterStatus(address _destination) private {
        uint256 updatedRayRemainingYieldAllowance = s_routerAccessRecords[_destination].principalYieldAllowance;

        if (updatedRayRemainingYieldAllowance == 0) {
            s_routerStatus.isActive = false;
            s_routerStatus.currentDestination = address(0);
        }
        if (s_routerStatus.isLocked && updatedRayRemainingYieldAllowance == 0) {
            s_routerStatus.isLocked = false;
            s_routerStatus.currentDestination = address(0);
        }
    }

    // calculates how much yield has accured since deposit
    function _updatePrincipalYield(uint256 _currentIndex) private returns (uint256) {
        uint256 currentIndexAdjustedBalance = s_ownerBalances[s_owner].indexAdjustedBalance;
        uint256 newPricipalBalance = currentIndexAdjustedBalance.rayMul(_currentIndex);

        uint256 currentPricipalBalance = s_ownerBalances[s_owner].principalBalance;

        if (newPricipalBalance > currentPricipalBalance) {
            uint256 newYield = newPricipalBalance - currentPricipalBalance;
            s_ownerBalances[s_owner].principalYield = newYield;
        }
        return s_ownerBalances[s_owner].principalYield;
    }

    // return address of previous router created
    function getPreviousRouter() public view returns (address) {
        return s_previousRouterAddress;
    }

    // scan through every previous router. check if active. if status is active, activateRouter
    function scanAndActivatePreviousRouters() public {
        if (s_prevRouterScanned == address(0)) s_prevRouterScanned = address(this);

        address prevRouter = Router(s_prevRouterScanned).getPreviousRouter();
        Router router = Router(prevRouter);
        s_prevRouterScanned = router.getAddress();
        if (s_prevRouterScanned == s_factoryAddress) {
            endRouterScan();
            return;
        }
        s_prevRouterStatus = router.getRouterStatus();
        if (s_prevRouterStatus) router.activateRouter();
    }

    function endRouterScan() private {
        s_prevRouterScanned = address(0);
    }

    function getAddress() public view returns (address) {
        return address(this);
    }

    function getRouterStatus() public view returns (bool) {
        return s_routerStatus.isActive;
    }

    // fetches aave's v3 pool's current liquidity index
    function _getLiquidityIndex() private view returns (uint256) {
        uint256 currentIndex = uint256(i_aavePool.getReserveData(i_principalToken).liquidityIndex);
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

    // returns whether the router is currently active.
    function getRouterIsActive() external view returns (bool) {
        return s_routerStatus.isActive;
    }

    // returns whether the router is currently locked.
    function getRouterIsLocked() external view returns (bool) {
        return s_routerStatus.isLocked;
    }

    // returns the current destination address for routed yield.
    function getRouterCurrentDestination() external view returns (address) {
        return s_routerStatus.currentDestination;
    }

    // return owner's index-adjusted balance (ray)
    function getOwnerIndexAdjustedBalance() external view returns (uint256) {
        return s_ownerBalances[s_owner].indexAdjustedBalance;
    }

    // return owner's index-adjusted yield (ray)
    function getOwnerPrincipalYield() external view returns (uint256) {
        return s_ownerBalances[s_owner].principalYield;
    }

    // return address's current yield allowance (prinicipal value e.g., USDC) (ray)
    function getYieldAllowanceInPrincipalValue(address _address) external view returns (uint256) {
        return s_routerAccessRecords[_address].principalYieldAllowance;
    }

    // return owner's deposit principal (ray)
    function getOwnerPrincipalValue() external view returns (uint256) {
        return s_ownerBalances[s_owner].principalBalance;
    }

    // check if an address has been granted router access
    function isAddressGrantedRouterAccess(address _address) external view returns (bool) {
        return s_routerAccessRecords[_address].grantedYieldAccess;
    }
}
