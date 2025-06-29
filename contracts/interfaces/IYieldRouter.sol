// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IYieldRouter
 * @notice Defines the interface for a YieldRouter that routes all yield from a user's deposited yield-bearing tokens to permitted addresses
 */
interface IYieldRouter {
    /// @notice Emitted when a user deposits yield-bearing tokens into the router
    /// @param account The address that performed the deposit
    /// @param token The yield-bearing token address
    /// @param amount The principal amount deposited (in token decimals)
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);

    /// @notice Emitted when the owner withdraws yield-bearing tokens from the router
    /// @param account The address receiving the withdrawn tokens
    /// @param token The yield-bearing token address
    /// @param amount The principal amount withdrawn (in token decimals)
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);

    /// @notice Emitted when yield is routed to a permitted destination address
    /// @param destination The address receiving the routed yield
    /// @param token The yield-bearing token address
    /// @param amount The amount of yield routed (in token decimals)
    event Yield_Routed(address indexed destination, address indexed token, uint256 indexed amount);

    /**
     * @notice Initializes the YieldRouter with the Aave address provider and token addresses
     * @dev Can only be called once. Required when using proxy clones instead of constructors
     * @param _addressProvider The Aave V3 PoolAddressesProvider contract address
     * @param _yieldBarringToken The address of the yield-bearing token (e.g., aUSDC)
     * @param _prinicalToken The underlying principal token address (e.g., USDC)
     */
    function initialize(address _addressProvider, address _yieldBarringToken, address _prinicalToken) external;

    /**
     * @notice Sets the owner of this YieldRouter
     * @dev Can only be called once; intended to be called by the factory immediately after clone deployment
     * @param _owner The address to set as owner
     * @return The address that was set as owner
     */
    function setOwner(address _owner) external returns (address);

    /**
     * @notice Deposits yield-bearing tokens into the router and tracks the scaled balance for yield accounting
     * @dev Only callable by the owner. The deposit token must match the yield-bearing token this router was configured for
     * @param _token The address of the token to deposit (must equal `i_yieldBarringToken`)
     * @param _amount The amount of tokens to deposit, in token decimals
     * @return The principal value of the deposit, adjusted for Aave's liquidity index
     */
    function deposit(address _token, uint256 _amount) external returns (uint256);

    /**
     * @notice Withdraws a specified amount of yield-bearing tokens back to the owner
     * @dev Only callable by the owner. Reduces both principal and scaled balances proportionally
     * @param _amount The amount to withdraw, in token decimals
     * @return The withdrawn amount, adjusted for liquidity index
     */
    function withdraw(uint256 _amount) external returns (uint256);

    /**
     * @notice Routes accrued yield to a destination address
     * @dev Only callable by the owner if the caller is also permitted. Caller must be the same as `_destination`
     * @param _destination The address to send yield to (must be `msg.sender`)
     * @param _amount The amount of yield-bearing tokens to route, in token decimals
     * @return The amount of tokens successfully routed
     */
    function routeYield(address _destination, uint256 _amount) external returns (uint256);

    /**
     * @notice Grants or revokes permission for an address to route yield
     * @dev Only the owner can manage yield access permissions
     * @param _account The address to permit or revoke
     * @param _isPermitted A boolean flag to enable or disable permission
     */
    function manageYieldAccess(address _account, bool _isPermitted) external;

    /**
     * @notice Returns the current owner of the YieldRouter
     * @return The owner address
     */
    function getRouterOwner() external view returns (address);
}
