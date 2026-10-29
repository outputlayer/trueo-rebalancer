// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RebalanceMath} from "../../../src/libraries/RebalanceMath.sol";

/// @notice Exposes RebalanceMath.build + payFor + capacity for one pool, so a test can compare the model with a
/// real swap on the same state.
contract MathHarness {
    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    /// mint = true: sale of n outcome units exact-in (pay = payout); false: purchase of n exact-out (pay = cost)
    function quote(PoolId id, int24 spacing, bool outIs0, bool mint, uint24 fee, uint160 limit, uint256 n)
        external
        view
        returns (bool ok, uint256 pay, uint256 cap, uint256 nb)
    {
        RebalanceMath.Stop memory stop;
        RebalanceMath.Curve memory c = RebalanceMath.build(pm, id, spacing, outIs0, mint, fee, limit, stop);
        cap = RebalanceMath.capacity(c);
        nb = c.count; // Curve.nb (boundaries) was removed; segments instead (no caller reads nb)
        (ok, pay) = RebalanceMath.payFor(c, n);
    }
}
