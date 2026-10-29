// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RebalanceMath} from "../../../src/libraries/RebalanceMath.sol";

/// @notice Exposes RebalanceMath (build, capacity, walk, payFor, estimateProfit) as external calls, so a test can
/// compare the model with real swaps on the same state and catch reverts with try/catch.
contract MathHarness3 {
    IPoolManager public immutable pm;

    struct P {
        PoolId id;
        int24 spacing;
        bool outIs0;
        bool mint; // true: sale exact-in; false: purchase exact-out
        uint24 fee; // pips
        uint160 limit;
    }

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function _curve(P memory p) internal view returns (RebalanceMath.Curve memory) {
        RebalanceMath.Stop memory stop;
        return RebalanceMath.build(pm, p.id, p.spacing, p.outIs0, p.mint, p.fee, p.limit, stop);
    }

    function capacity(P calldata p) external view returns (uint256) {
        return RebalanceMath.capacity(_curve(p));
    }

    function payFor(P calldata p, uint256 n) external view returns (bool ok, uint256 pay) {
        return RebalanceMath.payFor(_curve(p), n);
    }

    function walk(P calldata p, uint256 n) external view returns (bool ok, uint256 seg, uint160 s) {
        return RebalanceMath.walk(_curve(p), n);
    }

    function estimateProfit(P calldata y, P calldata no, uint256 x, uint256 scale, uint256 hookFee)
        external
        view
        returns (int256)
    {
        return RebalanceMath.estimateProfit(_curve(y), _curve(no), x, scale, hookFee);
    }
}
