// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice YesNoToken stand-in: 18 decimals, owner (the market) mints, burnFrom spends the caller's allowance.
contract MockOutcomeToken is ERC20 {
    address public owner;

    constructor(string memory symbol, address _owner) ERC20(symbol, symbol, 18) {
        owner = _owner;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _burn(from, amount);
    }
}
