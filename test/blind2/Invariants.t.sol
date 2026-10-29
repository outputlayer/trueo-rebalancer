// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Blind2Base} from "./Blind2Base.sol";
import {RevertingRebalancer, GasBurnerRebalancer, RecordingRebalancer} from "../mocks/TestRebalancers.sol";
import {MockOrderManager} from "../mocks/MockOrderManager.sol";

/// Property 11: invariants I1-I10 with OPTED-IN swaps.
contract Blind2InvariantsTest is Blind2Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function _pair(address r, PoolKey memory k, bool buy, uint256 amt)
        internal
        returns (Out memory a, Out memory b)
    {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        a = _tradeMain(k, buy, amt, _magic());
        vm.revertToState(s0);
        _plugWith(r, REBALANCE_GAS);
        b = _tradeMain(k, buy, amt, _magic());
    }

    // ---------------------------------------------------------------- I1 + I2

    function test_I1_failingRebalancers_tradePassesUnchanged() public {
        address[2] memory rs = [address(new RevertingRebalancer()), address(new GasBurnerRebalancer())];
        uint256 s0 = vm.snapshotState();
        for (uint256 i; i < 2; i++) {
            vm.revertToState(s0);
            (Out memory a, Out memory b) = _pair(rs[i], kYes, true, 50e6);
            _assertAllSame(a, b);
        }
    }

    function _gap(uint256 sum_) internal pure returns (uint256) {
        return sum_ > 1e18 ? sum_ - 1e18 : 1e18 - sum_;
    }

    /// I2: the opted-in trader's result equals the deployed hook's to the wei; the module either delivers at
    /// least minProfit or changes nothing; it never keeps tokens. Not satisfiable by "always idle": whenever the
    /// trade leaves |YES + NO - 1| > 3% (far above LP + 0.8% hook fees + threshold) the module must act.
    function testFuzz_I2_traderIdentical(uint256 amt, bool buy, bool onYes) public {
        amt = buy ? bound(amt, 1, 180e6) : bound(amt, 1, 600e18); // stays inside the validator bounds
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(onYes ? kYes : kNo, buy, amt, _magic());
        uint256 gapAfterTrade = _gap(_sum());
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        Out memory b = _tradeMain(onYes ? kYes : kNo, buy, amt, _magic());
        _assertTraderSame(a, b);
        if (gapAfterTrade > 0.03e18) _assertActed(a, b, MIN_PROFIT);
        if (b.recv == a.recv) _assertIdle(a, b);
        else _assertActed(a, b, MIN_PROFIT);
    }

    /// I2, deterministic companion: eight trades (both pools, both sides, two sizes) that must all be
    /// rebalanced, each with the trader identical to the deployed hook
    function test_I2_traderIdentical_knownGaps_allAct() public {
        uint256[2] memory buys = [uint256(50e6), 120e6];
        uint256[2] memory sells = [uint256(80e18), 300e18];
        for (uint256 p; p < 2; p++) {
            for (uint256 side; side < 2; side++) {
                for (uint256 z; z < 2; z++) {
                    bool buy = side == 0;
                    (Out memory a, Out memory b) =
                        _pair(address(module), p == 0 ? kYes : kNo, buy, buy ? buys[z] : sells[z]);
                    _assertTraderSame(a, b);
                    _assertActed(a, b, MIN_PROFIT);
                }
            }
        }
    }

    // ---------------------------------------------------------------- I3

    /// Trueo's fee: the trader's fee unchanged (claims seen when the module is called = deployed-hook claims);
    /// the module's swaps add fees in the other pool
    function test_I3_feeNotReduced_moduleSwapsPayFees() public {
        (Out memory a, Out memory b) = _pair(address(module), kYes, true, 50e6);
        _assertActed(a, b, MIN_PROFIT);
        assertGe(b.fYt, a.fYt);
        assertGe(b.fYy, a.fYy);
        assertGe(b.fNt, a.fNt);
        assertGe(b.fNn, a.fNn);
        assertGt(b.fNt + b.fNn, a.fNt + a.fNn, "module's NO-pool swap paid no hook fee");
        assertGe(b.c6909t, a.c6909t);
        assertGe(b.c6909y, a.c6909y);
        assertGe(b.c6909n, a.c6909n);
        assertGt(b.c6909t + b.c6909y + b.c6909n, a.c6909t + a.c6909y + a.c6909n);
    }

    function test_I3_traderFeeIdenticalAtCallTime() public {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(kYes, true, 50e6, _magic());
        vm.revertToState(s0);
        // YES bought with TYD exact-in: the unspecified currency is YES
        RecordingRebalancer rec = new RecordingRebalancer(poolManager, address(fc), uint256(uint160(YES)));
        _plugWith(address(rec), REBALANCE_GAS);
        Out memory b = _tradeMain(kYes, true, 50e6, _magic());
        assertEq(rec.calls(), 1);
        assertEq(PoolId.unwrap(rec.lastPool()), PoolId.unwrap(kYes.toId()));
        assertEq(rec.claimsSeen(), a.c6909y, "fee already minted when the rebalancer runs");
        _assertAllSame(a, b);
    }

    // ---------------------------------------------------------------- I4

    /// the hook's order-manager callback runs for the module's swaps on BOTH pools; the last callback of each
    /// pool reports that pool's final price
    function test_I4_orderManagerSeesModuleSwapsOnBothPools() public {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        Out memory a = _tradeMain(kYes, true, 50e6, _magic());
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        _startRec();
        Out memory b = _tradeMain(kYes, true, 50e6, _magic());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertActed(a, b, MIN_PROFIT);
        (uint256 nY, int24 toY, uint160 pY) = _lastMoved(logs, kYes.toId());
        (uint256 nN, int24 toN, uint160 pN) = _lastMoved(logs, kNo.toId());
        assertGe(nY, 2, "YES pool: trader + module callbacks");
        assertGe(nN, 1, "NO pool: module callback missing");
        assertEq(toY, b.tY);
        assertEq(pY, b.sY);
        assertEq(toN, b.tN);
        assertEq(pN, b.sN);
    }

    function _lastMoved(Vm.Log[] memory logs, PoolId id) internal view returns (uint256 n, int24 to, uint160 p) {
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(om) && logs[i].topics[0] == MockOrderManager.Moved.selector
                    && logs[i].topics[1] == PoolId.unwrap(id)
            ) {
                n++;
                (, to, p) = abi.decode(logs[i].data, (int24, int24, uint160));
            }
        }
    }

    // ---------------------------------------------------------------- I5

    /// a validator bound two spacings from the NO price, in the direction the module's NO sale moves it: the
    /// module rebalances partially and stays inside the bound
    function test_I5_validatorBoundRespected_partialRebalance() public {
        int24 t = _tick(kNo);
        bool down = Currency.unwrap(kNo.currency0) != TYD; // NO sale lowers the tick iff NO is currency0
        if (down) validator.setBoundaries(kNo.toId(), t - 120, 887220);
        else validator.setBoundaries(kNo.toId(), 276300, t + 120);
        (Out memory a, Out memory b) = _pair(address(module), kYes, true, 50e6);
        _assertTraderSame(a, b);
        _assertActed(a, b, MIN_PROFIT);
        if (down) assertGe(b.tN, t - 120);
        else assertLe(b.tN, t + 120);
    }

    /// bound exactly at the current NO tick: at most a move inside the current tick; never past the bound
    function test_I5_validatorBoundAtPrice_neverCrossed() public {
        int24 t = _tick(kNo);
        bool down = Currency.unwrap(kNo.currency0) != TYD;
        if (down) validator.setBoundaries(kNo.toId(), t, 887220);
        else validator.setBoundaries(kNo.toId(), 276300, t);
        (Out memory a, Out memory b) = _pair(address(module), kYes, true, 50e6);
        _assertTraderSame(a, b);
        _assertModuleEmpty();
        assertEq(b.tN, t, "NO pool left its tick past the bound");
        assertTrue(b.recv == a.recv || b.recv >= a.recv + MIN_PROFIT);
    }

    /// bound one spacing away: the module still acts, up to (never past) the bound
    function test_I5_validatorBoundOneSpacingAway_actsAndStops() public {
        int24 t = _tick(kNo);
        bool down = Currency.unwrap(kNo.currency0) != TYD;
        if (down) validator.setBoundaries(kNo.toId(), t - 60, 887220);
        else validator.setBoundaries(kNo.toId(), 276300, t + 60);
        (Out memory a, Out memory b) = _pair(address(module), kYes, true, 50e6);
        _assertTraderSame(a, b);
        _assertActed(a, b, MIN_PROFIT);
        if (down) assertGe(b.tN, t - 60);
        else assertLe(b.tN, t + 60);
        assertTrue(b.tN != t, "NO leg did not move toward the bound");
    }

    // ---------------------------------------------------------------- I6

    function _idleWhen(uint256 which) internal {
        if (which == 0) market.setPaused(true);
        else if (which == 1) mgr.setPaused(true);
        else if (which == 2) market.setStatus(7);
        else if (which == 3) market.setCap(yes.totalSupply());
        else if (which == 4) {
            hook.grantRole(keccak256("OPERATOR_ROLE"), address(this));
            hook.pausePool(kNo.toId()); // the pool the module would trade next
        } else if (which == 5) {
            vm.prank(admin);
            module.setEnabled(false);
        }
        (Out memory a, Out memory b) = _pair(address(module), kYes, true, 50e6);
        _assertIdle(a, b);
    }

    function test_I6_marketPaused_idle() public {
        _idleWhen(0);
    }

    function test_I6_managerPaused_idle() public {
        _idleWhen(1);
    }

    function test_I6_finalized_idle() public {
        _idleWhen(2);
    }

    function test_I6_tokenCapReached_idle() public {
        _idleWhen(3);
    }

    function test_I6_otherPoolPaused_idle() public {
        _idleWhen(4);
    }

    function test_I6_moduleDisabled_idle() public {
        _idleWhen(5);
    }

    function test_I6_burnSide_paused_and_finalized_idle() public {
        uint256 s0 = vm.snapshotState();
        market.setPaused(true);
        (Out memory a, Out memory b) = _pair(address(module), kYes, false, 80e18);
        _assertIdle(a, b);
        vm.revertToState(s0);
        market.setStatus(7);
        (a, b) = _pair(address(module), kYes, false, 80e18);
        _assertIdle(a, b);
    }

    // ---------------------------------------------------------------- I7

    /// balances after = balances before (here: a stray donation sitting in the module stays exactly as is)
    function test_I7_moduleBalancesUnchanged_withStrayTokens() public {
        tyd.transfer(address(module), 5e6);
        yes.transfer(address(module), 3e18);
        (Out memory a, Out memory b) = _pair(address(module), kYes, true, 50e6);
        _assertTraderSame(a, b);
        assertEq(tyd.balanceOf(address(module)), 5e6);
        assertEq(yes.balanceOf(address(module)), 3e18);
        assertEq(no.balanceOf(address(module)), 0);
        assertGt(b.recv, a.recv, "the trade did not cause a rebalance");
    }

    function test_I7_noBalancesBetweenCalls_manyTrades() public {
        _plugWith(address(module), REBALANCE_GAS);
        swapHookData = _magic();
        uint256 r0 = tyd.balanceOf(recipient);
        for (uint256 i; i < 8; i++) {
            if (i % 4 == 0) _buy(kYes, YES, 30e6);
            else if (i % 4 == 1) _sell(kNo, NO, 40e18);
            else if (i % 4 == 2) _buy(kNo, NO, 25e6);
            else _sell(kYes, YES, 35e18);
            _assertModuleEmpty();
            assertEq(poolManager.balanceOf(address(module), uint256(uint160(TYD))), 0);
            assertEq(poolManager.balanceOf(address(module), uint256(uint160(YES))), 0);
            assertEq(poolManager.balanceOf(address(module), uint256(uint160(NO))), 0);
        }
        assertGt(tyd.balanceOf(recipient), r0);
    }

    // ---------------------------------------------------------------- I9

    function test_I9_gasBoundedByRebalanceGas() public {
        uint32[4] memory g = [uint32(60_000), 250_000, 1_000_000, 5_000_000];
        for (uint256 i; i < g.length; i++) {
            uint256 s0 = vm.snapshotState();
            _installOriginal();
            Out memory a = _tradeMain(kYes, true, 50e6, _magic());
            vm.revertToState(s0);
            _plugWith(address(module), g[i]);
            Out memory b = _tradeMain(kYes, true, 50e6, _magic());
            _assertTraderSame(a, b);
            _assertModuleEmpty();
            assertLe(b.gas, a.gas + g[i] + 30_000, "module exceeded rebalanceGas");
            // with 1M+ the module rebalances (design target: module gas <= ~350k) while staying within the bound
            if (g[i] >= 1_000_000) assertGt(b.recv, a.recv, "module did not act within rebalanceGas");
            vm.revertToState(s0);
        }
    }

    // ---------------------------------------------------------------- I10

    /// rebalancer = 0 with the opt-in word on every swap: bit-identical to the deployed hook, logs included
    function test_I10_noRebalancer_flagged_bitIdentical() public {
        uint256 s0 = vm.snapshotState();
        _installOriginal();
        _startRec();
        Out memory a = _tradeMain(kYes, true, 50e6, _magic());
        Out memory a2 = _tradeMain(kNo, false, 70e18, _magic());
        Vm.Log[] memory la = vm.getRecordedLogs();
        vm.revertToState(s0);
        _plugWith(address(module), REBALANCE_GAS);
        _unplug();
        _startRec();
        Out memory b = _tradeMain(kYes, true, 50e6, _magic());
        Out memory b2 = _tradeMain(kNo, false, 70e18, _magic());
        Vm.Log[] memory lb = vm.getRecordedLogs();
        _assertAllSame(a, b);
        _assertAllSame(a2, b2);
        _assertLogsEqual(la, lb);
    }
}
