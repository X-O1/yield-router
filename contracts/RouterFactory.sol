// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {Router} from "./Router.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./RouterErrors.sol";

/**
 * @title RouterFactory
 * @notice deploys minimal proxy Router contracts for users to route yield from permitted tokens
 * each user gets their own factory. A single user can launch as many routers as they want from factory with no router fee and activate all from factory
 * or a protocol can have one factory for all their users and collect fees from their users routing yield.
 *
 */
contract RouterFactory {
    // ======================= Immutable Variables =======================

    // aave v3 pool instance
    IPool private immutable i_aaveV3Pool;
    // aave address provider
    IPoolAddressesProvider private immutable i_addressesProvider;
    // logic contract address used for cloning Router instances
    address private immutable i_implementation;
    // owner of this factory
    address private immutable i_factoryOwner;

    // ======================= State Variables =======================

    // all routers deployed by this factory
    address[] public s_routers;
    // active routers ready for routing
    address[] public s_activeRouters;
    // fee taken from routed yield (wad format, e.g. 1e15 = 0.1%)
    uint256 private s_routerFeePercentage;
    // permitted tokens
    mapping(address token => bool isPermitted) private s_permittedTokens;
    // all routers created by this factory
    mapping(address router => bool isPermitted) private s_permittedRouter;
    // accumulated fees per token
    mapping(address token => uint256 amount) public s_feesCollected;

    // ======================= Events =======================

    event Token_Permission_Updated(address indexed token, bool isPermitted);
    event Router_Fee_Percentage_Updated(uint256 newFeePercentage);
    event Active_Routers_Activated(uint256 numberOfRouters);
    event Router_Created(address indexed router, address indexed owner, address yieldToken, address principalToken);
    event Router_Activated(address indexed router);
    event Router_Deactivated(address indexed router);
    event Fees_Withdrawn(address indexed recipient, address indexed token, uint256 amount);
    event Yield_Routed(address indexed router);
    event Router_Reverted(address indexed router);

    // ======================= Constructor =======================

    // constructor initializes factory
    constructor(address _addressProvider, uint256 _startingRouterFeePercentage) {
        i_implementation = address(new Router());
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_aaveV3Pool = IPool(i_addressesProvider.getPool());
        i_factoryOwner = msg.sender;
        s_routerFeePercentage = _startingRouterFeePercentage;
    }

    // ======================= Modifiers =======================

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

    // ======================= Factory Control =======================

    // withdraw fees
    function withdrawFees(address _token, uint256 _amount) external onlyOwner returns (uint256) {
        if (s_feesCollected[_token] < _amount) revert INSUFFICIENT_BALANCE();

        s_feesCollected[_token] -= _amount;
        if (!IERC20(_token).transfer(msg.sender, _amount)) revert WITHDRAW_FAILED();

        emit Fees_Withdrawn(msg.sender, _token, _amount);
        return _amount;
    }

    // permits or revokes a token
    function permitTokensForRouters(address _token, bool _isPermitted) external onlyOwner {
        _isPermitted ? s_permittedTokens[_token] = true : s_permittedTokens[_token] = false;
        emit Token_Permission_Updated(_token, _isPermitted);
    }

    // updates router fee percentage
    function setRouterFeePercentage(uint256 _routerFeePercentage) external onlyOwner {
        _enforceWAD(_routerFeePercentage);
        s_routerFeePercentage = _routerFeePercentage;
        emit Router_Fee_Percentage_Updated(_routerFeePercentage);
    }

    // ======================= Router Control =======================

    /// @notice deploys a new Router instance
    /// @param _routerOwner the address that will control the router.
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
        emit Router_Created(address(router), _routerOwner, _yieldBarringToken, _principalToken);
        return (router);
    }

    // activates all routers marked active
    // use time-based chainlink automation to call this
    function activateActiveRouters() external {
        if (s_activeRouters.length == 0) revert NO_ACTIVE_ROUTERS();

        for (uint256 i = 0; i < s_activeRouters.length; i++) {
            try Router(s_activeRouters[i]).routeYield() {
                emit Yield_Routed(s_activeRouters[i]);
            } catch {
                emit Router_Reverted(s_activeRouters[i]);
            }
        }

        emit Active_Routers_Activated(s_activeRouters.length);
    }

    // ======================= External Router Functions =======================

    // adds fees collected by routers
    function addFees(address _token, uint256 _amount) external onlyRouter {
        s_feesCollected[_token] += _amount;
    }

    // adds router to active list
    function addToActiveRouterList(address _router) external onlyRouter {
        s_activeRouters.push(_router);
        emit Router_Activated(_router);
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
        emit Router_Deactivated(_router);
    }

    // ======================= Private Helpers =======================

    // checks for valid wad input
    function _enforceWAD(uint256 _amount) private pure {
        if (_amount < 1e15 || _amount > 1e30) {
            revert INPUT_MUST_BE_IN_WAD_UNITS();
        }
    }

    // ======================= View Functions =======================

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
