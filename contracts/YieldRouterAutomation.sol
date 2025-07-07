// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";

/**
 * @title YieldRouterAutomation
 * @notice Chainlink Automation contract that listens for Router_Status_Changed logs
 *         and automatically calls `activateRouter()` if the router is inactive
 *         and has a destination set.
 */
contract YieldRouterAutomation {

}
