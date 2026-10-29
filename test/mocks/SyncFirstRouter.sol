// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice A legal but unusual router: sync + transfer the input BEFORE the swap, settle after it.
/// Exact-in only. Pays from its own balance, sends the output to `to`.
contract SyncFirstRouter is IUnlockCallback {
    IPoolManager public immutable pm;
    bytes public hookData;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function setHookData(bytes calldata hd) external {
        hookData = hd;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) external {
        pm.unlock(abi.encode(key, zeroForOne, amountIn, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        pm.sync(cin);
        ERC20(Currency.unwrap(cin)).transfer(address(pm), amountIn);
        BalanceDelta d = pm.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(amountIn),
                zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            ),
            hookData
        );
        pm.settle();
        int128 out = zeroForOne ? d.amount1() : d.amount0();
        pm.take(cout, to, uint256(int256(out)));
        return "";
    }
}
