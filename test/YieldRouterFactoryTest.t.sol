// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldRouter} from "../contracts/YieldRouter.sol";
import {YieldRouterFactory} from "../contracts/YieldRouterFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

contract YieldRouterTest is Test {
    YieldRouter yieldRouter;
    YieldRouterFactory yieldRouterFactory;
    address yieldRouterAddress;
    MockPool mockPool;
    address addressProvider;
    MockUSDC usdc;
    MockAUSDC aUSDC;
    address usdcAddress;
    address aUSDCAddress;
    address dev = makeAddr("dev");
    address user = makeAddr("user");
    uint256 RAY = 1e27;

    function setUp() external {
        usdc = new MockUSDC();
        usdc.mint(dev, 1000);
        usdc.mint(user, 1000);
        usdcAddress = usdc.getAddress();
        aUSDC = new MockAUSDC();
        aUSDCAddress = aUSDC.getAddress();
        mockPool = new MockPool(usdcAddress, aUSDCAddress);
        addressProvider = mockPool.getPool();
        vm.startPrank(dev);
        yieldRouterFactory = new YieldRouterFactory(addressProvider);
        yieldRouterFactory.permitTokensForFactory(usdcAddress, true);
        yieldRouterFactory.permitTokensForFactory(aUSDCAddress, true);
        vm.stopPrank();
    }

    function testFactoryRouterCreationAndOwnerBeingSet() public {
        vm.prank(user);
        yieldRouter = yieldRouterFactory.createYieldRouter(user, aUSDCAddress, usdcAddress);
        assertEq(yieldRouter.getRouterOwner(), user);
    }

    function testFactoryPermittedTokens() public {
        vm.prank(user);
        vm.expectRevert();
        yieldRouterFactory.createYieldRouter(makeAddr("fakeAdd3"), makeAddr("fakeAdd"), makeAddr("fakeAdd2"));
    }

    function testFactoryOwner() public {
        vm.prank(user);
        assertEq(yieldRouterFactory.getFactoryOwner(), dev);
    }

    function testNotOwnerAddingPermittedTokensToFactory() public {
        vm.prank(user);
        vm.expectRevert();
        yieldRouterFactory.permitTokensForFactory(makeAddr("fakeAdd"), true);
    }
}
