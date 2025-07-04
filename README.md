# YieldRouter

YieldRouter allows users to deposit yield-bearing tokens (e.g., aUSDC from Aave), track yield growth via Aave’s liquidity index, and route that yield to permitted addresses.

Each user is assigned their own YieldRouter contract, deployed via a factory. Only the assigned user (owner) can deposit or withdraw principal. They can optionally permit others to route yield to themselves or route to any address they choose.

Protocols can use the router to lock their users yield-barring tokens to collect yield without having to custody their user's funds. 

All internal math is done in RAY units (1e27) for precision. User-facing amounts (inputs, outputs, events) are in WAD units (1e18).

---

## Architecture

- **Factory Contract**: Deploys a new YieldRouter for each user using `clone()`.
- **YieldRouter**: A user-specific instance that handles deposits, yield tracking, and routing.
- **Owner**: The only address allowed to deposit/withdraw. Can permit others to route yield.

---

## Features

- One router per user
- Aave-native yield tracking using the liquidity index
- Principal and yield tracked separately
- Permission system for routing yield
- Router lock functionality to enforce full yield allowance to be paid out before principal can be withdrawn
- Emergency shutdown controls
- Proxy-compatible initialization

---

## ⚠️ Yield Lock Warning

Calling `lockRouter()` will **freeze all of the owner's funds** inside the router **until the permitted destination address receives the full amount of its assigned yield allowance**. This is enforced strictly and prevents any principal withdrawals.

> ⚠️ Frontends MUST warn users before allowing `lockRouter()` to be called.

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

Make sure your `remappings.txt` includes the correct alias if needed:

```
@YieldRouter/=lib/yield-router/contracts
```

Once installed, import the contract in your code like this:

## Use the Interface 

Your protocol doesn't need to interact with the full `YieldRouter` contract directly. For cleaner integration, import and use the provided interface:

```solidity
import "@YieldRouter/interfaces/IYieldRouter.sol";
```

This gives you access to the external functions your protocol needs, with no need to compile the full implementation. Useful for mocks, testing, and cleaner dependency management.

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
- Owner or permitted account calls `activateRouter()`.
- Yield (not principal) is routed to the current destination address.
- If locked, router remains locked until full allowance is met.

### 5. Withdraw
- Only allowed when router is **not active** and **not locked**.
- Owner can withdraw any or all principal at the scaled value.

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
- `setFactoryOwner(address factoryOwner)`
- `deposit(address yieldToken, uint256 principalAmount)`
- `withdraw(uint256 principalAmount)`
- `activateRouter()`
- `deactivateRouter()`
- `lockRouter()`
- `emergencyRouterShutDown()`
- `setRouterDestination(address destination)`
- `manageRouterAccess(address account, bool permitted, uint256 allowance)`
- `getRouterOwner()`
- `getAccountIndexAdjustedBalance()`
- `getAccountDepositPrincipal()`
- `isAddressGrantedYieldAccess(address)`

### Internal Helpers

- `_wadToRay(uint256)`
- `_rayToWad(uint256)`
- `_getCurrentLiquidityIndex()`

---

## Access Control

- `onlyOwner`: The user who owns the router
- `onlyFactoryOwner`: Deployer with emergency shutdown rights
- `ifRouterNotActive`: Prevents actions when router is active
- `ifRouterNotLocked`: Prevents actions when router is locked
- `ifRouterDestinationIsSet`: Enforces destination setup before routing

---

## Events

- `Deposit(address account, address token, uint256 amount)`
- `Withdraw(address account, address token, uint256 amount)`
- `Router_Activated(address destination, address token, uint256 amount, bool status)`
- `Router_Status_Changed(bool isActive, bool isLocked, address destination)`

All amounts emitted are in **WAD** units for frontend readability.

---

## Testing

Built with Foundry. Includes mock aToken, mock pool, and USDC. Tests for all flows.

```bash
forge install
forge test
```

---

## License

MIT
