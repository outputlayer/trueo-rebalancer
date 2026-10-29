// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

interface IFeeTrack {
    function poolFeeAccumulated(PoolId, Currency) external view returns (uint256);
}

/// @notice N exact-in/exact-out swaps inside ONE unlock. After every swap it records the swap's delta, the sqrt
/// prices of two watched pools and the fee-collector's per-pool claims, so tests can compare every swap of a route
/// (not only the end state). Pays inputs from its own balance and keeps outputs.
contract MultiSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    struct Leg {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        bytes hookData;
    }

    struct Rec {
        int128 a0;
        int128 a1;
        uint160 s1;
        uint160 s2;
        uint256 f1t; // feeCollector: watched pool 1, currency fc1
        uint256 f1o; // feeCollector: watched pool 1, currency fo1
        uint256 f2t;
        uint256 f2o;
    }

    IPoolManager public immutable pm;
    PoolId public w1;
    PoolId public w2;
    address public fc;
    Currency public c1a;
    Currency public c1b;
    Currency public c2a;
    Currency public c2b;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function watch(PoolKey calldata k1, PoolKey calldata k2, address _fc) external {
        w1 = _id(k1);
        w2 = _id(k2);
        (c1a, c1b, c2a, c2b) = (k1.currency0, k1.currency1, k2.currency0, k2.currency1);
        fc = _fc;
    }

    function run(Leg[] calldata legs) external returns (Rec[] memory) {
        return abi.decode(pm.unlock(abi.encode(legs)), (Rec[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        Leg[] memory legs = abi.decode(data, (Leg[]));
        Rec[] memory recs = new Rec[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            Leg memory l = legs[i];
            BalanceDelta d = pm.swap(
                l.key,
                SwapParams(
                    l.zeroForOne,
                    l.amountSpecified,
                    l.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                ),
                l.hookData
            );
            recs[i] = _record(d);
        }
        for (uint256 i; i < legs.length; i++) {
            _close(legs[i].key.currency0);
            _close(legs[i].key.currency1);
        }
        return abi.encode(recs);
    }

    function _record(BalanceDelta d) internal view returns (Rec memory r) {
        r.a0 = d.amount0();
        r.a1 = d.amount1();
        (r.s1,,,) = pm.getSlot0(w1);
        (r.s2,,,) = pm.getSlot0(w2);
        if (fc != address(0)) {
            r.f1t = IFeeTrack(fc).poolFeeAccumulated(w1, c1a);
            r.f1o = IFeeTrack(fc).poolFeeAccumulated(w1, c1b);
            r.f2t = IFeeTrack(fc).poolFeeAccumulated(w2, c2a);
            r.f2o = IFeeTrack(fc).poolFeeAccumulated(w2, c2b);
        }
    }

    function _close(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            pm.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-d));
            pm.settle();
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }

    function _id(PoolKey calldata k) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(k)));
    }
}
