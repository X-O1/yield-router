// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {RouterFactory} from "./RouterFactory.sol";
import {Router} from "./Router.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./GlobalErrors.sol";

contract RouterFactoryController {
    // ======================= Immutable Variables =======================

    // aave address provider
    IPoolAddressesProvider private immutable i_addressesProvider;
    // owner of this factory controller
    address private immutable i_factoryControllerOwner;

    // ======================= State Variables =======================

    // logic contract address used for cloning factory instances
    address private s_implementation;
    // all factories deployed by this controller
    FactoryDetails[] private s_factories;
    // factories deployed by this controller
    mapping(address factory => bool isPermitted) private s_permittedFactory;
    // routers deployed by factories deployed by this controller
    mapping(address router => bool isPermitted) private s_permittedRouter;
    // accumulated fees per token
    mapping(address token => uint256 amount) public s_feesCollected;

    // ======================= Structs =======================

    struct FactoryDetails {
        address factoryAddress;
        address yieldBarringTokenAddress;
        address principalTokenAddress;
    }

    // ======================= Events =======================

    event Router_Factory_Created(address indexed factory, address yieldToken, address principalToken);
    event Fees_Withdrawn(address indexed recipient, address indexed token, uint256 amount);
    event Yield_Routed(address indexed router);
    event Router_Reverted(address indexed router);
    event Active_Routers_Activated(uint256 numberOfRouters);

    // ======================= Constructor =======================

    constructor(address _addressProvider) {
        s_implementation = address(new RouterFactory());
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_factoryControllerOwner = msg.sender;
    }

    // ======================= Modifiers =======================

    // restricts function to factory owner
    modifier onlyOwner() {
        if (msg.sender != i_factoryControllerOwner) revert NOT_OWNER();
        _;
    }
    // restricts function to only routers deployed by this factory
    modifier onlyFactory() {
        if (!s_permittedFactory[msg.sender]) revert NOT_FACTORY();
        _;
    }
    // restricts function to only routers deployed by this factory
    modifier onlyRouter() {
        if (!s_permittedRouter[msg.sender]) revert NOT_ROUTER();
        _;
    }

    // ======================= Factory Control =======================

    function createRouterFactory(
        address _yieldBarringToken,
        address _principalToken,
        uint256 _startingRouterFeePercentage
    ) external returns (RouterFactory) {
        address clone = Clones.clone(s_implementation);
        RouterFactory factory = RouterFactory(clone);

        factory.initialize(address(i_addressesProvider), address(this), _yieldBarringToken, _principalToken, _startingRouterFeePercentage);
        s_permittedFactory[address(factory)] = true;
        s_factories.push(
            FactoryDetails({factoryAddress: address(factory), yieldBarringTokenAddress: _yieldBarringToken, principalTokenAddress: _principalToken})
        );

        emit Router_Factory_Created(address(factory), _yieldBarringToken, _principalToken);
        return (factory);
    }

    // withdraw fees
    function withdrawFees(address _token, uint256 _amount) external onlyOwner returns (uint256) {
        if (s_feesCollected[_token] < _amount) revert INSUFFICIENT_BALANCE();

        s_feesCollected[_token] -= _amount;
        if (!IERC20(_token).transfer(msg.sender, _amount)) revert WITHDRAW_FAILED();

        emit Fees_Withdrawn(msg.sender, _token, _amount);
        return _amount;
    }

    // triggers all factories to route all yield from all active routers (chainlink automation recommended. if so remove onlyOwner)
    function triggerYieldRouting() external onlyOwner {
        if (s_factories.length == 0) revert NO_FACTORIES();

        for (uint256 i = 0; i < s_factories.length; i++) {
            address factoryAddress = RouterFactory(s_factories[i].factoryAddress).getFactoryAddress();
            RouterFactory factory = RouterFactory(factoryAddress);
            try factory.activateActiveRouters() {
                emit Yield_Routed(factoryAddress);
            } catch {
                emit Router_Reverted(factoryAddress);
            }
        }

        emit Active_Routers_Activated(s_factories.length);
    }

    // ======================= External Factory & Router Functions =======================

    // adds fees collected by routers
    function addFees(address _token, uint256 _amount) external onlyRouter {
        s_feesCollected[_token] += _amount;
    }

    // stores addresses of the routers deployed by factories deployed by this controller
    function addRouter(address _address) external onlyFactory {
        s_permittedRouter[_address] = true;
    }

    // ======================= View Functions =======================

    // returns fees collected for token
    function getCollectedFees(address _token) external view returns (uint256) {
        return s_feesCollected[_token];
    }

    // returns this factory controller address
    function getFactoryControllerAddress() external view returns (address) {
        return address(this);
    }

    // return all factories created by this controller
    function getFactories() external view returns (FactoryDetails[] memory) {
        return s_factories;
    }
}
