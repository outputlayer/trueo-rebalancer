// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice FeeCollector.trackPoolFee stand-in with the same onlyHook gate (FeeCollector.sol:78-84).
contract MockFeeCollector {
    address public hookAddress;
    mapping(PoolId => mapping(Currency => uint256)) public poolFeeAccumulated;

    error OnlyHook();

    function setHookAddress(address h) external {
        hookAddress = h;
    }

    function trackPoolFee(PoolId poolId, Currency currency, uint256 amount) external {
        if (msg.sender != hookAddress) revert OnlyHook();
        poolFeeAccumulated[poolId][currency] += amount;
    }
}
