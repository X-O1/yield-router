// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockAUSDC} from "../../test/mocks/MockAUSDC.sol";
import {MockUSDC} from "../../test/mocks/MockUSDC.sol";
import {MockPool} from "../../test/mocks/MockPool.sol";
import {RouterFactoryController} from "../../contracts/RouterFactoryController.sol";
import {RouterFactory} from "../../contracts/RouterFactory.sol";
import {Router} from "../../contracts/Router.sol";
import {Script} from "forge-std/Script.sol";

contract DeployRouterAndDependencies is Script {
    function run() external returns (Router) {
        vm.startBroadcast();
        MockAUSDC ausdc = new MockAUSDC();
        MockUSDC usdc = new MockUSDC();
        MockPool pool = new MockPool(address(ausdc), address(usdc));
        RouterFactoryController controller = new RouterFactoryController(pool.getPool(), 1e15);
        RouterFactory factory = controller.createRouterFactory(address(ausdc), address(usdc));
        Router router = factory.createRouter();
        vm.stopBroadcast();

        return router;
    }
}
