// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockMarketManager {
    mapping(address => bool) public isActiveMarket;
    bool public paused;

    function setActive(address market, bool active) external {
        isActiveMarket[market] = active;
    }

    function setPaused(bool p) external {
        paused = p;
    }
}
