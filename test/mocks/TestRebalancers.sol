// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ITrueoRebalancer} from "../../src/interfaces/ITrueoRebalancer.sol";

contract RevertingRebalancer is ITrueoRebalancer {
    function onSwap(PoolKey calldata) external pure {
        revert("boom");
    }
}

contract GasBurnerRebalancer is ITrueoRebalancer {
    uint256 public sink;

    function onSwap(PoolKey calldata) external {
        while (true) {
            sink += 1;
        }
    }
}

/// @notice Records each call and the fee-collector claim balance seen at call time.
contract RecordingRebalancer is ITrueoRebalancer {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable pm;
    address public immutable feeCollector;
    uint256 public immutable claimId;
    uint256 public calls;
    PoolId public lastPool;
    uint256 public claimsSeen;

    event Called(PoolId poolId);

    constructor(IPoolManager _pm, address _feeCollector, uint256 _claimId) {
        pm = _pm;
        feeCollector = _feeCollector;
        claimId = _claimId;
    }

    function onSwap(PoolKey calldata key) external {
        calls++;
        lastPool = key.toId();
        claimsSeen = pm.balanceOf(feeCollector, claimId);
        emit Called(key.toId());
    }
}
