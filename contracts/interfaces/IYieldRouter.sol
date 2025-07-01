// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IYieldRouter
 * @notice Interface for the YieldRouter contract that manages deposits of yield-bearing tokens,
 * routes yield to permitted addresses, and tracks principal/yield using Aave’s liquidity index.
 * @dev All deposit, withdraw, and route inputs/outputs are in WAD (1e18), representing the principal token value.
 * @dev `_yieldBarringToken` refers to the yield-bearing token (e.g., aUSDC).
 * @dev `_principalToken` refers to the underlying token that accrues yield (e.g., USDC).
 */
interface IYieldRouter {
    /// @notice Emitted when a user deposits yield-bearing tokens into the router
    /// @param account The depositor (must be router owner)
    /// @param token The yield-bearing token (e.g., aUSDC)
    /// @param amount The amount transferred in WAD (i.e., principal-equivalent yield barring token)
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);

    /// @notice Emitted when yield-bearing tokens are withdrawn from the router
    /// @param account The withdrawer (must be router owner)
    /// @param token The yield-bearing token (e.g., aUSDC)
    /// @param amount The amount withdrawn in WAD
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);

    // Emitted when any router status is changed
    /// @param activeStatus The current active status
    /// @param lockedStatus The current locked status
    event Router_Status_Changed(bool indexed activeStatus, bool indexed lockedStatus);

    /// @notice Emitted when yield is routed to a permitted destination address
    /// @param destination The address receiving the yield
    /// @param token The yield-bearing token
    /// @param amount The yield routed in WAD
    /// @param routerStatus Router status after yield is routed
    event Yield_Routed(address indexed destination, address token, uint256 indexed amount, bool indexed routerStatus);

    /**
     * @notice Initializes the router (used for clones)
     * @param _addressProvider Aave V3 PoolAddressesProvider address
     * @param _yieldBarringToken The yield-bearing token (e.g., aUSDC)
     * @param _prinicalToken The principal token (e.g., USDC)
     */
    function initialize(address _addressProvider, address _yieldBarringToken, address _prinicalToken) external;

    /**
     * @notice Sets the router owner (can only be called once)
     * @param _owner The address to assign ownership to
     * @return The new owner address
     */
    function setOwner(address _owner) external returns (address);

    /**
     * @notice Grants or revokes permission to route yield
     * @param _account The address to update
     * @param _isPermitted True to grant, false to revoke
     * @param _amountPermitted Max amount of yield permitted to withdraw
     */
    function manageRouterAccess(address _account, bool _isPermitted, uint256 _amountPermitted) external;

    /**
     * @notice Deposits yield-bearing tokens into the router
     * @dev Caller must hold and approve yield barring token. The `_amountInPrincipalValue` is in WAD (USDC terms).
     * @param _yieldBarringToken The yield-bearing token address (e.g., aUSDC) (must match configured one)
     * @param _amountInPrincipalValue The deposit amount in WAD (USDC value)
     * @return The actual amount of yield barring token transferred in WAD
     */
    function deposit(address _yieldBarringToken, uint256 _amountInPrincipalValue) external returns (uint256);

    /**
     * @notice Withdraws yield barring token from the router to the owner
     * @param _amountInPrincipalValue The amount to withdraw, in WAD (USDC value)
     * @return The amount of yield barring token transferred in WAD
     */
    function withdraw(uint256 _amountInPrincipalValue) external returns (uint256);

    /**
     * @notice Routes accrued yield to the caller.
     * @param _destination Must equal `msg.sender`
     * @param _amountInPrincipalValue Amount of yield to route in WAD (USDC value)
     * @param _lockRouter // === LOCKS OWNER'S FUNDS UNTIL PERMITTED ADDRESS WITHDRAWS MAX PERMMITED AMOUNT OF YIELD  ===  (Must be called by OWNER — input is ignored otherwise)
     * @return The amount of yield barring token transferred in WAD
     */
    function routeYield(address _destination, uint256 _amountInPrincipalValue, bool _lockRouter) external returns (uint256);

    /**
     * @notice Returns the router owner's address
     */
    function getRouterOwner() external view returns (address);

    /**
     * @notice Returns the current index-adjusted balance of the owner (in RAY)
     */
    function getAccountIndexAdjustedBalance() external view returns (uint256);

    /**
     * @notice Returns the current principal amount deposited by owner (in RAY)
     */
    function getAccountDepositPrincipal() external view returns (uint256);

    /**
     * @notice Returns the current index-adjusted yield (in RAY) after updating it
     */
    function getAccountIndexAdjustedYield() external returns (uint256);

    /**
     * @notice Checks if a given address is permitted to route yield
     * @param _address The address to check
     * @return True if permitted
     */
    function isAddressPermittedForYieldAccess(address _address) external view returns (bool);
}
