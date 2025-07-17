// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RouterFactoryController} from "../contracts/RouterFactoryController.sol";
import {RouterFactory} from "../contracts/RouterFactory.sol";
import {Router} from "../contracts/Router.sol";

import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

contract RouterTest is Test {
    // yield router instance under test
    Router router;
    // factory used to deploy yield routers
    RouterFactory routerFactory;
    // factory controller to deploy factories
    RouterFactoryController factoryController;
    // factory controller address
    address factoryControllerAddress;
    // mock Aave-style pool to simulate yield accrual
    MockPool mockPool;
    // address provider returned by mock pool
    address addressProvider;
    // mock USDC token (ERC20)
    MockUSDC usdc;
    // mock aUSDC token (yield-bearing token from mockPool)
    MockAUSDC aUSDC;
    // cached address of USDC token
    address usdcAddress;
    // cached address of aUSDC token
    address aUSDCAddress;
    // test address representing the yield router factory owner
    address factoryControllerOwner = makeAddr("factoryControllerOwner");
    // test address representing the yield router factory owner
    address owner = makeAddr("factoryOwner");
    // address of router factory
    address factoryAddress;
    // external test address that is not the router owner
    address user = makeAddr("user");
    // ray unit (1e27), used for internal precision and liquidity index math
    uint256 RAY = 1e27;
    // wad unit (1e18), standard ERC20 decimal precision
    uint256 WAD = 1e18;

    function setUp() external {
        // deploy mock USDC and mint 1000 WAD to dev and owner
        usdc = new MockUSDC();
        usdc.mint(user, 1000e6);
        usdc.mint(owner, 1000e6);
        usdcAddress = usdc.getAddress();

        // deploy mock aUSDC and get its address
        aUSDC = new MockAUSDC();
        aUSDC.mint(owner, 1000e6);
        aUSDCAddress = aUSDC.getAddress();

        // deploy mock pool with USDC and aUSDC addresses
        mockPool = new MockPool(aUSDCAddress, usdcAddress);
        addressProvider = mockPool.getPool();
        usdc.mint(address(mockPool), 10000e6);

        // deploy factory controller
        vm.startPrank(factoryControllerOwner);
        factoryController = new RouterFactoryController(addressProvider);
        factoryControllerAddress = factoryController.getFactoryControllerAddress();
        vm.stopPrank();

        // controller deploys factory
        vm.startPrank(factoryControllerAddress);
        routerFactory = factoryController.createRouterFactory(aUSDCAddress, usdcAddress, 1e3);
        factoryAddress = routerFactory.getFactoryAddress();
        vm.stopPrank();

        // owner approves mock pool to spend USDC
        vm.prank(owner);
        usdc.approve(address(mockPool), type(uint).max);

        // owner supplies 1000 WAD USDC to pool and receives aUSDC
        // vm.prank(owner);
        // mockPool.supply(usdcAddress, 1000e6, owner, 0);

        // owner deploys their own Router via factory
        vm.prank(owner);
        router = routerFactory.createRouter(owner, "Genesis");

        // owner approves Router to spend aUSDC
        vm.prank(owner);
        aUSDC.approve(address(router), type(uint256).max);
    }

    function testDeposit() public {
        // owner deposits 1000  aUSDC into router
        vm.prank(owner);
        console.logUint(router.deposit(1000e6));

        // check principal and index-adjusted balance
        assertEq(router.getOwnerPrincipalBalance(), 1000e6);
        assertEq(router.getOwnerIndexAdjustedBalance(), 1000e6);
    }

    function testNotOwnerDeposit() public {
        // dev (not owner) tries to deposit, should revert
        vm.expectRevert();
        vm.prank(user);
        router.deposit(1000e6);
    }

    function testWithdraw() public {
        // owner deposits into router
        vm.prank(owner);
        router.deposit(1000e6);

        // owner withdraws 500
        vm.prank(owner);
        router.withdraw(500e6);

        // check remaining index-adjusted balance
        assertEq(router.getOwnerIndexAdjustedBalance(), 500e6);
        assertEq(router.getOwnerPrincipalBalance(), 500e6);
        assertEq(usdc.balanceOf(user), 1000e6);
    }

    function testWithdraAfterIndexChange() public {
        // owner deposits into router
        vm.prank(owner);
        router.deposit(1000e6);

        // index increases (simulates yield)
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);

        // owner withdraws full 1000  principal
        vm.prank(owner);
        router.withdraw(500e6);

        // check balance and aUSDC transfer
        assertEq(router.getOwnerIndexAdjustedBalance(), 750e6);
    }

    function testManagingYieldAccess() public {
        // owner deposits
        vm.prank(owner);
        router.deposit(100e6);

        // owner grants access to dev
        vm.prank(owner);
        router.manageRouterAccess(user, true, 100e6);
        assertEq(router.isAddressGrantedRouterAccess(user), true);

        // owner revokes access
        vm.prank(owner);
        router.manageRouterAccess(user, false, 0);
        assertEq(router.isAddressGrantedRouterAccess(user), false);

        // dev tries to re-enable access (should revert)
        vm.expectRevert();
        vm.prank(user);
        router.manageRouterAccess(user, true, 100e6);
        assertEq(router.isAddressGrantedRouterAccess(user), false);
    }

    function testRouterWhenYieldCoversAllowance() public {
        // owner deposits
        vm.prank(owner);
        router.deposit(1000e6);

        // index increases (yield added)
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);

        // owner grants access to dev and sets 500 allowance
        vm.prank(owner);
        router.manageRouterAccess(user, true, 500e6);

        // owner activates router and sets destination address signaling to factory value is ready to be routed
        vm.prank(owner);
        router.activateRouter(user);

        // triggers all factories to route all yield from all active routers
        vm.prank(factoryAddress);
        console.logUint(router.routeYield());

        // // triggers all factories to route all yield from all active routers
        // vm.prank(factoryControllerOwner);
        // factoryController.triggerYieldRouting();

        // check post-payout balances
        assertEq(router.getOwnerIndexAdjustedBalance(), 750e6);
        assertEq(router.getOwnerYield(), 500e6);
        assertEq(router.getYieldAllowance(user), 0);
        assertEq(usdc.balanceOf(user), 14995e5);
        assertEq(usdc.balanceOf(factoryControllerAddress), 5e5);

        //     // router is now inactive and cleared
        assertEq(router.getRouterIsActive(), false);
        assertEq(router.getRouterCurrentDestination(), address(0));
    }

    function testRouterWhenYieldDoesNottCoverAllowance() public {
        // owner deposits
        vm.prank(owner);
        router.deposit(1000e6);

        // index increases (not enough yield yet)
        vm.prank(owner);
        mockPool.setLiquidityIndex(12e26);

        // owner grants access to dev and sets 450 WAD allowance
        vm.prank(owner);
        router.manageRouterAccess(user, true, 450e6);

        // owner activates router and sets destination address signaling to factory value is ready to be routed
        vm.prank(owner);
        router.activateRouter(user);

        // triggers all factories to route all yield from all active routers
        vm.prank(factoryControllerOwner);
        factoryController.triggerYieldRouting();

        // check balances after first partial payout
        assertEq(router.getOwnerIndexAdjustedBalance(), 833333334);
        assertEq(router.getOwnerPrincipalBalance(), 1000e6);
        assertEq(router.getYieldAllowance(user), 250e6);

        // router still active waiting to pay rest
        assertEq(router.getRouterIsActive(), true);
        assertEq(router.getRouterCurrentDestination(), address(user));

        // index increases again (now enough yield)
        vm.prank(owner);
        mockPool.setLiquidityIndex(15e26);

        // triggers all factories to route all yield from all active routers
        vm.prank(factoryControllerOwner);
        factoryController.triggerYieldRouting();

        // check final balances
        assertEq(router.getOwnerIndexAdjustedBalance(), 666666668);
        assertEq(router.getOwnerPrincipalBalance(), 1000e6);
        assertEq(router.getOwnerYield(), 1);
        assertEq(router.getYieldAllowance(user), 0);

        // router deactivates automatically
        assertEq(router.getRouterIsActive(), false);
        assertEq(router.getRouterCurrentDestination(), address(0));
    }
}
