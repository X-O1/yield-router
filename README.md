# YieldRouter

YieldRouter allows users to deposit yield-bearing tokens (e.g., aUSDC from Aave), track yield growth via Aave’s liquidity index, and route that yield to permitted addresses.

Each user is assigned their own YieldRouter contract, deployed via a factory. Only the assigned user (owner) can deposit or withdraw principal. They can optionally permit others to route yield to themselves or route to any address they choose.

All internal math is done in RAY units (1e27) for precision. User-facing amounts (inputs, outputs, events) are in WAD units (1e18), matching the decimals of most principal tokens like USDC.

---

## Architecture

- **Factory Contract**: Deploys a new YieldRouter for each user using `clone()`.
- **YieldRouter**: A user-specific instance that handles deposits, yield tracking, and routing.
- **Owner**: The only address allowed to deposit/withdraw. Can permit others to route yield.
- **Permitted Address**: Can call `routeYield()` to claim yield, but not deposit or withdraw principal.

---

## Features

- One router per user
- Aave-native yield tracking using the liquidity index
- Principal and yield tracked separately
- Permission system for routing yield
- Minimal interface and event surface
- Proxy-compatible initialization

---

## Installation (Forge)

To install YieldRouter into your Foundry project:

```bash
forge install X-O1/yield-router
```

If you’re using scoped packages or need to prevent an auto-commit:

```bash
forge install X-O1/yield-router --no-commit
```

Once installed, import the contract in your code like this:

```solidity
import "@YieldRouter/contracts/YieldRouter.sol";
```

Make sure your `remappings.txt` includes the correct alias if needed:

```
@YieldRouter/=lib/YieldRouter/
```
---

## Units

- **WAD (1e18)**: Used for all user-facing input/output values
- **RAY (1e27)**: Used for internal accounting and precision math

---

## Workflow

### 1. Deployment
- Factory deploys a clone of the YieldRouter.
- The new clone is initialized with Aave addresses and token configs.
- Ownership is set immediately after.

### 2. Deposit
- Only the owner can call `deposit`.
- `_principalTokenAmount` is in WAD (e.g., 1000 USDC = 1,000 * 1e18).
- YieldRouter calculates scaled aToken amount using Aave's index and transfers aUSDC from the owner.

### 3. Yield Accrual
- As Aave’s index grows, so does the `indexAdjustedBalance`.
- The difference between `indexAdjustedBalance * index` and original `depositPrincipal` is yield.

### 4. Route Yield
- Permitted accounts (set by owner) or owner can call `routeYield`.
- Only accrued yield is sent, not principal.

### 5. Withdraw
- Owner can withdraw principal in any amount.
- aTokens are transferred out at the correct scaled amount.

---

## Core Contracts

- `YieldRouter.sol` — The individual router implementation
- `IYieldRouter.sol` — Public interface
- `YieldRouterFactory.sol` — Deploys clones and sets ownership
- `Mocks/*.sol` — USDC, aUSDC, and Aave pool mocks for local testing

---

## Functions

### External

- `initialize(address addressProvider, address yieldToken, address principalToken)`
- `setOwner(address newOwner)`
- `deposit(address yieldToken, uint256 principalAmount)`
- `withdraw(uint256 principalAmount)`
- `routeYield(address destination, uint256 amount)`
- `manageYieldAccess(address account, bool permitted)`
- `getRouterOwner()`
- `getAccountIndexAdjustedBalance()`
- `getAccountDepositPrincipal()`
- `getAccountIndexAdjustedYield()`
- `isAddressPermittedForYieldAccess(address)`

### Internal Helpers

- `_wadToRay(uint256)`
- `_rayToWad(uint256)`
- `_getCurrentLiquidityIndex()`

---

## Access Control

- `onlyOwner`: The user who owns the router
- `onlyPermitted`: Yield-routing addresses
- `onlyOwnerAndPermitted`: Owner or permitted address (used for `routeYield`)

---

## Events

- `Deposit(address account, address token, uint256 amount)`
- `Withdraw(address account, address token, uint256 amount)`
- `Yield_Routed(address destination, address token, uint256 amount)`

All amounts emitted are in **WAD** units for frontend readability.

---

## Testing

Built with Foundry. Includes mock aToken, mock pool, and USDC. Tests for all flows.

```bash
forge install
forge test

---

## License

MIT
