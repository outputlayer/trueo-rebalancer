// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice The subset of TruthMarketV2 (0x2CA8...3409) the rebalancer uses.
interface ITrueoMarket {
    function mint(uint256 paymentTokenAmount) external;
    function burn(uint256 amount) external;
    function getPoolKeys() external view returns (PoolKey memory, PoolKey memory);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function paymentToken() external view returns (address);
    function paused() external view returns (bool);
    function getCurrentStatus() external view returns (uint8);
    function yesNoTokenCap() external view returns (uint256);
}

/// @notice The subset of TruthMarketManager (0x61A9...95d7) the rebalancer uses.
interface ITrueoManager {
    function isActiveMarket(address market) external view returns (bool);
    function paused() external view returns (bool);
}

/// @notice The subset of TruthMarketHook the rebalancer uses.
interface ITrueoHook {
    function poolPaused(PoolId poolId) external view returns (bool);
    function feeNumerator() external view returns (uint256);
    function swapValidator() external view returns (address);
}

/// @notice The subset of TruthMarketSwapValidator (0x55e2...Dd38) the rebalancer uses.
interface ITrueoValidator {
    function poolBoundaries(PoolId poolId)
        external
        view
        returns (int24 tickLowerBoundary, int24 tickUpperBoundary, bool isSet);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}
