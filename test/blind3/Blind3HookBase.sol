// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LocalFixture} from "../LocalFixture.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RebalanceFlag} from "../../src/libraries/RebalanceFlag.sol";

/// @notice Hook-only tests (demo hook gate, test rebalancers): the fixture market without deploying the module, so
/// these run (and were validated) independently of the module implementation.
abstract contract Blind3HookBase is Blind3Base {
    function setUp() public virtual override {
        LocalFixture.setUp();
    }

    /// calldata of a single opted-in trader swap through the fixture router (exact in)
    function _swapData(PoolKey memory k, bool buy, uint256 amt, bytes memory hd)
        internal
        view
        returns (bytes memory)
    {
        bool z = _zfo(k, buy);
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                k,
                SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                hd
            )
        );
    }

    /// low-level call with a gas limit (as the trader when `asTrader`), gas used measured around it
    function _callG(address to, bytes memory data, uint256 g, bool asTrader) internal returns (bool ok, uint256 used) {
        if (asTrader) vm.prank(trader);
        uint256 before = gasleft();
        (ok,) = to.call{gas: g}(data);
        used = before - gasleft();
    }

    /// every account an opted-in trade touches, cooled (accounts and their slots)
    function _coolAll(address extra) internal {
        vm.cool(trader);
        vm.cool(address(router));
        vm.cool(address(poolManager));
        vm.cool(HOOK);
        vm.cool(address(validator));
        vm.cool(address(om));
        vm.cool(address(fc));
        vm.cool(TYD);
        vm.cool(YES);
        vm.cool(NO);
        if (extra != address(0)) vm.cool(extra);
    }

    function _flag() internal pure returns (bytes memory) {
        return RebalanceFlag.encode();
    }
}
