// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Blind3HookBase} from "./Blind3HookBase.sol";
import {TruthMarketHookDemo} from "../../src/trueo/hook/TruthMarketHookDemo.sol";
import {RecordingRebalancer} from "../mocks/TestRebalancers.sol";
import {MockOrderManager} from "../mocks/MockOrderManager.sol";

/// Test-plan items 10-16: the demo hook's gate and setters. Hook only: no module needed.
contract Blind3HookGateTest is Blind3HookBase {
    using PoolIdLibrary for PoolKey;

    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event RebalanceGasUpdated(uint32 oldGas, uint32 newGas);
    event RebalanceGasReserveUpdated(uint32 oldReserve, uint32 newReserve);

    RecordingRebalancer internal rec;
    /// hook default rebalanceGasMin (spec change: 750k, was 1M)
    uint32 internal constant DEFAULT_MIN = 750_000;

    function setUp() public override {
        super.setUp();
        rec = new RecordingRebalancer(poolManager, address(fc), uint256(uint160(YES)));
    }

    // ---------------------------------------------------------------- 10: reserve floor

    function test_g10_reserveFloor() public {
        assertEq(hook.MIN_REBALANCE_GAS_RESERVE(), 150_000);
        assertEq(hook.rebalanceGasReserve(), 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(TruthMarketHookDemo.RebalanceGasReserveBelowFloor.selector, 0, 150_000));
        hook.setRebalanceGasReserve(0);
        assertEq(hook.rebalanceGasReserve(), 1_000_000, "changed by a reverted call");

        vm.expectRevert(
            abi.encodeWithSelector(TruthMarketHookDemo.RebalanceGasReserveBelowFloor.selector, 149_999, 150_000)
        );
        hook.setRebalanceGasReserve(149_999);
        assertEq(hook.rebalanceGasReserve(), 1_000_000, "changed by a reverted call");

        vm.expectEmit(false, false, false, true, HOOK);
        emit RebalanceGasReserveUpdated(1_000_000, 150_000);
        hook.setRebalanceGasReserve(150_000);
        assertEq(hook.rebalanceGasReserve(), 150_000);

        // floor holds after a lower value was set too
        vm.expectRevert(
            abi.encodeWithSelector(TruthMarketHookDemo.RebalanceGasReserveBelowFloor.selector, 149_999, 150_000)
        );
        hook.setRebalanceGasReserve(149_999);
        assertEq(hook.rebalanceGasReserve(), 150_000);

        hook.setRebalanceGasReserve(type(uint32).max);
        assertEq(hook.rebalanceGasReserve(), type(uint32).max);
    }

    // ---------------------------------------------------------------- 11 / 13: no call, no cold-account charge

    /// gas of an opted-in 50 TYD YES purchase with every touched account cooled first
    function _cooledTradeGas() internal returns (uint256 used) {
        _coolAll(address(rec));
        (bool ok, uint256 u) = _callG(address(router), _swapData(kYes, true, 50e6, _flag()), 30_000_000, true);
        assertTrue(ok, "trade failed");
        used = u;
    }

    function _noCallCase(bool minZero) internal {
        uint256 s0 = vm.snapshotState();
        // reference: no rebalancer at all
        hook.setRebalancer(address(0));
        uint256 g0 = _cooledTradeGas();
        Out memory a = _snapOut(kYes, kNo);
        vm.revertToState(s0);

        hook.setRebalancer(address(rec));
        assertEq(hook.rebalanceGas(), 0);
        if (minZero) hook.setRebalanceGasMin(0);
        uint256 g1 = _cooledTradeGas();
        Out memory b = _snapOut(kYes, kNo);
        assertEq(rec.calls(), 0, "rebalancer called with rebalanceGas 0");
        _assertAllSame(a, b);
        console.log("gas no rebalancer / rebalancer with gas 0", g0, g1);
        assertApproxEqAbs(g1, g0, 500, "rebalanceGas 0 costs more than the gate check");

        // control: a zero-gas CALL to the cold rebalancer would be visible (calls with gas > 0 are)
        vm.revertToState(s0);
        hook.setRebalancer(address(rec));
        hook.setRebalanceGas(1_000_000);
        _cooledTradeGas();
        assertEq(rec.calls(), 1, "control: rebalancer not called with gas");
    }

    function test_g11_rebalanceGasZero_noCall_noColdAccountCharge() public {
        _noCallCase(false);
    }

    function test_g13_minZero_gasZero_noCall() public {
        _noCallCase(true);
    }

    // ---------------------------------------------------------------- 12: below min / at min

    function test_g12_gasBelowMin_noCall_atMin_called() public {
        hook.setRebalancer(address(rec));
        uint32 mn = hook.rebalanceGasMin();
        assertEq(mn, DEFAULT_MIN, "default rebalanceGasMin");
        uint256 s0 = vm.snapshotState();

        hook.setRebalanceGas(mn / 2);
        (bool ok,) = _callG(address(router), _swapData(kYes, true, 50e6, _flag()), 30_000_000, true);
        assertTrue(ok);
        assertEq(rec.calls(), 0, "called with rebalanceGas below rebalanceGasMin");
        vm.revertToState(s0);

        hook.setRebalanceGas(mn - 1);
        (ok,) = _callG(address(router), _swapData(kYes, true, 50e6, _flag()), 30_000_000, true);
        assertTrue(ok);
        assertEq(rec.calls(), 0, "called one gas below the min");
        vm.revertToState(s0);

        hook.setRebalanceGas(mn);
        (ok,) = _callG(address(router), _swapData(kYes, true, 50e6, _flag()), 30_000_000, true);
        assertTrue(ok);
        assertEq(rec.calls(), 1, "not called with rebalanceGas == rebalanceGasMin");
    }

    // ---------------------------------------------------------------- 14: code removed

    function test_g14_rebalancerCodeRemoved_tradeIdentical() public {
        uint256 s0 = vm.snapshotState();
        hook.setRebalancer(address(0));
        Out memory a = _tradeMain(kYes, true, 50e6, _flag());
        Out memory a2 = _tradeMain(kYes, false, 80e18, _flag());
        vm.revertToState(s0);

        hook.setRebalancer(address(rec));
        hook.setRebalanceGas(5_000_000);
        vm.etch(address(rec), "");
        assertEq(address(rec).code.length, 0);
        assertEq(address(hook.rebalancer()), address(rec));
        Out memory b = _tradeMain(kYes, true, 50e6, _flag());
        Out memory b2 = _tradeMain(kYes, false, 80e18, _flag());
        _assertAllSame(a, b);
        _assertAllSame(a2, b2);
    }

    // ---------------------------------------------------------------- 15: setter events

    function test_g15_setterEvents_andAdminOnlyMin() public {
        vm.expectEmit(true, true, false, true, HOOK);
        emit RebalancerUpdated(address(0), address(rec));
        hook.setRebalancer(address(rec));

        RecordingRebalancer rec2 = new RecordingRebalancer(poolManager, address(fc), 0);
        vm.expectEmit(true, true, false, true, HOOK);
        emit RebalancerUpdated(address(rec), address(rec2));
        hook.setRebalancer(address(rec2));

        vm.expectEmit(false, false, false, true, HOOK);
        emit RebalanceGasUpdated(0, 7);
        hook.setRebalanceGas(7);
        assertEq(hook.rebalanceGas(), 7);

        vm.expectEmit(false, false, false, true, HOOK);
        emit RebalanceGasUpdated(7, 1_500_000);
        hook.setRebalanceGas(1_500_000);

        vm.expectEmit(true, true, false, true, HOOK);
        emit RebalancerUpdated(address(rec2), address(0));
        hook.setRebalancer(address(0));

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, trader, bytes32(0))
        );
        hook.setRebalanceGasMin(1);
        assertEq(hook.rebalanceGasMin(), DEFAULT_MIN, "changed by a reverted call");
    }

    // ---------------------------------------------------------------- 16: called last

    function test_g16_rebalancerCalledAfterMovePoolTick() public {
        hook.setRebalancer(address(rec));
        hook.setRebalanceGas(1_500_000);
        hook.setRebalanceGasMin(750_000);
        PoolId pid = kYes.toId();
        _startRec();
        _tradeMain(kYes, true, 50e6, _flag());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 moved = type(uint256).max;
        uint256 called = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(om) && logs[i].topics[0] == MockOrderManager.Moved.selector
                    && logs[i].topics[1] == PoolId.unwrap(pid) && moved == type(uint256).max
            ) moved = i;
            if (logs[i].emitter == address(rec) && logs[i].topics[0] == RecordingRebalancer.Called.selector) {
                assertEq(called, type(uint256).max, "called twice");
                called = i;
            }
        }
        assertTrue(moved != type(uint256).max, "no movePoolTick for the trader swap");
        assertTrue(called != type(uint256).max, "rebalancer not called");
        assertGt(called, moved, "rebalancer called before movePoolTick");
        // the fee of the trader swap was already minted when the rebalancer ran (fee step precedes the call)
        assertEq(rec.claimsSeen(), poolManager.balanceOf(address(fc), uint256(uint160(YES))));
        assertGt(rec.claimsSeen(), 0);
        assertEq(rec.calls(), 1);
    }
}
