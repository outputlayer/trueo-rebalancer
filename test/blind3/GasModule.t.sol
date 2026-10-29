// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {TwoSwapRouter} from "../mocks/TwoSwapRouter.sol";

/// Test-plan items 17, 20, 21: the real module under trader gas limits.
contract Blind3GasModuleTest is Blind3Base {
    TwoSwapRouter internal two;

    function setUp() public override {
        super.setUp();
        two = new TwoSwapRouter(poolManager);
        tyd.transfer(address(two), 1e10);
        yes.transfer(address(two), 1e22);
        no.transfer(address(two), 1e22);
    }

    function _single(PoolKey memory k, bool buy, uint256 amt) internal view returns (address, bytes memory, bool) {
        bool z = _zfo(k, buy);
        return (
            address(router),
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    k,
                    SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    _magic()
                )
            ),
            true
        );
    }

    function _callR(address to, bytes memory data, uint256 g, bool asTrader)
        internal
        returns (bool ok, uint256 used, bytes memory ret)
    {
        if (asTrader) vm.prank(trader);
        uint256 before = gasleft();
        (ok, ret) = to.call{gas: g}(data);
        used = before - gasleft();
    }

    /// gas of the call with rebalancer 0 (state restored)
    function _plain(address to, bytes memory data, bool asTrader) internal returns (uint256 used) {
        uint256 s = vm.snapshotState();
        _unplug();
        bool ok;
        (ok, used,) = _callR(to, data, 30_000_000, asTrader);
        assertTrue(ok, "plain trade failed");
        vm.revertToState(s);
    }

    // ---------------------------------------------------------------- 17: below-min skip is cheap

    function _skipCheap(bool buy, uint256 amt, uint32 minGas, uint256 above) internal {
        (address to, bytes memory data, bool asT) = _single(kYes, buy, amt);
        if (minGas != 0) hook.setRebalanceGasMin(minGas);
        uint256 s0 = vm.snapshotState();
        uint256 plain = _plain(to, data, asT);
        uint256 limit = plain + hook.rebalanceGasReserve() + above;

        _unplug();
        (bool okA, uint256 usedA,) = _callR(to, data, limit, asT);
        assertTrue(okA);
        Out memory a = _snapOut(kYes, kNo);
        vm.revertToState(s0);

        hook.setRebalancer(address(module));
        hook.setRebalanceGas(5_000_000);
        vm.expectCall(address(module), _onSwapSel(), 0);
        (bool ok, uint256 used,) = _callR(to, data, limit, asT);
        assertTrue(ok);
        Out memory b = _snapOut(kYes, kNo);
        _assertIdle(a, b);
        console.log("skip: gas no module / module plugged", usedA, used);
        assertLt(used, usedA + 10_000, "skipping the module costs >= 10k");
        vm.revertToState(s0);
    }

    function test_g17_belowMinSkipIsCheap_buyYes() public {
        _skipCheap(true, 50e6, 0, 500_000);
    }

    function test_g17_belowMinSkipIsCheap_sellYes200() public {
        _skipCheap(false, 200e18, 0, 500_000);
    }

    function test_g17_highMin_skipIsCheap_buyYes() public {
        _skipCheap(true, 50e6, 3_000_000, 1_500_000);
    }

    function test_g17_highMin_skipIsCheap_sellYes200() public {
        _skipCheap(false, 200e18, 3_000_000, 1_500_000);
    }

    /// control for 17: with plenty of gas the same trades do rebalance (the skip is not "never acts")
    function test_g17_control_plentyOfGas_acts() public {
        cfgGas = 5_000_000;
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertActedR(_main(), a, b);
    }

    // ---------------------------------------------------------------- 20: real-module sweeps

    function _moduleSweep(address to, bytes memory data, bool asT, bool route) internal {
        uint256 s0 = vm.snapshotState();
        uint256 captured;
        uint256 passed;
        for (uint256 g = 200_000; g <= 7_000_000; g += (g < 1_800_000 ? 100_000 : 25_000)) {
            vm.revertToState(s0);
            _unplug();
            (bool okA,, bytes memory retA) = _callR(to, data, g, asT);
            if (!okA) continue;
            passed++;
            Out memory a = _snapOut(kYes, kNo);
            vm.revertToState(s0);
            hook.setRebalancer(address(module));
            hook.setRebalanceGas(5_000_000);
            (bool ok,, bytes memory ret) = _callR(to, data, g, asT);
            assertTrue(ok, string.concat("trade fails with the module at gas limit ", vm.toString(g)));
            Out memory b = _snapOut(kYes, kNo);
            if (route) {
                (int256 d1A,) = abi.decode(retA, (int256, int256));
                (int256 d1B,) = abi.decode(ret, (int256, int256));
                assertEq(d1A, d1B, "hop-1 delta differs");
            } else {
                assertEq(abi.decode(retA, (int256)), abi.decode(ret, (int256)), "trader delta differs");
                _assertTraderSame(a, b);
            }
            _assertModuleEmpty();
            assertGe(b.recv, a.recv, "recipient lost");
            if (b.recv > a.recv) {
                assertGe(b.recv, a.recv + MIN_PROFIT);
                captured++;
            } else if (!route) {
                _assertIdle(a, b);
            }
        }
        console.log("limits passing / module captured", passed, captured);
        assertGt(captured, 100, "module captured at too few limits");
    }

    function test_g20_moduleSweep_mint_single() public {
        (address to, bytes memory data, bool asT) = _single(kYes, true, 50e6);
        _moduleSweep(to, data, asT, false);
    }

    function test_g20_moduleSweep_burn_single() public {
        (address to, bytes memory data, bool asT) = _single(kYes, false, 200e18);
        _moduleSweep(to, data, asT, false);
    }

    function test_g20_moduleSweep_mint_route_wordOnHop1() public {
        two.setHookData(_magic(), "");
        _moduleSweep(
            address(two),
            abi.encodeCall(TwoSwapRouter.run, (kYes, _zfo(kYes, true), 50e6, kNo, _zfo(kNo, true), 10e6, trader)),
            false,
            true
        );
    }

    function test_g20_moduleSweep_burn_route_wordOnHop1() public {
        two.setHookData(_magic(), "");
        _moduleSweep(
            address(two),
            abi.encodeCall(
                TwoSwapRouter.run, (kYes, _zfo(kYes, false), 200e18, kNo, _zfo(kNo, false), 50e18, trader)
            ),
            false,
            true
        );
    }

    // ---------------------------------------------------------------- 21: headroom, burn side

    function test_g21_headroom_burnSide_sell200Yes() public {
        (address to, bytes memory data, bool asT) = _single(kYes, false, 200e18);
        uint256 s0 = vm.snapshotState();
        uint256 plain = _plain(to, data, asT);
        uint256 limit = plain + 1_000_000 + 1_500_000;
        _unplug();
        (bool okA, uint256 usedA,) = _callR(to, data, limit, asT);
        assertTrue(okA);
        Out memory a = _snapOut(kYes, kNo);
        vm.revertToState(s0);
        hook.setRebalancer(address(module));
        hook.setRebalanceGas(5_000_000);
        vm.expectCall(address(module), _onSwapSel(), 1);
        _startRec();
        (bool ok, uint256 used,) = _callR(to, data, limit, asT);
        uint256 nReb = _rebalances(vm.getRecordedLogs());
        assertTrue(ok);
        Out memory b = _snapOut(kYes, kNo);
        _assertTraderSame(a, b);
        _assertActed(a, b, MIN_PROFIT);
        assertEq(nReb, 1);
        assertLt(used, usedA + 1_500_000, "module added >= 1.5M gas");
    }
}
