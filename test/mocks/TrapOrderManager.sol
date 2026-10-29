// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice OrderManager stand-in: the hook's movePoolTick costs `burn` gas when the move crosses tick `trap` of
/// pool `pid` (an expensive limit-order fill nothing in the module could have measured beforehand)
contract TrapOrderManager {
    using PoolIdLibrary for PoolKey;

    bytes32 public pid;
    int24 public trap;
    uint256 public burn;

    function set(bytes32 p, int24 t, uint256 b) external {
        (pid, trap, burn) = (p, t, b);
    }

    function movePoolTick(PoolKey calldata key, int24 fromTick, int24 toTick, uint160) external view {
        if (PoolId.unwrap(key.toId()) != pid || burn == 0) return;
        (int24 lo, int24 hi) = fromTick < toTick ? (fromTick, toTick) : (toTick, fromTick);
        if (lo < trap && trap <= hi) {
            uint256 g = gasleft();
            while (g - gasleft() < burn) {}
        }
    }
}

