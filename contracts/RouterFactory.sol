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
 */
contract RouterFactory {
    IPool private immutable i_aaveV3Pool;
    IPoolAddressesProvider private immutable i_addressesProvider;
    address private immutable i_implementation;
    address private i_factoryOwner;
    address[] public s_Routers;

    mapping(address token => bool isPermitted) private s_permittedTokens;

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

    function permitTokensForFactory(address _token, bool _isPermitted) external onlyOwner {
        _isPermitted ? s_permittedTokens[_token] = true : s_permittedTokens[_token] = false;
    }

    function createRouter(address _routerOwner, address _yieldBarringToken, address _principalToken) external returns (Router) {
        if (!s_permittedTokens[_yieldBarringToken]) revert TOKEN_NOT_PERMITTED();
        if (!s_permittedTokens[_principalToken]) revert TOKEN_NOT_PERMITTED();

        address clone = Clones.clone(i_implementation);
        Router router = Router(clone);
        uint256 previousRouterIndex = s_Routers.length - 1;
        address previousRouter = s_Routers[previousRouterIndex];

        router.initialize(address(this), previousRouter, address(i_addressesProvider), _yieldBarringToken, _principalToken);
        router.setOwner(_routerOwner);
        router.setFactoryOwner(i_factoryOwner);
        s_Routers.push(address(router));

        return (router);
    }

    // scan through every previous router. check if active. if status is active, activateRouter
    function scanAndActivatePreviousRouters() internal {
        uint256 previousRouterIndex = s_Routers.length - 1;
        address previousRouter = s_Routers[previousRouterIndex];
        Router router = Router(previousRouter);

        bool prevRouterStatus = router.getRouterStatus();
        if (prevRouterStatus) {
            router.activateRouter();
        } else {
            router.scanAndActivatePreviousRouters();
        }
    }

    function getAllRouters() external view returns (address[] memory) {
        return s_Routers;
    }

    function getFactoryOwner() external view returns (address) {
        return i_factoryOwner;
    }
}
