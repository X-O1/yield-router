// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title YieldRouterFactory
 * @notice Deploys vaults for each user to route yield from a specific yield-bearing token
 * @dev One factory is deployed per yield-bearing token (e.g., YieldRouterFactory (AUSDC), YieldRouterFactory( AUSDT))
 * @dev Uses OpenZeppelin's ERC-1167 minimal proxy (clone) pattern for efficient vault creation
 */
contract YieldRouterFactory {}
