// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IRouter
 * @notice Interface for the Router contract, defining all external functions and events
 * for managing yield-bearing token deposits, yield routing, access control, and router state.
 * @dev All external inputs/outputs are in WAD (1e18), internal accounting uses RAY (1e27).
 */
interface IRouter {
    /// @notice Emitted when a user deposits yield-bearing tokens into the router
    /// @param account The depositor (must be router owner)
    /// @param token The yield-bearing token address
    /// @param amount Amount deposited in WAD (principal-equivalent)
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);

    /// @notice Emitted when a user withdraws yield-bearing tokens from the router
    /// @param account The withdrawer (must be router owner)
    /// @param token The yield-bearing token address
    /// @param amount Amount withdrawn in WAD
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);

    /// @notice Emitted when yield is routed to a permitted destination
    /// @param destination The destination receiving yield
    /// @param token The yield-bearing token
    /// @param amount The amount of yield routed (in WAD)
    /// @param routerStatus The router's active status after routing
    event Router_Activated(address indexed destination, address token, uint256 indexed amount, bool indexed routerStatus);

    /// @notice Emitted when the router's status changes
    /// @param activeStatus Whether the router is currently active
    /// @param lockedStatus Whether the router is locked
    /// @param currentDestination The current yield destination address
    event Router_Status_Changed(bool indexed activeStatus, bool indexed lockedStatus, address indexed currentDestination);

    /**
     * @notice Initializes the router instance (for clones)
     * @param _addressProvider Address of Aave V3 PoolAddressesProvider
     * @param _yieldBarringToken Address of the yield-bearing token (e.g., aUSDC)
     * @param _prinicalToken Address of the principal token (e.g., USDC)
     */
    function initialize(
        address _factoryAddress,
        address _previousRouter,
        address _addressProvider,
        address _yieldBarringToken,
        address _prinicalToken
    ) external;

    /**
     * @notice Sets the router owner (can only be called once)
     * @param _owner Address to assign as owner
     * @return The address set as the new owner
     */
    function setOwner(address _owner) external returns (address);

    /**
     * @notice Sets the factory owner for emergency control (can only be called once)
     * @param _factoryOwner Address of the factory/deployer
     * @return The address set as the factory owner
     */
    function setFactoryOwner(address _factoryOwner) external returns (address);

    /**
     * @notice Grants or revokes yield access for an address
     * @param _account The address to update
     * @param _grantedYieldAccess Whether access should be granted (true) or revoked (false)
     * @param _yieldAllowance Max yield this address can withdraw (in RAY)
     */
    function manageRouterAccess(address _account, bool _grantedYieldAccess, uint256 _yieldAllowance) external;

    /**
     * @notice Sets the destination address to receive yield
     * @dev Destination must already be granted access. Router must be deactivated to change.
     * @param _destination The address to route yield to
     */
    function setRouterDestination(address _destination) external;

    /**
     * @notice Deactivates the router
     * @dev Required to unlock principal withdrawal. Router must be unlocked.
     */
    function deactivateRouter() external;

    /**
     * @notice Locks the router, preventing withdrawals until the destination address has received its full yield allowance.
     * @dev WARNING: LOCKS ALL OF OWNER'S FUNDS UNTIL DESTINATION ADDRESS RECEIVES MAX YIELD ALLOWANCE.
     * @dev Router must be active before it can be locked.
     * @dev === MAKE SURE ANY FRONT-END WARNS USER BEFORE CALLING THIS FUNCTION ===
     */
    function lockRouter() external;

    /**
     * @notice Emergency shutdown only callable by factory owner
     * @dev Resets destination, deactivates, and unlocks router
     */
    function emergencyRouterShutDown() external;

    /**
     * @notice Deposits yield-bearing tokens into the router
     * @param _yieldBarringToken Token address to deposit (must match configured yield-bearing token)
     * @param _amountInPrincipalValue Amount to deposit (in WAD)
     * @return Amount of tokens transferred into the router (in WAD)
     */
    function deposit(address _yieldBarringToken, uint256 _amountInPrincipalValue) external returns (uint256);

    /**
     * @notice Withdraws yield-bearing tokens from the router to the owner
     * @dev Only allowed when router is inactive and unlocked
     * @param _amountInPrincipalValue Amount to withdraw (in WAD)
     * @return Amount of tokens withdrawn (in WAD)
     */
    function withdraw(uint256 _amountInPrincipalValue) external returns (uint256);

    /**
     * @notice Activates the router and routes any accrued yield to the permitted destination
     * @dev Router must have a destination set.
     * @dev Chainlink Automation will be used to call on a time interval while router is acitve.
     * @return Amount of yield routed (in WAD)
     */
    function activateRouter() external returns (uint256);

    /**
     * @notice Returns the router owner address
     * @return Address of the current owner
     */
    function getRouterOwner() external view returns (address);

    /**
     * @notice Returns the owner's index-adjusted balance
     * @return Balance in RAY (1e27)
     */
    function getOwnerIndexAdjustedBalance() external view returns (uint256);

    /**
     * @notice Returns the owner's original deposited principal
     * @return Principal in RAY (1e27)
     */
    function getOwnerPrincipalValue() external view returns (uint256);

    /**
     * @notice Returns the owner's principal yield (unrouted)
     * @return Yield in RAY (1e27)
     */
    function getOwnerPrincipalYield() external view returns (uint256);

    /**
     * @notice Returns the yield allowance (in principal value) for a permitted address
     * @param _address The address to query
     * @return Yield allowance in RAY
     */
    function getYieldAllowanceInPrincipalValue(address _address) external view returns (uint256);

    /**
     * @notice Returns whether the router is currently active
     * @return True if router is active, false otherwise
     */
    function getRouterIsActive() external view returns (bool);

    /**
     * @notice Returns whether the router is currently locked
     * @return True if router is locked, false otherwise
     */
    function getRouterIsLocked() external view returns (bool);

    /**
     * @notice Returns the current destination set for yield routing
     * @return Address of current destination
     */
    function getRouterCurrentDestination() external view returns (address);

    /**
     * @notice Checks if an address has been granted yield access
     * @param _address Address to check
     * @return True if access is granted, false otherwise
     */
    function isAddressGrantedRouterAccess(address _address) external view returns (bool);
}
