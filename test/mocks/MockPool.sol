// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAUSDC} from "../mocks/MockAUSDC.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";

contract MockPool {
    using WadRayMath for uint256;

    MockUSDC internal immutable usdc;
    MockAUSDC internal immutable aUSDC;
    uint256 constant RAY = 1e27;
    mapping(address => uint256) public liquidityIndex;
    mapping(address => mapping(address => uint256)) public scaledBalances;

    struct ReserveData {
        //stores the reserve configuration
        ReserveConfigurationMap configuration;
        //the liquidity index. Expressed in ray
        uint128 liquidityIndex;
        //the current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        //the current stable borrow rate. Expressed in ray
        uint128 currentStableBorrowRate;
        //timestamp of last update
        uint40 lastUpdateTimestamp;
        //the id of the reserve. Represents the position in the list of the active reserves
        uint16 id;
        //aToken address
        address aTokenAddress;
        //stableDebtToken address
        address stableDebtTokenAddress;
        //variableDebtToken address
        address variableDebtTokenAddress;
        //address of the interest rate strategy
        address interestRateStrategyAddress;
        //the current treasury balance, scaled
        uint128 accruedToTreasury;
        //the outstanding unbacked aTokens minted through the bridging feature
        uint128 unbacked;
        //the outstanding debt borrowed against this asset in isolation mode
        uint128 isolationModeTotalDebt;
    }

    struct ReserveConfigurationMap {
        //bit 0-15: LTV
        //bit 16-31: Liq. threshold
        //bit 32-47: Liq. bonus
        //bit 48-55: Decimals
        //bit 56: reserve is active
        //bit 57: reserve is frozen
        //bit 58: borrowing is enabled
        //bit 59: stable rate borrowing enabled
        //bit 60: asset is paused
        //bit 61: borrowing in isolation mode is enabled
        //bit 62: siloed borrowing enabled
        //bit 63: flashloaning enabled
        //bit 64-79: reserve factor
        //bit 80-115 borrow cap in whole tokens, borrowCap == 0 => no cap
        //bit 116-151 supply cap in whole tokens, supplyCap == 0 => no cap
        //bit 152-167 liquidation protocol fee
        //bit 168-175 eMode category
        //bit 176-211 unbacked mint cap in whole tokens, unbackedMintCap == 0 => minting disabled
        //bit 212-251 debt ceiling for isolation mode with (ReserveConfiguration::DEBT_CEILING_DECIMALS) decimals
        //bit 252-255 unused
        uint256 data;
    }

    constructor(address usdcAddress, address ausdcAddress) {
        usdc = MockUSDC(usdcAddress);
        aUSDC = MockAUSDC(ausdcAddress);
        setLiquidityIndex(1e27);
    }

    function setLiquidityIndex(uint256 newIndex) public returns (uint256) {
        require(newIndex > 0, "Index must be > 0");
        liquidityIndex[address(usdc)] = newIndex;
        return liquidityIndex[address(usdc)];
    }

    function getReserveNormalizedIncome(address asset) public view returns (uint256) {
        return liquidityIndex[asset];
    }

    function getReserveData(address asset) public view returns (ReserveData memory) {
        return
            ReserveData({
                configuration: ReserveConfigurationMap(0),
                liquidityIndex: uint128(getReserveNormalizedIncome(asset)),
                currentLiquidityRate: 0,
                variableBorrowIndex: 0,
                currentVariableBorrowRate: 0,
                currentStableBorrowRate: 0,
                lastUpdateTimestamp: uint40(block.timestamp),
                aTokenAddress: address(0),
                stableDebtTokenAddress: address(0),
                variableDebtTokenAddress: address(0),
                interestRateStrategyAddress: address(0),
                id: 0,
                accruedToTreasury: 0,
                unbacked: 0,
                isolationModeTotalDebt: 0
            });
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /*referralCode*/) external {
        uint256 index = liquidityIndex[asset];
        require(index > 0, "Index not set");

        uint256 scaledAmount = _wadToRay(amount).rayDiv(index);
        scaledBalances[asset][onBehalfOf] += scaledAmount;

        usdc.transferFrom(msg.sender, address(this), amount);
        aUSDC.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 index = liquidityIndex[asset];
        require(index > 0, "Index not set");

        uint256 scaledAmount = amount.rayDiv(index);
        uint256 aUSDCAmountToBurn = scaledAmount;
        require(scaledBalances[asset][msg.sender] >= scaledAmount, "Insufficient balance");
        scaledBalances[asset][msg.sender] -= scaledAmount;

        aUSDC.burn(msg.sender, aUSDCAmountToBurn);
        usdc.transfer(to, amount);

        return amount;
    }

    function getUserBalance(address asset, address user) external view returns (uint256) {
        uint256 index = liquidityIndex[asset];
        uint256 scaled = scaledBalances[asset][user];
        uint256 actualBalance = scaled.rayMul(index);
        return actualBalance;
    }

    function getPool() external view returns (address) {
        return address(this);
    }

    // converts number to RAY units (1e27)
    function _wadToRay(uint256 _num) private pure returns (uint256) {
        return _num * 1e9;
    }

    // converts number from RAY units (1e27) to WAD units (1e18)
    function _rayToWad(uint256 _num) private pure returns (uint256) {
        return _num / 1e9;
    }
}
