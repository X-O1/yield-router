// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldRouter} from "../contracts/YieldRouter.sol";
import {YieldRouterFactory} from "../contracts/YieldRouterFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

contract YieldRouterTest is Test {
    // yield router instance under test
    YieldRouter yieldRouter;
    // factory used to deploy yield routers
    YieldRouterFactory yieldRouterFactory;
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
    address factoryOwner = makeAddr("factoryOwner");
    // primary test address representing the yield router owner
    address routerOwner = makeAddr("routerOwner");
    // external test address that is not the router owner
    address user = makeAddr("user");
    // ray unit (1e27), used for internal precision and liquidity index math
    uint256 RAY = 1e27;
    // wad unit (1e18), standard ERC20 decimal precision
    uint256 WAD = 1e18;

    function setUp() external {
        // deploy mock USDC and mint 1000 WAD to dev and owner
        usdc = new MockUSDC();
        usdc.mint(user, 1000 * WAD);
        usdc.mint(routerOwner, 1000 * WAD);
        usdcAddress = usdc.getAddress();

        // deploy mock aUSDC and get its address
        aUSDC = new MockAUSDC();
        aUSDCAddress = aUSDC.getAddress();

        // deploy mock pool with USDC and aUSDC addresses
        mockPool = new MockPool(usdcAddress, aUSDCAddress);
        addressProvider = mockPool.getPool();

        // dev deploys factory and permits USDC/aUSDC tokens
        vm.startPrank(factoryOwner);
        yieldRouterFactory = new YieldRouterFactory(addressProvider);
        yieldRouterFactory.permitTokensForFactory(usdcAddress, true);
        yieldRouterFactory.permitTokensForFactory(aUSDCAddress, true);
        vm.stopPrank();

        // owner approves mock pool to spend USDC
        vm.prank(routerOwner);
        usdc.approve(address(mockPool), type(uint).max);

        // owner supplies 1000 WAD USDC to pool and receives aUSDC
        vm.prank(routerOwner);
        mockPool.supply(usdcAddress, 1000 * WAD, routerOwner, 0);

        // owner deploys their own YieldRouter via factory
        vm.prank(routerOwner);
        yieldRouter = yieldRouterFactory.createYieldRouter(routerOwner, aUSDCAddress, usdcAddress);

        // owner approves YieldRouter to spend aUSDC
        vm.prank(routerOwner);
        aUSDC.approve(address(yieldRouter), type(uint256).max);
    }

    function testDeposit() public {
        // owner deposits 1000 WAD aUSDC into router
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // check principal and index-adjusted balance
        assertEq(yieldRouter.getOwnerPrincipalValue(), 1000 * RAY);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 1000 * RAY);
    }

    function testFuzzDeposit(uint256 amount) public {
        // only allow reasonable deposit amounts (1 to 1000 USDC)
        vm.assume(amount > 0 && amount <= 1000 * WAD);

        // owner deposits random fuzzed amount of aUSDC
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, amount);

        // expected value in RAY
        uint256 expectedRay = amount * 1e9;

        // check balances
        assertEq(yieldRouter.getOwnerPrincipalValue(), expectedRay);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), expectedRay);
    }

    function testNotOwnerDeposit() public {
        // dev (not owner) tries to deposit, should revert
        vm.expectRevert();
        vm.prank(user);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
    }

    function testWithdraw() public {
        // owner deposits into router
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // owner withdraws 500 WAD
        vm.prank(routerOwner);
        yieldRouter.withdraw(500 * WAD);

        // check remaining index-adjusted balance
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500 * RAY);
    }

    function testWithdraAfterIndexChange() public {
        // owner deposits into router
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (simulates yield)
        vm.prank(routerOwner);
        mockPool.setLiquidityIndex(2e27);

        // owner withdraws full 1000 WAD principal
        vm.prank(routerOwner);
        yieldRouter.withdraw(1000 * WAD);

        // check balance and aUSDC transfer
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500 * RAY);
        assertEq(aUSDC.balanceOf(routerOwner), 500 * WAD);
    }

    function testManagingYieldAccess() public {
        // owner deposits
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // owner grants access to dev
        vm.prank(routerOwner);
        yieldRouter.manageRouterAccess(user, true, 100 * WAD);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(user), true);

        // owner revokes access
        vm.prank(routerOwner);
        yieldRouter.manageRouterAccess(user, false, 0);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(user), false);

        // dev tries to re-enable access (should revert)
        vm.expectRevert();
        vm.prank(user);
        yieldRouter.manageRouterAccess(user, true, 100 * WAD);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(user), false);
    }

    function testRouterWhenYieldCoversAllowance() public {
        // owner deposits
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (yield added)
        vm.prank(routerOwner);
        mockPool.setLiquidityIndex(2e27);

        // owner grants access to dev and sets 500 WAD allowance
        vm.prank(routerOwner);
        yieldRouter.manageRouterAccess(user, true, 500 * WAD);

        // owner sets destination address
        vm.prank(routerOwner);
        yieldRouter.setRouterDestination(user);

        // owner activates router and yield is paid out in full
        vm.prank(routerOwner);
        console.logUint(yieldRouter.activateRouter());

        // check post-payout balances
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 750e27);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 500e27);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(user), 0);

        // router is now inactive and cleared
        assertEq(yieldRouter.getRouterIsActive(), false);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(0));
    }

    function testRouterWhenYieldDoesNottCoverAllowance() public {
        // owner deposits
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (not enough yield yet)
        vm.prank(routerOwner);
        mockPool.setLiquidityIndex(12e26);

        // owner grants access to dev and sets 450 WAD allowance
        vm.prank(routerOwner);
        yieldRouter.manageRouterAccess(user, true, 450 * WAD);

        // owner sets destination
        vm.prank(routerOwner);
        yieldRouter.setRouterDestination(user);

        // activate router, partial payout happens
        vm.prank(routerOwner);
        console.logUint(yieldRouter.activateRouter());

        // check balances after first partial payout
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 833333333333333333333333333333);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 0);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(user), 250e27);

        // router still active waiting to pay rest
        assertEq(yieldRouter.getRouterIsActive(), true);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(user));

        // index increases again (now enough yield)
        vm.prank(routerOwner);
        mockPool.setLiquidityIndex(15e26);

        // activate router, rest of yield paid
        vm.prank(routerOwner);
        console.logUint(yieldRouter.activateRouter());

        // check final balances
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 666666666666666666666666666666);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 0);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(user), 0);

        // router deactivates automatically
        assertEq(yieldRouter.getRouterIsActive(), false);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(0));
    }

    function testLockingRouterUntilAllowanceIsPayedOut() public {
        // owner deposits
        vm.prank(routerOwner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (not enough yield yet)
        vm.prank(routerOwner);
        mockPool.setLiquidityIndex(12e26);

        // owner grants access to dev and sets 450 WAD allowance
        vm.prank(routerOwner);
        yieldRouter.manageRouterAccess(user, true, 450 * WAD);

        // owner sets destination
        vm.prank(routerOwner);
        yieldRouter.setRouterDestination(user);

        // owner activates router, first partial payout happens
        vm.prank(routerOwner);
        console.logUint(yieldRouter.activateRouter());

        // owner locks the router to ensure user's allwance is fully paid before owner can withdraw any funds
        vm.prank(routerOwner);
        yieldRouter.lockRouter();
        assertEq(yieldRouter.getRouterIsLocked(), true);

        // check balances after first partial payout
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 833333333333333333333333333333);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 0);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(user), 250e27);

        // router still active and locked waiting to pay rest
        assertEq(yieldRouter.getRouterIsActive(), true);
        assertEq(yieldRouter.getRouterIsLocked(), true);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(user));

        // attempt to unlock router before full allowance is paid out (should revert)
        vm.expectRevert();
        vm.prank(routerOwner);
        yieldRouter.deactivateRouter();

        // attempt to withdraw principal before full allowance is paid out (should revert)
        vm.expectRevert();
        vm.prank(routerOwner);
        yieldRouter.withdraw(500 * WAD);

        // index increases again (now enough yield)
        vm.prank(routerOwner);
        mockPool.setLiquidityIndex(15e26);

        // activate router, rest of yield paid
        vm.prank(routerOwner);
        console.logUint(yieldRouter.activateRouter());

        // check final balances
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 666666666666666666666666666666);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 0);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(user), 0);

        // router deactivates and unlocks automatically
        assertEq(yieldRouter.getRouterIsActive(), false);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(0));

        // attempt to withdraw principal after full allowance is paid out and router is unlocked
        vm.prank(routerOwner);
        yieldRouter.withdraw(500 * WAD);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 333333333333333333333333333333);
        assertEq(aUSDC.balanceOf(routerOwner), 333333333333333333333);
    }
}
