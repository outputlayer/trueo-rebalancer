// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {MockTruthMarket} from "../mocks/MockTruthMarket.sol";
import {TrapOrderManager} from "../mocks/TrapOrderManager.sol";

/// Test-plan items 40-49: failures and traps. Every "idle" test first proves (control) that the same trade is
/// rebalanced without the failure, so idleness cannot come from a module that never acts.
contract Blind3SafetyTest is Blind3Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// control: from the current state a 50 TYD YES purchase is rebalanced (state restored)
    function _controlActs(int256 amt, bool buy) internal {
        uint256 s = vm.snapshotState();
        (Run memory c, Run memory d) = _pairMain(true, buy, amt);
        _assertActedR(_main(), c, d);
        vm.revertToState(s);
    }

    // ---------------------------------------------------------------- 40

    function test_s40_marketMintReverts_idle() public {
        _controlActs(-50e6, true);
        vm.mockCallRevert(address(market), abi.encodeWithSelector(MockTruthMarket.mint.selector), "x");
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertIdleR(_main(), a, b);
    }

    // ---------------------------------------------------------------- 41

    function test_s41_otherPoolEmpty_idle() public {
        _controlActs(-50e6, true);
        lpRouter.modifyLiquidity(kNo, ModifyLiquidityParams(FULL_LO, FULL_HI, -int256(uint256(LIQ)), 0), "");
        assertEq(poolManager.getLiquidity(kNo.toId()), 0);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertIdleR(_main(), a, b);
    }

    // ---------------------------------------------------------------- 42

    function test_s42_noRoomToBound_idle() public {
        _controlActs(-50e6, true);
        int24 tn = _tick(kNo);
        // NO is currency1 of its pool: the module's NO sale raises the tick; the bound sits just below the price
        assertFalse(_saleDown(kNo));
        validator.setBoundaries(kNo.toId(), 276300, tn - 1);
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertIdleR(_main(), a, b);
        assertEq(_tick(kNo), tn);
    }

    // ---------------------------------------------------------------- 43

    function _cheapIdle(uint256 which) internal {
        _controlActs(-50e6, true);
        if (which == 0) mgr.setPaused(true);
        else if (which == 1) market.setPaused(true);
        else if (which == 2) market.setStatus(7);
        else if (which == 3) {
            hook.grantRole(keccak256("OPERATOR_ROLE"), address(this));
            hook.pausePool(kNo.toId());
        } else {
            market.setCap(yes.totalSupply());
        }
        (Run memory a, Run memory b) = _pairMain(true, true, -50e6);
        _assertIdleR(_main(), a, b);
        console.log("gas added", _gasAdded(a, b));
        assertLe(_gasAdded(a, b), 80_000, "early exit cost > 80k");
    }

    function test_s43_managerPaused_cheapIdle() public {
        _cheapIdle(0);
    }

    function test_s43_marketPaused_cheapIdle() public {
        _cheapIdle(1);
    }

    function test_s43_finalized_cheapIdle() public {
        _cheapIdle(2);
    }

    function test_s43_noPoolPaused_cheapIdle() public {
        _cheapIdle(3);
    }

    function test_s43_tokenCap_cheapIdle() public {
        _cheapIdle(4);
    }

    // ---------------------------------------------------------------- 44 (replaces blind2's vacuous tooLittleGas)

    function test_s44_tooLittleGas_calledButRealNoop() public {
        Mkt memory M = _main();
        T memory t = T(true, true, -200e6, 0);
        _modulePaths(M, t, true, 16, 0, 1, 0xd000);
        hook.setRebalanceGasMin(0);

        // control: with 5M the same trade on the same dusty state is rebalanced
        uint256 s0 = vm.snapshotState();
        cfgGas = 5_000_000;
        (Run memory c, Run memory d) = _pairT(M, t);
        _assertActedR(M, c, d);
        vm.revertToState(s0);

        cfgGas = 300_000;
        vm.expectCall(address(module), _onSwapSel(), 1);
        (Run memory a, Run memory b) = _pairT(M, t);
        assertEq(b.o.recv, a.o.recv, "recipient got something");
        assertEq(b.o.sY, a.o.sY, "YES pool sqrt price differs from the no-module run");
        assertEq(b.o.sN, a.o.sN, "NO pool sqrt price differs from the no-module run");
        _assertIdleR(M, a, b);
        assertLe(_gasAdded(a, b), 300_000 + CALL_OVERHEAD);
    }

    // ---------------------------------------------------------------- 45: all-or-nothing matrix

    function _matrix(uint256 yDust, uint256 nDust, uint256 real) internal {
        Mkt memory M = _main();
        T memory t = T(true, true, -200e6, 0);
        if (yDust + nDust > 0) _modulePaths(M, t, true, yDust, nDust, 1, 0xd000);
        if (real > 0) _modulePaths(M, t, true, real, real, 1e13, 0x5000);
        uint32[4] memory gases = [uint32(1_000_000), 2_500_000, 5_000_000, 30_000_000];
        uint256 s0 = vm.snapshotState();
        for (uint256 i; i < 4; i++) {
            vm.revertToState(s0);
            cfgGas = gases[i];
            (Run memory a, Run memory b) = _pairT(M, t);
            _assertTraderSame(a.o, b.o);
            _assertEmptyM(M);
            assertLe(_gasAdded(a, b), uint256(gases[i]) + CALL_OVERHEAD, "module used more than rebalanceGas");
            assertGe(b.o.recv, a.o.recv, "recipient lost");
            bool acted = b.o.recv > a.o.recv;
            console.log("rebalanceGas / acted / gas added", gases[i], acted ? 1 : 0, _gasAdded(a, b));
            if (acted) {
                assertEq(b.nReb, 1, "(a) one Rebalanced");
                assertEq(b.modSwaps, 2, "(a) exactly two swaps by the module");
                assertEq(b.evProfit, b.o.recv - a.o.recv);
                assertLt(_dist(b.sum), _dist(a.sum), "(a) |sum - 1| not reduced");
            } else {
                assertEq(b.sum, a.sum, "(b) sum differs from the no-module run");
                _assertIdleR(M, a, b);
            }
            if (gases[i] == 30_000_000) assertTrue(acted, "30M: no rebalance");
        }
    }

    function test_s45_matrix_clean() public {
        _matrix(0, 0, 0);
    }

    function test_s45_matrix_dust16Yes() public {
        _matrix(16, 0, 0);
    }

    function test_s45_matrix_dust48Yes() public {
        _matrix(48, 0, 0);
    }

    function test_s45_matrix_dust128Yes() public {
        _matrix(128, 0, 0);
    }

    function test_s45_matrix_dust64No() public {
        _matrix(0, 64, 0);
    }

    function test_s45_matrix_dust64Both() public {
        _matrix(64, 64, 0);
    }

    function test_s45_matrix_real24Both() public {
        _matrix(0, 0, 24);
    }

    // ---------------------------------------------------------------- 46: one shot = one size

    function _oneSize(uint256 total) internal {
        Mkt memory M = _main();
        T memory t = T(true, true, -200e6, 0);
        _modulePaths(M, t, true, total / 2, total / 2, 5e13, 0x7000);
        uint256 s0 = vm.snapshotState();
        cfgGas = 30_000_000;
        (Run memory r0, Run memory r1) = _pairT(M, t);
        uint256 ref = _assertActedR(M, r0, r1);
        assertEq(r1.modSwaps, 2);
        assertLe(_gasAdded(r0, r1), 30_000_000 + CALL_OVERHEAD);
        console.log("ladder / 30M profit", total, ref);
        uint32[3] memory gases = [uint32(2_000_000), 5_000_000, 10_000_000];
        for (uint256 i; i < 3; i++) {
            vm.revertToState(s0);
            cfgGas = gases[i];
            (Run memory a, Run memory b) = _pairT(M, t);
            _assertTraderSame(a.o, b.o);
            _assertEmptyM(M);
            assertLe(_gasAdded(a, b), uint256(gases[i]) + CALL_OVERHEAD);
            uint256 p = b.o.recv - a.o.recv;
            console.log("rebalanceGas / profit", gases[i], p);
            if (p != 0) assertEq(p, ref, "a cell with less gas rebalanced to a different size");
            else _assertIdleR(M, a, b);
        }
    }

    function test_s46_oneSize_ladder24() public {
        _oneSize(24);
    }

    function test_s46_oneSize_ladder48() public {
        _oneSize(48);
    }

    function test_s46_oneSize_ladder100() public {
        _oneSize(100);
    }

    function test_s46_oneSize_ladder200() public {
        _oneSize(200);
    }

    // ---------------------------------------------------------------- 47

    function test_s47_exactlyTwoSwaps_longRealLadders() public {
        Mkt memory M = _main();
        T memory t = T(true, true, -200e6, 0);
        _modulePaths(M, t, true, 12, 12, 5e13, 0x7000);
        cfgGas = 30_000_000;
        (Run memory a, Run memory b) = _pairT(M, t);
        _assertActedR(M, a, b);
        assertEq(b.modSwaps, 2, "exactly two swaps by the module");
    }

    // ---------------------------------------------------------------- 48: dust at the default gas

    function _dustDefault(uint256 n) internal {
        Mkt memory M = _main();
        T memory t = T(true, true, -200e6, 0);
        _modulePaths(M, t, true, n, 0, 1, 0xd000);
        cfgGas = 5_000_000;
        (Run memory a, Run memory b) = _pairT(M, t);
        _assertActedR(M, a, b);
        assertEq(b.modSwaps, 2);
        assertLe(_gasAdded(a, b), 5_000_000);
        console.log("dust / profit / gas added", n, b.evProfit, _gasAdded(a, b));
    }

    function test_s48_dust48_defaultGas() public {
        _dustDefault(48);
    }

    function test_s48_dust64_defaultGas() public {
        _dustDefault(64);
    }

    function test_s48_dust128_defaultGas() public {
        _dustDefault(128);
    }

    function test_s48_dust64_burnSide() public {
        Mkt memory M = _main();
        T memory t = T(true, false, -300e18, 0);
        _modulePaths(M, t, false, 64, 0, 1, 0xd000);
        cfgGas = 5_000_000;
        (Run memory a, Run memory b) = _pairT(M, t);
        _assertActedR(M, a, b);
        assertFalse(b.evMint);
        assertLt(_dist(b.sum), _dist(a.sum), "|sum - 1| not reduced");
    }

    // ---------------------------------------------------------------- 49: expensive crossing in the YES pool

    function _trapRun(uint256 burnGas) internal returns (Run memory a, Run memory b, int24 trapTick, Run memory free) {
        Mkt memory M = _main();
        T memory t = T(true, true, -150e6, 0);
        TrapOrderManager trap = new TrapOrderManager();
        hook.setOrderManager(address(trap));
        int24 t1 = _postTick(M, t, kYes);
        trapTick = t1 - 2 * SPACING; // the module sells YES (currency0): its leg moves the tick down through here
        cfgGas = 5_000_000;
        uint256 s0 = vm.snapshotState();
        // reference: the trap disarmed, the module's YES leg goes past the trap tick
        (, free) = _pairT(M, t);
        vm.revertToState(s0);
        trap.set(PoolId.unwrap(kYes.toId()), trapTick, burnGas);
        (a, b) = _pairT(M, t);
    }

    function test_s49_trapYesPool_10M_idle() public {
        (Run memory a, Run memory b, int24 trapTick, Run memory free) = _trapRun(10_000_000);
        assertLt(free.o.tY, trapTick, "guard: the module never reaches the trap tick");
        assertGt(free.o.recv, a.o.recv, "guard: no rebalance without the trap");
        _assertIdleR(_main(), a, b);
        assertEq(b.sum, a.sum);
    }

    function test_s49_trapYesPool_100k_acts() public {
        (Run memory a, Run memory b, int24 trapTick,) = _trapRun(100_000);
        _assertActedR(_main(), a, b);
        assertLt(b.o.tY, trapTick, "the rebalance did not cross the trap tick");
    }
}
