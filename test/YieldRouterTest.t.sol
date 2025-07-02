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
    address owner = makeAddr("owner");
    uint256 RAY = 1e27;
    uint256 WAD = 1e18;

    function setUp() external {
        usdc = new MockUSDC();
        usdc.mint(dev, 1000 * WAD);
        usdc.mint(owner, 1000 * WAD);
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

        vm.prank(owner);
        usdc.approve(address(mockPool), type(uint).max);

        vm.prank(owner);
        mockPool.supply(usdcAddress, 1000 * WAD, owner, 0);

        vm.prank(owner);
        yieldRouter = yieldRouterFactory.createYieldRouter(aUSDCAddress, usdcAddress);

        vm.prank(owner);
        aUSDC.approve(address(yieldRouter), type(uint256).max);
    }

    modifier routerActivated() {
        // owner deposits
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases adding yield
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);

        // owner grants external address router access and sets max yield allowance
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, true, 100 * WAD);

        // owner sets end destination of router
        vm.prank(owner);
        yieldRouter.setRouterDestination(dev);

        // owner activates router
        vm.prank(owner);
        yieldRouter.activateRouter();
        _;
    }

    function testDeposit() public {
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
        assertEq(yieldRouter.getOwnerPrincipalValue(), 1000 * RAY);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 1000 * RAY);
    }

    function testFuzzDeposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000 * WAD);
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, amount);
        uint256 expectedRay = amount * 1e9;
        assertEq(yieldRouter.getOwnerPrincipalValue(), expectedRay);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), expectedRay);
    }

    function testNotOwnerDeposit() public {
        vm.expectRevert();
        vm.prank(dev);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
    }

    function testWithdraw() public {
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
        vm.prank(owner);
        yieldRouter.withdraw(500 * WAD);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500 * RAY);
    }

    function testWithdraAfterIndexChange() public {
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);
        vm.prank(owner);
        yieldRouter.withdraw(1000 * WAD);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500 * RAY);
        assertEq(aUSDC.balanceOf(owner), 500 * WAD);
    }

    function testManagingYieldAccess() public {
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, true, 100 * WAD);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(dev), true);
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, false, 0);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(dev), false);
        vm.expectRevert();
        vm.prank(dev);
        yieldRouter.manageRouterAccess(dev, true, 100 * WAD);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(dev), false);
    }

    function testActivatingRouter() public {
        // owner deposits
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases adding yield
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);

        // owner grants external address router access and sets max yield allowance
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, true, 2000 * WAD);

        // owner sets end destination of router
        vm.prank(owner);
        yieldRouter.setRouterDestination(dev);

        // owner activates router and sends first yield payment
        vm.prank(owner);
        yieldRouter.activateRouter();

        // assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500e25);
        // assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500e25);
    }
}
