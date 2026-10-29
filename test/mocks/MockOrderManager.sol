// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Emits every movePoolTick call (the real OrderManager is exercised on the fork). Events, not storage,
/// so the mock adds little gas to the hook.
contract MockOrderManager {
    using PoolIdLibrary for PoolKey;

    event Moved(PoolId indexed poolId, int24 fromTick, int24 toTick, uint160 sqrtPriceX96);

    function movePoolTick(PoolKey calldata key, int24 fromTick, int24 toTick, uint160 sqrtPriceX96) external {
        emit Moved(key.toId(), fromTick, toTick, sqrtPriceX96);
    }
}
