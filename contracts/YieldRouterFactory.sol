// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {YieldRouter} from "./YieldRouter.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import "./YieldRouterErrors.sol";

/**
 * @title YieldRouterFactory
 * @notice Deploys vaults for each user to route yield from a specific yield-bearing token
 * @dev Uses OpenZeppelin's ERC-1167 minimal proxy (clone) pattern for efficient vault creation
 * @dev Factory owner uses TokenRegistry to permit which tokens are allowed in yield router contracts
 */
contract YieldRouterFactory {
    IPool private immutable i_aaveV3Pool;
    IPoolAddressesProvider private immutable i_addressesProvider;
    address private immutable i_implementation;
    address private i_factoryOwner;
    address[] public s_yieldRouters;

    mapping(address token => bool isPermitted) private s_permittedTokens;

    constructor(address _addressProvider) {
        i_implementation = address(new YieldRouter());
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

    function createYieldRouter(address _yieldBarringToken, address _principalToken) external returns (YieldRouter) {
        if (!s_permittedTokens[_yieldBarringToken]) revert TOKEN_NOT_PERMITTED();
        if (!s_permittedTokens[_principalToken]) revert TOKEN_NOT_PERMITTED();

        address routerOwner = msg.sender;
        address clone = Clones.clone(i_implementation);
        YieldRouter yieldRouter = YieldRouter(clone);
        yieldRouter.initialize(address(i_addressesProvider), _yieldBarringToken, _principalToken);
        yieldRouter.setOwner(routerOwner);
        s_yieldRouters.push(address(yieldRouter));

        return (yieldRouter);
    }

    function getAllYieldRouters() external view returns (address[] memory) {
        return s_yieldRouters;
    }

    function getFactoryOwner() external view returns (address) {
        return i_factoryOwner;
    }
}
