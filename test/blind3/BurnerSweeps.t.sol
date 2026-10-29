// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Blind3HookBase} from "./Blind3HookBase.sol";
import {GasBurnerRebalancer} from "../mocks/TestRebalancers.sol";
import {TwoSwapRouter} from "../mocks/TwoSwapRouter.sol";

/// Test-plan items 18-19 (I1 + I9): gas-limit sweeps with a rebalancer that burns all the gas it gets. At every
/// trader gas limit where the trade succeeds with rebalancer = 0 it must also succeed with the burner.
/// Hook only: no module needed.
contract Blind3BurnerSweepTest is Blind3HookBase {
    /// the burner "fired": the trade used at least this much more gas than the same trade without it
    uint256 internal constant FIRED = 700_000; // just under the default rebalanceGasMin (750k)

    GasBurnerRebalancer internal burner;
    TwoSwapRouter internal two;

    enum Case {
        BuyYes50, // single swap: buy YES for 50 TYD (mint side)
        SellYes200, // single swap: sell 200 YES (burn side)
        RouteMintWordLast, // TwoSwapRouter: buy NO 30 TYD, then buy YES 50 TYD (word on hop 2)
        RouteBurnWordLast, // TwoSwapRouter: sell 100 NO, then sell 200 YES (word on hop 2)
        RouteSellYesThenBuyNoWordFirst // TwoSwapRouter: sell 200 YES (word), then buy NO 10 TYD
    }

    function setUp() public override {
        super.setUp();
        burner = new GasBurnerRebalancer();
        two = new TwoSwapRouter(poolManager);
        tyd.transfer(address(two), 1e10);
        yes.transfer(address(two), 1e22);
        no.transfer(address(two), 1e22);
        hook.setRebalanceGas(5_000_000);
    }

    function _call(Case c) internal returns (address to, bytes memory data, bool asTrader) {
        if (c == Case.BuyYes50) return (address(router), _swapData(kYes, true, 50e6, _flag()), true);
        if (c == Case.SellYes200) return (address(router), _swapData(kYes, false, 200e18, _flag()), true);
        if (c == Case.RouteMintWordLast) {
            two.setHookData("", _flag());
            return (
                address(two),
                abi.encodeCall(TwoSwapRouter.run, (kNo, _zfo(kNo, true), 30e6, kYes, _zfo(kYes, true), 50e6, trader)),
                false
            );
        }
        if (c == Case.RouteBurnWordLast) {
            two.setHookData("", _flag());
            return (
                address(two),
                abi.encodeCall(
                    TwoSwapRouter.run, (kNo, _zfo(kNo, false), 100e18, kYes, _zfo(kYes, false), 200e18, trader)
                ),
                false
            );
        }
        two.setHookData(_flag(), "");
        return (
            address(two),
            abi.encodeCall(TwoSwapRouter.run, (kYes, _zfo(kYes, false), 200e18, kNo, _zfo(kNo, true), 10e6, trader)),
            false
        );
    }

    function _try(Case c, address r, uint256 g, uint256 s0) internal returns (bool ok, uint256 used) {
        vm.revertToState(s0);
        hook.setRebalancer(r);
        (address to, bytes memory data, bool asTrader) = _call(c);
        (ok, used) = _callG(to, data, g, asTrader);
    }

    /// sweep [gLo, gHi]: step `fine` up to `fineTo`, `coarse` after. Returns the number of firings.
    function _sweep(Case c, uint256 gLo, uint256 gHi, uint256 fine, uint256 fineTo, uint256 coarse)
        internal
        returns (uint256 fired, uint256 passedBase)
    {
        uint256 s0 = vm.snapshotState();
        for (uint256 g = gLo; g <= gHi; g += (g < fineTo ? fine : coarse)) {
            (bool okBase, uint256 usedBase) = _try(c, address(0), g, s0);
            if (!okBase) continue;
            passedBase++;
            (bool ok, uint256 used) = _try(c, address(burner), g, s0);
            assertTrue(ok, string.concat("trade fails with the burner at gas limit ", vm.toString(g)));
            if (used >= usedBase + FIRED) {
                fired++;
                assertLe(used, usedBase + 5_000_000 + CALL_OVERHEAD, "burner got more than rebalanceGas");
            }
        }
        vm.revertToState(s0);
    }

    // ---------------------------------------------------------------- 18: reserve at the floor, min 0

    function _floorSweep(Case c) internal {
        hook.setRebalanceGasReserve(150_000);
        hook.setRebalanceGasMin(0);
        (uint256 fired, uint256 passed) = _sweep(c, 200_000, 7_000_000, 10_000, 2_800_000, 200_000);
        console.log("limits passing without the rebalancer / burner fired", passed, fired);
        assertGt(passed, 200, "sweep too sparse");
        assertGt(fired, 100, "the burner fired at too few limits: sweep proves little");
    }

    function test_g18_floorSweep_buyYes50() public {
        _floorSweep(Case.BuyYes50);
    }

    function test_g18_floorSweep_sellYes200() public {
        _floorSweep(Case.SellYes200);
    }

    function test_g18_floorSweep_routeMint_wordOnLastHop() public {
        _floorSweep(Case.RouteMintWordLast);
    }

    function test_g18_floorSweep_routeBurn_wordOnLastHop() public {
        _floorSweep(Case.RouteBurnWordLast);
    }

    // ---------------------------------------------------------------- 19: burn side at the default reserve

    function _defaultSweep(Case c) internal {
        assertEq(hook.rebalanceGasReserve(), 1_000_000);
        assertEq(hook.rebalanceGasMin(), 750_000, "default rebalanceGasMin");
        (uint256 fired, uint256 passed) = _sweep(c, 200_000, 9_000_000, 20_000, 3_500_000, 250_000);
        console.log("limits passing without the rebalancer / burner fired", passed, fired);
        assertGt(passed, 120, "sweep too sparse");
        assertGt(fired, 30, "the burner fired at too few limits: sweep proves little");
        // at the top the burner received all of rebalanceGas
        uint256 s0 = vm.snapshotState();
        (bool okB, uint256 usedB) = _try(c, address(0), 9_000_000, s0);
        (bool ok, uint256 used) = _try(c, address(burner), 9_000_000, s0);
        assertTrue(okB && ok);
        assertGe(used, usedB + 5_000_000 - 1_000, "burner did not get rebalanceGas at 9M");
    }

    function test_g19_defaultReserveSweep_sellYes200() public {
        _defaultSweep(Case.SellYes200);
    }

    function test_g19_defaultReserveSweep_route_sellYesWordFirst_thenBuyNo() public {
        _defaultSweep(Case.RouteSellYesThenBuyNoWordFirst);
    }
}
