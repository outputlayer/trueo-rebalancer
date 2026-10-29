// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Two exact-in swaps inside one unlock (a multi-hop style router), then settles every delta.
/// Pays from its own balance, sends outputs to `to`.
contract TwoSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    bytes public hookData1;
    bytes public hookData2;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    /// hookData passed to the first and the second swap (default: empty)
    function setHookData(bytes calldata hd1, bytes calldata hd2) external {
        hookData1 = hd1;
        hookData2 = hd2;
    }

    function run(PoolKey memory k1, bool z1, uint256 in1, PoolKey memory k2, bool z2, uint256 in2, address to)
        external
        returns (BalanceDelta d1, BalanceDelta d2)
    {
        return abi.decode(pm.unlock(abi.encode(k1, z1, in1, k2, z2, in2, to)), (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory k1, bool z1, uint256 in1, PoolKey memory k2, bool z2, uint256 in2, address to) =
            abi.decode(data, (PoolKey, bool, uint256, PoolKey, bool, uint256, address));
        BalanceDelta d1 = pm.swap(k1, SwapParams(z1, -int256(in1), _limit(z1)), hookData1);
        BalanceDelta d2 = pm.swap(k2, SwapParams(z2, -int256(in2), _limit(z2)), hookData2);
        _close(k1.currency0, to);
        _close(k1.currency1, to);
        _close(k2.currency0, to);
        _close(k2.currency1, to);
        return abi.encode(d1, d2);
    }

    function _close(Currency c, address to) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            pm.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-d));
            pm.settle();
        } else if (d > 0) {
            pm.take(c, to, uint256(d));
        }
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
    }
}
