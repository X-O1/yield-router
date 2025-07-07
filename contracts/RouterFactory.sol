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
 * @notice Deploys vaults for each user to route yield from a specific yield-bearing token
 * @dev Uses OpenZeppelin's ERC-1167 minimal proxy (clone) pattern for efficient vault creation
 * @dev Factory owner uses TokenRegistry to permit which tokens are allowed in yield router contracts
 * @dev inputs are expected to be in WAD (1e18)
 * // For protocol each protocol can get their own factory so all user vault are originated from their protocol
 */
contract RouterFactory {
    IPool private immutable i_aaveV3Pool;
    IPoolAddressesProvider private immutable i_addressesProvider;
    address private immutable i_implementation;
    address private immutable i_factoryOwner;
    address[] public s_routers;
    address[] public s_activeRouters;
    uint256 private s_routerFeePercentage;

    mapping(address token => bool isPermitted) private s_permittedTokens;
    mapping(address router => bool isPermitted) private s_permittedRouter;

    constructor(address _addressProvider) {
        i_implementation = address(new Router());
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_aaveV3Pool = IPool(i_addressesProvider.getPool());
        i_factoryOwner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != i_factoryOwner) revert NOT_OWNER();
        _;
    }
    modifier onlyRouter() {
        if (!s_permittedRouter[msg.sender]) revert NOT_ROUTER();
        _;
    }

    function permitTokensForFactory(address _token, bool _isPermitted) external onlyOwner {
        _isPermitted ? s_permittedTokens[_token] = true : s_permittedTokens[_token] = false;
    }

    function setRouterFeePercentage(uint256 _routerFeePercentage) external onlyOwner {
        _enforceWAD(_routerFeePercentage);
        s_routerFeePercentage = _routerFeePercentage;
    }

    function createRouter(address _routerOwner, address _yieldBarringToken, address _principalToken) external returns (Router) {
        if (!s_permittedTokens[_yieldBarringToken]) revert TOKEN_NOT_PERMITTED();
        if (!s_permittedTokens[_principalToken]) revert TOKEN_NOT_PERMITTED();

        address clone = Clones.clone(i_implementation);
        Router router = Router(clone);
        uint256 previousRouterIndex = s_routers.length - 1;
        address previousRouter = s_routers[previousRouterIndex];

        router.initialize(address(this), previousRouter, address(i_addressesProvider), _yieldBarringToken, _principalToken);
        router.setOwner(_routerOwner);
        router.setFactoryOwner(i_factoryOwner);
        s_routers.push(address(router));
        s_permittedRouter[address(router)] = true;

        return (router);
    }

    // in theory router fees should cover cost of this call making the factory profitable
    function activateActiveRouters() external onlyOwner {
        for (uint256 i = 0; i < s_activeRouters.length; i++) {
            Router router = Router(s_activeRouters[i]);
            router.activateRouter();
        }
    }

    // reverts if input is not WAD units
    function _enforceWAD(uint256 _amount) private pure {
        if (_amount < 1e15 || _amount > 1e30) {
            revert INPUT_MUST_BE_IN_WAD_UNITS();
        }
    }

    function getAllRouters() external view returns (address[] memory) {
        return s_routers;
    }

    function getFactoryOwner() external view returns (address) {
        return i_factoryOwner;
    }

    function getRouterFeePercentage() external view returns (uint256) {
        return s_routerFeePercentage;
    }

    function isTokenPermitted(address _token) external view returns (bool) {
        return s_permittedTokens[_token];
    }

    function addToActiveRouterList(address _router) external onlyRouter {
        s_routers.push(_router);
    }

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
    }
}
