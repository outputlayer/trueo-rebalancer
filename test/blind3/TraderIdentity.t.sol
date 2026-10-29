// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {SyncFirstRouter} from "../mocks/SyncFirstRouter.sol";

/// Test-plan items 22-24: exact-output trader swaps, a router between sync and settle, hook fee 0.
contract Blind3TraderIdentityTest is Blind3Base {
    // ---------------------------------------------------------------- 22

    function test_t22_exactOut_buy30No() public {
        (Run memory a, Run memory b) = _pairT(_main(), T(false, true, 30e18, 0));
        // the trader got exactly 30 NO out (NO is currency1 of its pool)
        assertEq(b.o.a1, int128(30e18));
        assertEq(b.o.trNo, a.o.trNo);
        _assertActedR(_main(), a, b);
        assertTrue(b.evMint, "a NO purchase must be followed by a mint-side rebalance");
    }

    function test_t22_exactOut_get20Tyd_sellingYes() public {
        (Run memory a, Run memory b) = _pairT(_main(), T(true, false, 20e6, 0));
        // YES is currency0 of its pool: zeroForOne, TYD (currency1) out exactly 20
        assertEq(b.o.a1, int128(20e6));
        _assertActedR(_main(), a, b);
        assertFalse(b.evMint, "a YES sale must be followed by a burn-side rebalance");
    }

    // ---------------------------------------------------------------- 23

    function test_t23_syncFirstRouter_moduleStaysOut() public {
        SyncFirstRouter sfr = new SyncFirstRouter(poolManager);
        sfr.setHookData(_magic());
        tyd.transfer(address(sfr), 1e9);
        uint256 yes0 = yes.balanceOf(trader);
        hook.setRebalanceGas(5_000_000);
        uint256 s0 = vm.snapshotState();

        // control: the same purchase through a router that does not sync first is rebalanced
        (Run memory c, Run memory d) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), c, d);
        vm.revertToState(s0);

        _unplug();
        sfr.swapExactIn(kYes, _zfo(kYes, true), 50e6, trader);
        Out memory a = _snapOut(kYes, kNo);
        vm.revertToState(s0);

        hook.setRebalancer(address(module));
        vm.expectCall(address(module), _onSwapSel(), 1);
        sfr.swapExactIn(kYes, _zfo(kYes, true), 50e6, trader);
        Out memory b = _snapOut(kYes, kNo);
        assertGt(b.trYes, yes0, "trader received no YES");
        assertGt(b.trYes, 1000e18);
        assertEq(b.trYes, a.trYes, "trader result differs");
        assertEq(b.recv, a.recv, "recipient got something");
        assertEq(b.sY, a.sY, "YES pool moved by the module");
        assertEq(b.sN, a.sN, "NO pool moved by the module");
        _assertModuleEmpty();
    }

    // ---------------------------------------------------------------- 24

    function test_t24_hookFeeZero_stillRebalanced_sumNearOne() public {
        hook.setFeeRate(0);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a, b);
        assertGt(a.sum, 1.01e18, "trade did not open a gap");
        assertApproxEqAbs(b.sum, 1e18, 0.0005e18, "YES + NO not within 0.0005 of 1");
        // no hook fee anywhere
        assertEq(b.o.c6909t + b.o.c6909y + b.o.c6909n, 0);
    }
}
