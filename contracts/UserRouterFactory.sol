// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {UserRouter} from "./UserRouter.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./GlobalErrors.sol";

/**
 * @title UserRouterFactory
 * @notice deploys minimal proxy Router contracts for users to route yield from permitted tokens
 * each user gets their own factory. A single user can launch as many routers as they want from factory with no router fee and activate all from factory
 * or a protocol can have one factory for all their users and collect fees from their users routing yield.
 *
 */
contract UserRouterFactory {
    // ======================= State Variables =======================

    // aave v3 pool instance
    IPool private s_aaveV3Pool;
    // aave address provider
    IPoolAddressesProvider private s_addressesProvider;
    // logic contract address used for cloning Router instances
    address private s_implementation;
    // flag to prevent re-initialization
    bool private s_initialized;
    // factory controller address
    address private s_factoryControllerAddress;
    // factory controller owner
    address private s_factoryControllerOwner;
    // flag to ensure factory controller owner can only be set once
    bool private s_factoryControllerOwnerSet;
    // owner of this factory
    address private s_factoryOwner;
    // flag to ensure factory owner can only be set once
    bool private s_factoryOwnerSet;
    // yield-bearing token address (e.g., aUSDC)
    address private s_yieldBarringToken;
    // principal token address (e.g., USDC)
    address private s_principalToken;
    // all routers deployed by this factory
    address[] public s_routers;
    // active routers ready for routing
    address[] public s_activeRouters;
    // all routers created by this factory
    mapping(address router => bool isPermitted) private s_permittedRouter;

    // ======================= Events =======================

    event Active_Routers_Activated(uint256 numberOfRouters);
    event Router_Created(address indexed router, address indexed owner, address yieldToken, address principalToken);
    event Router_Activated(address indexed router);
    event Router_Deactivated(address indexed router);
    event Fees_Withdrawn(address indexed recipient, address indexed token, uint256 amount);
    event Yield_Routed(address indexed router);
    event Router_Reverted(address indexed router);

    // ======================= Initialization =======================

    // initializes the fractory with aave provider, starting fee percentage and token settings
    function initialize(
        address _addressProvider,
        address _factoryController,
        address _factoryOwner,
        address _yieldBarringToken,
        address _principalToken
    ) external {
        if (s_initialized) revert ALREADY_INITIALIZED();
        s_initialized = true;

        s_implementation = address(new UserRouter());
        s_addressesProvider = IPoolAddressesProvider(_addressProvider);
        s_aaveV3Pool = IPool(s_addressesProvider.getPool());
        s_factoryControllerAddress = _factoryController;
        s_factoryOwner = _factoryOwner;
        s_yieldBarringToken = _yieldBarringToken;
        s_principalToken = _principalToken;
    }

    // sets the factory owner (only once)
    function setFactoryOwner(address _factoryOwner) external returns (address) {
        if (s_factoryOwnerSet) revert ALREADY_SET();
        s_factoryOwnerSet = true;
        s_factoryOwner = _factoryOwner;
        return s_factoryOwner;
    }

    // sets the factory controller owner (only once)
    function setFactoryControllerOwner(address _owner) external returns (address) {
        if (s_factoryControllerOwnerSet) revert ALREADY_SET();
        s_factoryControllerOwnerSet = true;
        s_factoryControllerOwner = _owner;
        return s_factoryControllerOwner;
    }

    // ======================= Modifiers =======================

    // restricts function to factory owner
    modifier onlyOwner() {
        if (msg.sender != s_factoryOwner) revert NOT_OWNER();
        _;
    }

    // restricts function to only routers deployed by this factory
    modifier onlyRouter() {
        if (!s_permittedRouter[msg.sender]) revert NOT_ROUTER();
        _;
    }

    // ======================= Router Control =======================

    /// @notice deploys a new Router instance
    /// @return router the deployed Router instance
    function createRouter() external returns (UserRouter) {
        address clone = Clones.clone(s_implementation);
        UserRouter router = UserRouter(clone);

        router.initialize(address(this), address(router), address(s_addressesProvider), s_yieldBarringToken, s_principalToken);
        router.setOwner(s_factoryOwner);
        s_routers.push(address(router));
        s_permittedRouter[address(router)] = true;
        emit Router_Created(address(router), s_factoryOwner, s_yieldBarringToken, s_principalToken);
        return (router);
    }

    // activates all routers marked active
    // use time-based chainlink automation to call this
    function activateActiveRouters() external {
        if (s_activeRouters.length == 0) revert NO_ACTIVE_ROUTERS();

        for (uint256 i = 0; i < s_activeRouters.length; i++) {
            address routerAddress = UserRouter(s_activeRouters[i]).getAddress();
            UserRouter router = UserRouter(routerAddress);
            try router.routeYield() {
                emit Yield_Routed(routerAddress);
            } catch {
                emit Router_Reverted(routerAddress);
            }
        }

        emit Active_Routers_Activated(s_activeRouters.length);
    }

    // ======================= External Router Functions =======================

    // adds router to active list
    function addToActiveRouterList(address _router) external onlyRouter {
        s_activeRouters.push(_router);
        emit Router_Activated(_router);
    }

    // removes router from active list
    function removeFromActiveRouterList(address _router) external onlyRouter {
        if (s_activeRouters.length == 0) revert NO_ACTIVE_ROUTERS();
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

    // returns all routers
    function getAllRouters() external view returns (address[] memory) {
        return s_routers;
    }

    // returns all routers
    function getActiveRouters() external view returns (address[] memory) {
        return s_activeRouters;
    }

    // returns factory owner
    function getFactoryOwner() external view returns (address owner) {
        return s_factoryOwner;
    }

    // returns factory controller owner
    function getFactoryControllerOwner() external view returns (address factory) {
        return s_factoryControllerOwner;
    }

    // returns factory controller
    function getFactoryControllerAddress() external view returns (address factory) {
        return s_factoryControllerAddress;
    }

    // returns factory address
    function getFactoryAddress() external view returns (address factory) {
        return address(this);
    }
}
