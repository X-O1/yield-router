// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {Router} from "./Router.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import "./RouterErrors.sol";

contract RouterCore {}
