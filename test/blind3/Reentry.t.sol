// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {MultiSwapRouter} from "../blind2/utils/MultiSwapRouter.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";

interface IReentryHook {
    function onSwapCalls() external view returns (uint256);
}

/// I8 / no recursion: with a test-only hook (utils/ReentryHook.sol) that calls onSwap on EVERY swap of its pools,
/// including the module's own swaps, the module must ignore nested calls during a rebalance and release its guard
/// afterwards. The module is bound to HOOK, where the variant code is installed (storage kept).
contract Blind3ReentryTest is Blind3Base {
    function _installReentryHook() internal {
        _deployHook("ReentryHook.sol:ReentryHook");
        assertEq(IReentryHook(HOOK).onSwapCalls(), 0);
    }

    /// same gas settings on both hooks; reserve at the floor and min 0 so that nested calls are always made
    function _gasCfg() internal {
        hook.setRebalanceGasReserve(150_000);
        cfgMinSet = true;
        cfgMin = 0;
        cfgGas = 5_000_000;
    }

    // ---------------------------------------------------------------- 1: one trader swap -> one rebalance

    function _oneSwap(bool buy, int256 amt) internal {
        _gasCfg();
        uint256 s0 = vm.snapshotState();
        // reference: the normal demo hook
        (Run memory a0, Run memory b0) = _pairMain(true, buy, amt);
        uint256 pRef = _assertActedR(_main(), a0, b0);
        vm.revertToState(s0);

        _installReentryHook();
        _gasCfg();
        (Run memory a, Run memory b) = _pairMain(true, buy, amt);
        uint256 calls = IReentryHook(HOOK).onSwapCalls();
        console.log("onSwap calls for one trader swap / profit ref / profit", calls, pRef, b.o.recv - a.o.recv);
        // control: the variant really called onSwap during the module's own swaps (trader swap + 2 module swaps)
        assertGe(calls, 3, "variant hook did not call onSwap on the module's swaps");
        uint256 p = _assertActedR(_main(), a, b); // trader identical, one Rebalanced, module empty
        assertEq(b.modSwaps, 2, "nested onSwap traded");
        assertEq(p, pRef, "profit differs from the normal hook");
        assertApproxEqAbs(b.o.sY, b0.o.sY, 1, "YES pool price differs from the normal hook");
        assertApproxEqAbs(b.o.sN, b0.o.sN, 1, "NO pool price differs from the normal hook");
    }

    function test_r1_nestedOnSwapIgnored_mint() public {
        _oneSwap(true, -50e6);
    }

    function test_r1_nestedOnSwapIgnored_burn() public {
        _oneSwap(false, -80e18);
    }

    // ---------------------------------------------------------------- 2: guard released

    function test_r2_guardReleased_twoTraderSwapsInOneTx() public {
        _installReentryHook();
        _gasCfg();
        _plugCfg();
        MultiSwapRouter msr = new MultiSwapRouter(poolManager);
        msr.watch(kYes, kNo, address(fc));
        tyd.transfer(address(msr), 1e10);
        MultiSwapRouter.Leg[] memory legs = new MultiSwapRouter.Leg[](2);
        // buy YES for 50 TYD, then buy NO for 50 TYD: each opens a profitable mint-side gap
        legs[0] = MultiSwapRouter.Leg(kYes, _zfo(kYes, true), -50e6, _magic());
        legs[1] = MultiSwapRouter.Leg(kNo, _zfo(kNo, true), -50e6, _magic());
        uint256 r0 = tyd.balanceOf(recipient);
        _startRec();
        msr.run(legs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        uint256[2] memory profits;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(module) && logs[i].topics[0] == TrueoRebalancer.Rebalanced.selector) {
                (,, uint256 pr) = abi.decode(logs[i].data, (bool, uint256, uint256));
                if (n < 2) profits[n] = pr;
                n++;
            }
        }
        uint256 gain = tyd.balanceOf(recipient) - r0;
        console.log("rebalances / profit 1 / profit 2", n, profits[0], profits[1]);
        assertEq(n, 2, "guard not released: the second trader swap was not rebalanced");
        assertGt(profits[0], 0);
        assertGt(profits[1], 0, "second payment is zero");
        assertEq(gain, profits[0] + profits[1], "recipient not paid exactly twice");
        assertGe(IReentryHook(HOOK).onSwapCalls(), 6, "control: nested calls missing");
        _assertModuleEmpty();
    }
}
