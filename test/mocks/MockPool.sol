// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAUSDC} from "../mocks/MockAUSDC.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import "../../contracts/GlobalErrors.sol";

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
        uint256 data;
    }

    constructor(address ausdcAddress, address usdcAddress) {
        aUSDC = MockAUSDC(ausdcAddress);
        usdc = MockUSDC(usdcAddress);
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
                aTokenAddress: address(aUSDC),
                stableDebtTokenAddress: address(0),
                variableDebtTokenAddress: address(0),
                interestRateStrategyAddress: address(0),
                id: 0,
                accruedToTreasury: 0,
                unbacked: 0,
                isolationModeTotalDebt: 0
            });
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 index = liquidityIndex[asset];
        require(index > 0, "Index not set");

        uint256 scaledAmount = _numDiv(amount, index);
        uint256 aUSDCAmountToBurn = scaledAmount;

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

    function _convertDecimals(uint256 amount, uint256 fromDecimals, uint256 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) {
            return amount * 10 ** (toDecimals - fromDecimals);
        } else {
            return amount / 10 ** (fromDecimals - toDecimals);
        }
    }

    function _numDiv(uint256 _wholeNum, uint256 _partNum) private pure returns (uint256) {
        require(_wholeNum != 0, MUST_BE_GREATER_THAN_0());
        return _wholeNum / _partNum;
    }

    function _numMul(uint256 _wholeNum, uint256 _partNum) private pure returns (uint256) {
        require(_wholeNum != 0, MUST_BE_GREATER_THAN_0());
        return _wholeNum * _partNum;
    }
}
