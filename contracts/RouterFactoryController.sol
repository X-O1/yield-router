// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {Router} from "./Router.sol";
import {RouterFactory} from "./RouterFactory.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./GlobalErrors.sol";

contract RouterFactoryController {
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
    // fee taken from routed yield (wad format, e.g. 1e15 = 0.1%)
    uint256 private s_routerFeePercentage;

    // factories created by this controller
    mapping(address router => bool isPermitted) private s_permittedFactory;
    // accumulated fees per token
    mapping(address token => uint256 amount) public s_feesCollected;

    event Router_Factory_Created(address indexed factory, address indexed owner, address yieldToken, address principalToken);
    event Router_Fee_Percentage_Updated(uint256 newFeePercentage);
    event Fees_Withdrawn(address indexed recipient, address indexed token, uint256 amount);

    constructor(address _addressProvider, uint256 _startingRouterFeePercentage) {
        s_implementation = address(new RouterFactory());
        s_addressesProvider = IPoolAddressesProvider(_addressProvider);
        s_factoryControllerOwner = msg.sender;
        s_routerFeePercentage = _startingRouterFeePercentage;
    }

    // restricts function to factory owner
    modifier onlyOwner() {
        if (msg.sender != s_factoryControllerOwner) revert NOT_OWNER();
        _;
    }
    // restricts function to only routers deployed by this factory
    modifier onlyFactory() {
        if (!s_permittedFactory[msg.sender]) revert NOT_FACTORY();
        _;
    }

    function createUserRouterFactory(address _factoryOwner, address _yieldBarringToken, address _principalToken) external returns (RouterFactory) {
        address clone = Clones.clone(s_implementation);
        RouterFactory factory = RouterFactory(clone);

        factory.initialize(address(s_addressesProvider), address(this), _factoryOwner, _yieldBarringToken, _principalToken);
        factory.setFactoryOwner(_factoryOwner);
        s_factories.push(address(factory));
        s_permittedFactory[address(factory)] = true;

        emit Router_Factory_Created(address(factory), _factoryOwner, _yieldBarringToken, _principalToken);
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

    // updates router fee percentage
    function setRouterFeePercentage(uint256 _routerFeePercentage) external onlyOwner {
        _enforceWAD(_routerFeePercentage);
        s_routerFeePercentage = _routerFeePercentage;
        emit Router_Fee_Percentage_Updated(_routerFeePercentage);
    }

    // adds fees collected by routers
    function addFees(address _token, uint256 _amount) external onlyFactory {
        s_feesCollected[_token] += _amount;
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

    // returns current router fee percentage
    function getRouterFeePercentage() external view returns (uint256 feePercentage) {
        return s_routerFeePercentage;
    }
}
