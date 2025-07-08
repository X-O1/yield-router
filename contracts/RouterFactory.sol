// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {Router} from "./Router.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import "./RouterErrors.sol";
import {IERC20Permit} from "@openzeppelin/token/ERC20/extensions/IERC20Permit.sol";

/**
 * @title RouterFactory
 * @notice deploys minimal proxy Router contracts for users to route yield from permitted tokens
 */
contract RouterFactory {
    // aave v3 pool instance
    IPool private immutable i_aaveV3Pool;
    // aave address provider
    IPoolAddressesProvider private immutable i_addressesProvider;
    // logic contract address used for cloning Router instances
    address private immutable i_implementation;
    // owner of this factory
    address private immutable i_factoryOwner;
    // all routers deployed by this factory
    address[] public s_routers;
    // active routers ready for routing
    address[] public s_activeRouters;
    // fee taken from routed yield (wad format, e.g. 1e15 = 0.1%)
    uint256 private s_routerFeePercentage = 1e15;
    // permitted tokens
    mapping(address token => bool isPermitted) private s_permittedTokens;
    // all routers created by this factory
    mapping(address router => bool isPermitted) private s_permittedRouter;
    // accumulated fees per token
    mapping(address token => uint256 amount) public s_feesCollected;

    event TokenPermissionUpdated(address indexed token, bool isPermitted);
    event RouterFeePercentageUpdated(uint256 newFeePercentage);
    event ActiveRoutersActivated(uint256 numberOfRouters);
    event RouterCreated(address indexed router, address indexed owner, address yieldToken, address principalToken);
    event RouterActivated(address indexed router);
    event RouterDeactivated(address indexed router);

    // constructor initializes factory
    constructor(address _addressProvider) {
        i_implementation = address(new Router());
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_aaveV3Pool = IPool(i_addressesProvider.getPool());
        i_factoryOwner = msg.sender;
    }

    // restricts function to factory owner
    modifier onlyOwner() {
        if (msg.sender != i_factoryOwner) revert NOT_OWNER();
        _;
    }

    // restricts function to only routers deployed by this factory
    modifier onlyRouter() {
        if (!s_permittedRouter[msg.sender]) revert NOT_ROUTER();
        _;
    }

    // permits or revokes a token
    function permitTokensForFactory(address _token, bool _isPermitted) external onlyOwner {
        _isPermitted ? s_permittedTokens[_token] = true : s_permittedTokens[_token] = false;
        emit TokenPermissionUpdated(_token, _isPermitted);
    }

    // updates router fee percentage
    function setRouterFeePercentage(uint256 _routerFeePercentage) external onlyOwner {
        _enforceWAD(_routerFeePercentage);
        s_routerFeePercentage = _routerFeePercentage;
        emit RouterFeePercentageUpdated(_routerFeePercentage);
    }

    // activates all routers marked active
    function activateActiveRouters() external onlyOwner {
        for (uint256 i = 0; i < s_activeRouters.length; i++) {
            Router router = Router(s_activeRouters[i]);
            router.routeYield();
        }
        emit ActiveRoutersActivated(s_activeRouters.length);
    }

    /// @notice deploys a new Router instance
    /// @param _routerOwner the address that will control the router
    /// @param _yieldBarringToken the yield-bearing token address
    /// @param _principalToken the underlying token address
    /// @return router the deployed Router instance
    function createRouter(address _routerOwner, address _yieldBarringToken, address _principalToken) external returns (Router) {
        if (!s_permittedTokens[_yieldBarringToken]) revert TOKEN_NOT_PERMITTED();
        if (!s_permittedTokens[_principalToken]) revert TOKEN_NOT_PERMITTED();

        address clone = Clones.clone(i_implementation);
        Router router = Router(clone);

        router.initialize(address(this), address(i_addressesProvider), _yieldBarringToken, _principalToken);
        router.setOwner(_routerOwner);
        router.setFactoryOwner(i_factoryOwner);
        s_routers.push(address(router));
        s_permittedRouter[address(router)] = true;
        emit RouterCreated(address(router), _routerOwner, _yieldBarringToken, _principalToken);
        return (router);
    }

    // adds fees collected by routers
    function addFees(address _token, uint256 _amount) external onlyRouter {
        s_feesCollected[_token] += _amount;
    }

    // adds router to active list
    function addToActiveRouterList(address _router) external onlyRouter {
        s_activeRouters.push(_router);
        emit RouterActivated(_router);
    }

    // removes router from active list
    function removeFromActiveRouterList(address _router) external onlyRouter {
        bool routerFound;
        for (uint256 i = 0; i < s_activeRouters.length; i++) {
            if (s_activeRouters[i] == _router) {
                routerFound = true;
                if (i != s_activeRouters.length - 1) {
                    s_activeRouters[i] = s_activeRouters[s_activeRouters.length - 1];
                }
                s_activeRouters.pop();
                break;
            }
        }
        if (!routerFound) revert ROUTER_NOT_FOUND();
        emit RouterDeactivated(_router);
    }

    // checks for valid wad input
    function _enforceWAD(uint256 _amount) private pure {
        if (_amount < 1e15 || _amount > 1e30) {
            revert INPUT_MUST_BE_IN_WAD_UNITS();
        }
    }

    // returns fees collected for token
    function getCollectedFees(address _token) external view returns (uint256 amount) {
        return s_feesCollected[_token];
    }

    // returns all routers
    function getAllRouters() external view returns (address[] memory routers) {
        return s_routers;
    }

    // returns factory owner
    function getFactoryOwner() external view returns (address owner) {
        return i_factoryOwner;
    }

    // returns current router fee percentage
    function getRouterFeePercentage() external view returns (uint256 feePercentage) {
        return s_routerFeePercentage;
    }

    // returns factory address
    function getFactoryAddress() external view returns (address factory) {
        return address(this);
    }

    // returns if token is permitted
    function isTokenPermitted(address _token) external view returns (bool isPermitted) {
        return s_permittedTokens[_token];
    }
}
