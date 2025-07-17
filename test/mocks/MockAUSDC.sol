// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract MockAUSDC is ERC20 {
    constructor() ERC20("Mock aUSDC", "aUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address account, uint256 value) external {
        _burn(account, value);
    }

    function getAddress() external view returns (address) {
        return address(this);
    }

    function symbol() public pure override returns (string memory) {
        return "aUSDC";
    }
}
