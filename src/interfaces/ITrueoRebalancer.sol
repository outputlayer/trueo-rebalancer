// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Called by the Trueo hook as the last step of afterSwap, only for swaps whose hookData ends with
/// RebalanceFlag.MAGIC (the trader's opt-in).
interface ITrueoRebalancer {
    function onSwap(PoolKey calldata key) external;
}
