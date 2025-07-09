// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {UserRouter} from "./UserRouter.sol";
import {UserRouterFactory} from "./UserRouterFactory.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./GlobalErrors.sol";

contract UserFactoryController {
    // aave v3 pool instance
    IPool private s_aaveV3Pool;
    // aave address provider
    IPoolAddressesProvider private s_addressesProvider;
    // logic contract address used for cloning factory instances
    address private s_implementation;
    // owner of this factory controller
    address private s_factoryControllerOwner;
    // flag to prevent re-initialization
    bool private s_initialized;
    // all factories deployed by this controller
    address[] public s_factories;

    // factories created by this controller
    mapping(address router => bool isPermitted) private s_permittedFactory;

    event User_Router_Factory_Created(address indexed factory, address indexed owner, address yieldToken, address principalToken);

    constructor(address _addressProvider) {
        s_implementation = address(new UserRouterFactory());
        s_addressesProvider = IPoolAddressesProvider(_addressProvider);
        s_factoryControllerOwner = msg.sender;
    }

    function createUserRouterFactory(
        address _factoryOwner,
        address _yieldBarringToken,
        address _principalToken
    ) external returns (UserRouterFactory) {
        address clone = Clones.clone(s_implementation);
        UserRouterFactory factory = UserRouterFactory(clone);

        factory.initialize(address(s_addressesProvider), address(this), _factoryOwner, _yieldBarringToken, _principalToken);
        factory.setFactoryOwner(_factoryOwner);
        s_factories.push(address(factory));
        s_permittedFactory[address(factory)] = true;

        emit User_Router_Factory_Created(address(factory), _factoryOwner, _yieldBarringToken, _principalToken);
        return (factory);
    }
}
