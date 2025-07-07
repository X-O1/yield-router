// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Router} from "../contracts/Router.sol";
import {RouterFactory} from "../contracts/RouterFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

contract RouterFactoryTest is Test {
    // Router router;
    // RouterFactory routerFactory;
    // MockPool mockPool;
    // address addressProvider;
    // MockUSDC usdc;
    // MockAUSDC aUSDC;
    // address usdcAddress;
    // address aUSDCAddress;
    // address dev = makeAddr("dev");
    // address user = makeAddr("user");
    // uint256 RAY = 1e27;
    // function setUp() external {
    //     usdc = new MockUSDC();
    //     usdc.mint(dev, 1000);
    //     usdc.mint(user, 1000);
    //     usdcAddress = usdc.getAddress();
    //     aUSDC = new MockAUSDC();
    //     aUSDCAddress = aUSDC.getAddress();
    //     mockPool = new MockPool(usdcAddress, aUSDCAddress);
    //     addressProvider = mockPool.getPool();
    //     vm.startPrank(dev);
    //     routerFactory = new RouterFactory(addressProvider);
    //     routerFactory.permitTokensForFactory(usdcAddress, true);
    //     routerFactory.permitTokensForFactory(aUSDCAddress, true);
    //     vm.stopPrank();
    // }
    // function testFactoryRouterCreationAndOwnerBeingSet() public {
    //     vm.prank(user);
    //     router = routerFactory.createRouter(user, aUSDCAddress, usdcAddress);
    //     assertEq(router.getRouterOwner(), user);
    // }
    // function testFactoryPermittedTokens() public {
    //     vm.prank(user);
    //     vm.expectRevert();
    //     routerFactory.createRouter(makeAddr("fakeAdd3"), makeAddr("fakeAdd"), makeAddr("fakeAdd2"));
    // }
    // function testFactoryOwner() public {
    //     vm.prank(user);
    //     assertEq(routerFactory.getFactoryOwner(), dev);
    // }
    // function testNotOwnerAddingPermittedTokensToFactory() public {
    //     vm.prank(user);
    //     vm.expectRevert();
    //     routerFactory.permitTokensForFactory(makeAddr("fakeAdd"), true);
    // }
}
