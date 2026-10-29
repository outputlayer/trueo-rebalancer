// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Blind2Base} from "./Blind2Base.sol";
import {TrueoRebalancer} from "../../src/TrueoRebalancer.sol";
import {TrapOrderManager} from "../mocks/TrapOrderManager.sol";

/// Property 7 (one-shot module): long ladders of real liquidity, and an order-manager trap that makes the module's
/// call run out of gas. The module either completes a profitable rebalance or does nothing.
contract Blind2LadderTest is Blind2Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant LADDER = 48; // positions per pool
    uint128 internal constant RUNG = 5e13; // 5% of the full-range liquidity each: far above any dust threshold
    uint256 internal constant MP = 1_000; // minProfit used here (0.001 TYD)
    /// what the hook's low-level call itself may add on top of rebalanceGas (encoding, cold account, 63/64 slack)
    uint256 internal constant CALL_OVERHEAD = 30_000;

    /// ladders where both the trader (traded pool, both directions) and the module's legs move the prices
    function _ladders() internal {
        _ladder(kYes, false, LADDER, RUNG, 0); // YES bought
        _ladder(kYes, true, LADDER, RUNG, 1_000); // YES sold (salts offset)
        _ladder(kNo, false, LADDER, RUNG, 2_000);
        _ladder(kNo, true, LADDER, RUNG, 3_000);
    }

    function _distance(uint256 s) internal pure returns (uint256) {
        return s > 1e18 ? s - 1e18 : 1e18 - s;
    }

    /// trader result identical, module empty, profit >= minProfit or nothing at all changed, module gas bounded
    function _check(PoolKey memory k, bool buy, uint256 amt) internal returns (bool acted) {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(k, buy, amt, _magic());
        uint256 sumBase = _sum();
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        Out memory b = _tradeMain(k, buy, amt, _magic());
        _assertTraderSame(a, b);
        _assertModuleEmpty();
        acted = b.recv != a.recv;
        if (acted) {
            assertGe(b.recv, a.recv + MP, "profit below minProfit");
            assertLe(_distance(_sum()), _distance(sumBase), "rebalance moved YES+NO away from 1");
            // Trueo's fee only grows
            assertGe(b.fYt, a.fYt);
            assertGe(b.fNt, a.fNt);
        } else {
            _assertIdle(a, b);
        }
        assertLe(b.gas, a.gas + REBALANCE_GAS + CALL_OVERHEAD, "module used more than rebalanceGas");
        vm.revertToState(s0);
    }

    function test_p7_longLadder_mint_actsAndNeverLoses() public {
        _ladders();
        _setMinProfit(MP);
        assertTrue(_check(kYes, true, 150e6), "module idle on a large gap");
    }

    function test_p7_longLadder_burn_actsAndNeverLoses() public {
        _ladders();
        _setMinProfit(MP);
        assertTrue(_check(kNo, false, 250e18), "module idle on a large gap");
    }

    function testFuzz_p7_ladder_neverLoses(uint256 amt, bool buy, bool onYes) public {
        _ladders();
        _setMinProfit(MP);
        amt = buy ? bound(amt, 1e5, 180e6) : bound(amt, 1e17, 400e18); // inside the validator bounds
        // "profit or idle" must not be satisfiable by always idle: a > 3% gap after the trade must be rebalanced
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        _tradeMain(onYes ? kYes : kNo, buy, amt, _magic());
        bool bigGap = _distance(_sum()) > 0.03e18;
        vm.revertToState(s0);
        bool acted = _check(onYes ? kYes : kNo, buy, amt);
        if (bigGap) assertTrue(acted, "module idle on a > 3% gap");
    }

    /// a much longer ladder (dense: 128 rungs per side in the module's direction)
    function test_p7_veryLongLadder_gasBoundedAndNoLoss() public {
        _ladder(kYes, false, 128, RUNG / 4, 0);
        _ladder(kNo, true, 128, RUNG / 4, 5_000);
        _ladder(kYes, true, 128, RUNG / 4, 10_000);
        _ladder(kNo, false, 128, RUNG / 4, 15_000);
        _setMinProfit(MP);
        assertTrue(_check(kYes, true, 200e6), "module idle on a large gap");
        _check(kNo, false, 300e18);
    }

    // ---------------------------------------------------------------- trap: the module's call runs out of gas

    /// k-th initialized boundary (k >= 1) from the current NO-pool tick in the direction the module's NO sale
    /// moves it; the sell-side ladder has its boundaries at base +/- i * SPACING, i >= 1
    function _noSaleBoundary(uint256 k) internal view returns (int24 t, bool down) {
        down = Currency.unwrap(kNo.currency0) != TYD; // selling currency0 lowers the tick
        int24 base = _alignDown(_tick(kNo), SPACING);
        t = down ? base - int24(int256(k)) * SPACING : base + int24(int256(k)) * SPACING;
    }

    struct TrapRun {
        uint256 r0;
        int24 trapTick;
        bool down;
        Out base; // deployed hook
        Out free; // module, trap disarmed
        Out hit; // module, trap armed
    }

    function _beyond(int24 t, int24 trapTick, bool down) internal pure returns (bool) {
        return down ? t < trapTick : t >= trapTick;
    }

    function _trap(uint256 boundary, uint256 burnGas) internal returns (TrapRun memory r) {
        _ladders();
        TrapOrderManager trap = new TrapOrderManager();
        hook.setOrderManager(address(trap));
        (r.trapTick, r.down) = _noSaleBoundary(boundary);
        _setMinProfit(MP);
        r.r0 = tyd.balanceOf(recipient);
        uint256 s0 = vm.snapshotState();

        trap.set(PoolId.unwrap(kNo.toId()), r.trapTick, burnGas);
        _installOriginal();
        r.base = _tradeMain(kYes, true, 150e6, _magic());
        vm.revertToState(s0);

        trap.set(PoolId.unwrap(kNo.toId()), r.trapTick, 0);
        _plugWith(address(module), REBALANCE_GAS);
        r.free = _tradeMain(kYes, true, 150e6, _magic());
        _assertModuleEmpty();
        vm.revertToState(s0);

        trap.set(PoolId.unwrap(kNo.toId()), r.trapTick, burnGas);
        _plugWith(address(module), REBALANCE_GAS);
        r.hit = _tradeMain(kYes, true, 150e6, _magic());

        _assertTraderSame(r.base, r.hit);
        _assertModuleEmpty();
        assertLe(r.hit.gas, r.base.gas + REBALANCE_GAS + CALL_OVERHEAD);
        assertGe(r.hit.recv, r.r0, "recipient lost money");
    }

    /// guard: without the trap the module's NO leg goes past the trap tick and pays (so the trapped run must cross
    /// it); with the trap the whole one-shot call runs out of gas and reverts: no profit, prices and fees as on the
    /// deployed hook, nothing left in the module, trader identical
    function _assertTrapNoop(TrapRun memory r) internal view {
        assertTrue(_beyond(r.free.tN, r.trapTick, r.down), "module never reaches the trap: test is vacuous");
        assertGe(r.free.recv, r.r0 + MP, "no rebalance without the trap");
        _assertIdle(r.base, r.hit);
    }

    /// trap deep in the NO-pool ladder (boundary 14)
    function test_p7_trapDeep_moduleOutOfGas_doesNothing() public {
        _assertTrapNoop(_trap(14, 4_900_000));
    }

    /// trap on the very first boundary the module's NO leg crosses
    function test_p7_trapFirstBoundary_moduleOutOfGas_doesNothing() public {
        _assertTrapNoop(_trap(1, 4_900_000));
    }

    /// trap burning more than rebalanceGas: same
    function test_p7_trapAboveRebalanceGas_doesNothing() public {
        _assertTrapNoop(_trap(5, 6_000_000));
    }

    /// a cheap trap (100k) does not stop the rebalance: it completes and pays
    function test_p7_cheapTrap_rebalanceCompletes() public {
        TrapRun memory r = _trap(14, 100_000);
        assertTrue(_beyond(r.hit.tN, r.trapTick, r.down), "cheap trap stopped the rebalance");
        assertGe(r.hit.recv, r.r0 + MP, "rebalance did not complete");
    }
}
