// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldRouter} from "../contracts/YieldRouter.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

contract YieldRouterTest is Test {
    YieldRouter yieldRouter;
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
        yieldRouter = new YieldRouter(addressProvider, aUSDCAddress, usdcAddress);
    }

    function test() public {}
}
