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
        // owner deposits 1000 WAD aUSDC into router
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // check principal and index-adjusted balance
        assertEq(yieldRouter.getOwnerPrincipalValue(), 1000 * RAY);
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 1000 * RAY);
    }

    function testFuzzDeposit(uint256 amount) public {
        // only allow reasonable deposit amounts (1 to 1000 USDC)
        vm.assume(amount > 0 && amount <= 1000 * WAD);

        // owner deposits random fuzzed amount of aUSDC
        vm.prank(owner);
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
        vm.prank(dev);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);
    }

    function testWithdraw() public {
        // owner deposits into router
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // owner withdraws 500 WAD
        vm.prank(owner);
        yieldRouter.withdraw(500 * WAD);

        // check remaining index-adjusted balance
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500 * RAY);
    }

    function testWithdraAfterIndexChange() public {
        // owner deposits into router
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (simulates yield)
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);

        // owner withdraws full 1000 WAD principal
        vm.prank(owner);
        yieldRouter.withdraw(1000 * WAD);

        // check balance and aUSDC transfer
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 500 * RAY);
        assertEq(aUSDC.balanceOf(owner), 500 * WAD);
    }

    function testManagingYieldAccess() public {
        // owner deposits
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // owner grants access to dev
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, true, 100 * WAD);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(dev), true);

        // owner revokes access
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, false, 0);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(dev), false);

        // dev tries to re-enable access (should revert)
        vm.expectRevert();
        vm.prank(dev);
        yieldRouter.manageRouterAccess(dev, true, 100 * WAD);
        assertEq(yieldRouter.isAddressGrantedRouterAccess(dev), false);
    }

    function testPayoutWhenYieldCoversAllowance() public {
        // owner deposits
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (yield added)
        vm.prank(owner);
        mockPool.setLiquidityIndex(2e27);

        // owner grants access to dev and sets 500 WAD allowance
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, true, 500 * WAD);

        // owner sets destination address
        vm.prank(owner);
        yieldRouter.setRouterDestination(dev);

        // owner activates router and yield is paid out in full
        vm.prank(owner);
        console.logUint(yieldRouter.activateRouter());

        // check post-payout balances
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 750e27);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 500e27);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(dev), 0);

        // router is now inactive and cleared
        assertEq(yieldRouter.getRouterIsActive(), false);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(0));
    }

    function testPayoutWhenYieldDoesNottCoverAllowance() public {
        // owner deposits
        vm.prank(owner);
        yieldRouter.deposit(aUSDCAddress, 1000 * WAD);

        // index increases (not enough yield yet)
        vm.prank(owner);
        mockPool.setLiquidityIndex(12e26);

        // owner grants access to dev and sets 450 WAD allowance
        vm.prank(owner);
        yieldRouter.manageRouterAccess(dev, true, 450 * WAD);

        // owner sets destination
        vm.prank(owner);
        yieldRouter.setRouterDestination(dev);

        // activate router, partial payout happens
        vm.prank(owner);
        console.logUint(yieldRouter.activateRouter());

        // check balances after first partial payout
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 833333333333333333333333333333);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 0);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(dev), 250e27);

        // router still active waiting to pay rest
        assertEq(yieldRouter.getRouterIsActive(), true);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(dev));

        // index increases again (now enough yield)
        vm.prank(owner);
        mockPool.setLiquidityIndex(15e26);

        // activate router, rest of yield paid
        vm.prank(owner);
        console.logUint(yieldRouter.activateRouter());

        // check final balances
        assertEq(yieldRouter.getOwnerIndexAdjustedBalance(), 666666666666666666666666666666);
        assertEq(yieldRouter.getOwnerPrincipalYield(), 0);
        assertEq(yieldRouter.getYieldAllowanceInPrincipalValue(dev), 0);

        // router deactivates automatically
        assertEq(yieldRouter.getRouterIsActive(), false);
        assertEq(yieldRouter.getRouterIsLocked(), false);
        assertEq(yieldRouter.getRouterCurrentDestination(), address(0));
    }
}
