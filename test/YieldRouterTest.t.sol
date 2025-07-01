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
    uint256 WAD = 1e18;

    function setUp() external {
        usdc = new MockUSDC();
        usdc.mint(dev, 1000 * WAD);
        usdc.mint(user, 1000 * WAD);
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

        vm.prank(user);
        usdc.approve(address(mockPool), type(uint256).max);
        vm.prank(user);
        mockPool.supply(usdcAddress, 1000 * WAD, user, 0);

        vm.prank(user);
        yieldRouter = yieldRouterFactory.createYieldRouter(aUSDCAddress, usdcAddress);

        vm.prank(user);
        aUSDC.approve(address(yieldRouter), type(uint256).max);
    }

    function testDeposit() public {
        vm.prank(user);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        assertEq(yieldRouter.getAccountDepositPrincipal(), 1000 * RAY);
        assertEq(yieldRouter.getAccountIndexAdjustedBalance(), 1000 * RAY);
    }

    function testNotOwnerDeposit() public {
        vm.expectRevert();
        vm.prank(dev);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
    }

    function testWithdraw() public {
        vm.prank(user);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        vm.prank(user);
        yieldRouter.withdraw(500 * WAD);
        assertEq(yieldRouter.getAccountIndexAdjustedBalance(), 500 * RAY);
    }

    function testWithdraAfterIndexChange() public {
        vm.prank(user);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        vm.prank(user);
        mockPool.setLiquidityIndex(2e27);

        vm.prank(user);
        yieldRouter.withdraw(1000 * WAD);

        assertEq(yieldRouter.getAccountIndexAdjustedBalance(), 500 * RAY);
        assertEq(aUSDC.balanceOf(user), 500 * WAD);
    }

    function testManagingYieldAccess() public {
        vm.prank(user);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        vm.prank(user);
        yieldRouter.manageYieldAccess(dev, true);
        assertEq(yieldRouter.isAddressPermittedForYieldAccess(dev), true);

        vm.prank(user);
        yieldRouter.manageYieldAccess(dev, false);
        assertEq(yieldRouter.isAddressPermittedForYieldAccess(dev), false);

        vm.expectRevert();
        vm.prank(dev);
        yieldRouter.manageYieldAccess(dev, true);
        assertEq(yieldRouter.isAddressPermittedForYieldAccess(dev), false);
    }

    function testYieldRouting() public {
        vm.prank(user);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        vm.prank(user);
        yieldRouter.manageYieldAccess(dev, true);

        vm.prank(user);
        mockPool.setLiquidityIndex(2e27);
        assertEq(yieldRouter.getAccountIndexAdjustedYield(), 500 * RAY);

        vm.prank(dev);
        yieldRouter.routeYield(dev, 500 * WAD);
        assertEq(aUSDC.balanceOf(dev), 250 * WAD);
        assertEq(yieldRouter.getAccountIndexAdjustedYield(), 250 * RAY);
        assertEq(yieldRouter.getAccountIndexAdjustedBalance(), 750 * RAY);

        vm.prank(user);
        yieldRouter.routeYield(user, 500 * WAD);
        assertEq(aUSDC.balanceOf(user), 250 * WAD);
        assertEq(yieldRouter.getAccountIndexAdjustedYield(), 0 * RAY);
        assertEq(yieldRouter.getAccountIndexAdjustedBalance(), 500 * RAY);
    }
}
