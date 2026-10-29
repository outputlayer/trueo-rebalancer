// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3ForkBase} from "./Blind3ForkBase.sol";
import {TruthMarketHookDemo} from "../../../src/trueo/hook/TruthMarketHookDemo.sol";
import {IOrderManager} from "../../../src/trueo/hook/interfaces/IOrderManager.sol";
import {IERC20Like, ITrueoMarket} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

interface IValidatorView {
    function poolBoundaries(PoolId) external view returns (int24, int24, bool);
}

interface IMarketPause {
    function setPaused(bool) external;
}

interface IHookPause {
    function pausePool(PoolId) external;
}

/// Test-plan items 53, 56-63, 65-66 on the Base fork (block 53172900), real AERO and PUMP markets, real OrderManager,
/// validator and FeeCollector. Baseline = the deployed hook code; run = demo hook + module.
/// Run: BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/blind3/fork/*" -vv
contract Blind3ForkMarketsTest is Blind3ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- 56: gas bound

    function _gasBound(address m, bool yesSide, bool buy, uint256 amt) internal {
        (FRun memory a, FRun memory b) = _fpair(m, yesSide, buy, amt);
        uint256 p = _fActed(m, a, b);
        assertGt(p, 0);
        assertEq(b.modSwaps, 2, "exactly two swaps by the module");
        console.log("profit / gas added", p, _gasAddedF(a, b));
        assertLt(_gasAddedF(a, b), 800_000, "module added >= 800k gas");
    }

    function test_f56_gasBound_AERO_buyYes200() public {
        _gasBound(AERO, true, true, 200e6);
    }

    function test_f56_gasBound_PUMP_sellNo500() public {
        _gasBound(PUMP, false, false, 500e18);
    }

    // ---------------------------------------------------------------- 57: outcomes

    function _buyYesOutcome(address m) internal {
        (FRun memory a, FRun memory b) = _fpair(m, true, true, 200e6);
        _fActed(m, a, b);
        assertTrue(b.evMint);
        console.log("sum no module / module", a.o.sum, b.o.sum);
        assertLt(b.o.sum, a.o.sum, "sum not below the no-module sum");
        assertGe(b.o.sum, 0.999e18, "sum pushed below 0.999");
    }

    function test_f57_AERO_buyYes200() public {
        _buyYesOutcome(AERO);
    }

    function test_f57_PUMP_buyYes200() public {
        _buyYesOutcome(PUMP);
    }

    function test_f57_PUMP_sellNo500() public {
        (FRun memory a, FRun memory b) = _fpair(PUMP, false, false, 500e18);
        _fActed(PUMP, a, b);
        assertFalse(b.evMint);
        assertGt(b.o.sum, a.o.sum, "sum not above the no-module sum");
    }

    // ---------------------------------------------------------------- 58: hook fee and movePoolTick on module swaps

    function test_f58_feeAndOrderHooksOnModuleSwaps_AERO() public {
        (, PoolKey memory kn) = _keys(AERO);
        vm.expectCall(OM, abi.encodeWithSelector(IOrderManager.movePoolTick.selector, kn));
        (FRun memory a, FRun memory b) = _fpair(AERO, true, true, 200e6);
        _fActed(AERO, a, b);
        assertGt(b.o.feeN, a.o.feeN, "no hook fee from the module's NO-pool swap");
        assertGe(b.o.feeY, a.o.feeY);
    }

    // ---------------------------------------------------------------- 59: I6 on the fork

    function _controlAero() internal {
        uint256 s = vm.snapshotState();
        (FRun memory c, FRun memory d) = _fpair(AERO, true, true, 200e6);
        _fActed(AERO, c, d);
        vm.revertToState(s);
    }

    function _idleAero() internal {
        (FRun memory a, FRun memory b) = _fpair(AERO, true, true, 200e6);
        _fIdle(AERO, a, b);
        assertEq(b.nReb, 0);
    }

    function test_f59_pausedThroughSafe_idle() public {
        _controlAero();
        vm.prank(SAFE);
        IMarketPause(AERO).setPaused(true);
        assertTrue(ITrueoMarket(AERO).paused());
        _idleAero();
    }

    function test_f59_finalized_idle() public {
        _controlAero();
        vm.mockCall(AERO, abi.encodeWithSelector(ITrueoMarket.getCurrentStatus.selector), abi.encode(uint8(7)));
        _idleAero();
    }

    function test_f59_noPoolPausedOnHook_idle() public {
        _controlAero();
        (, PoolKey memory kn) = _keys(AERO);
        vm.prank(DEPLOYER);
        IAccessControl(REAL_HOOK).grantRole(keccak256("OPERATOR_ROLE"), address(this));
        IHookPause(REAL_HOOK).pausePool(kn.toId());
        _idleAero();
    }

    // ---------------------------------------------------------------- 60: manipulation

    address internal attacker = makeAddr("attacker");

    function _afterManipulation(bool dumpNo) internal {
        swapHookData = "";
        if (dumpNo) _sellAs(attacker, AERO, false, 2000e18);
        else _buyAs(attacker, AERO, false, 1000e6);
        (FRun memory a, FRun memory b) = _fpair(AERO, true, true, 200e6);
        uint256 p = _fActed(AERO, a, b);
        assertEq(b.evProfit, p);
        assertLt(_dist(b.o.sum), _dist(a.o.sum), "|sum - 1| not reduced");
        console.log("sum no module / module / profit", a.o.sum, b.o.sum, p);
    }

    function test_f60_attackerDumps2000No_thenTrader() public {
        _afterManipulation(true);
    }

    function test_f60_attackerBuysNo1000_thenTrader() public {
        _afterManipulation(false);
    }

    function test_f60_attackerOwnDump_rebalancedInOwnTx() public {
        uint256 s0 = vm.snapshotState();
        swapHookData = RebalanceFlag.encode();
        BalanceDelta dA = _sellAs(attacker, AERO, false, 2000e18);
        uint256 r0 = IERC20Like(TYD).balanceOf(recipient);
        vm.revertToState(s0);
        _installDemo(true);
        vm.recordLogs();
        vm.getRecordedLogs();
        BalanceDelta dB = _sellAs(attacker, AERO, false, 2000e18);
        FRun memory r;
        _fparse(r, vm.getRecordedLogs());
        assertEq(BalanceDelta.unwrap(dA), BalanceDelta.unwrap(dB), "attacker delta differs");
        uint256 gain = IERC20Like(TYD).balanceOf(recipient) - r0;
        assertGe(gain, module.minProfit(), "the attacker's own dump was not rebalanced");
        assertEq(r.nReb, 1);
        assertEq(r.evProfit, gain);
        _assertModuleEmpty(AERO);
    }

    // ---------------------------------------------------------------- 61: huge trade

    function extBuy(address m, uint256 amt) external {
        _ftradeG(m, true, true, amt);
    }

    function test_f61_hugeTrade_AERO() public {
        uint256 amt = 50_000e6;
        swapHookData = RebalanceFlag.encode();
        while (true) {
            uint256 s = vm.snapshotState();
            bool ok;
            try this.extBuy(AERO, amt) {
                ok = true;
            } catch {}
            vm.revertToState(s);
            if (ok) break;
            amt /= 2;
            assertGt(amt, 1e6, "no size passes");
        }
        console.log("largest accepted purchase (halving from 50k TYD)", amt);
        (FRun memory a, FRun memory b) = _fpair(AERO, true, true, amt);
        _fActed(AERO, a, b);
        (PoolKey memory ky, PoolKey memory kn) = _keys(AERO);
        (int24 l1, int24 u1,) = IValidatorView(VALIDATOR).poolBoundaries(ky.toId());
        (int24 l2, int24 u2,) = IValidatorView(VALIDATOR).poolBoundaries(kn.toId());
        assertGe(b.o.tY, l1);
        assertLe(b.o.tY, u1);
        assertGe(b.o.tN, l2);
        assertLe(b.o.tN, u2);
    }

    // ---------------------------------------------------------------- 62: dust vs clean

    function test_f62_dust16PerPool_vsClean_AERO() public {
        (PoolKey memory ky, PoolKey memory kn) = _keys(AERO);
        uint256 s0 = vm.snapshotState();
        (FRun memory c0, FRun memory c1) = _fpair(AERO, true, true, 1000e6);
        uint256 clean = _fActed(AERO, c0, c1);
        vm.revertToState(s0);

        int24 tY = _postTick(AERO, true, true, 1000e6);
        // the module sells YES and NO: YES is currency0 (down from the post-trade tick), AERO NO is currency1 (up)
        _dust(ky, tY, !_saleDownF(ky), 16);
        _dust(kn, _tick(kn), !_saleDownF(kn), 16);
        (FRun memory a, FRun memory b) = _fpair(AERO, true, true, 1000e6);
        uint256 dusty = _fActed(AERO, a, b);
        console.log("profit clean / dust", clean, dusty);
        assertGe(dusty * 1000, clean * 999, "dust cost more than 0.1% of the profit");
        assertLe(_gasAddedF(a, b), 5_000_000);
    }

    // ---------------------------------------------------------------- 63: headroom

    function _headroom(address m, bool yesSide, bool buy, uint256 amt) internal {
        PoolKey memory k = _pool(m, yesSide);
        address tin = buy ? TYD : _outcome(m, yesSide);
        deal(tin, trader, amt * 4);
        vm.prank(trader);
        IERC20Like(tin).approve(address(router), type(uint256).max);
        bool z = Currency.unwrap(k.currency0) == tin;
        bytes memory data = abi.encodeCall(
            PoolSwapTest.swap,
            (
                k,
                SwapParams(z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(false, false),
                RebalanceFlag.encode()
            )
        );
        uint256 s0 = vm.snapshotState();
        _demoCfg(address(0));
        vm.prank(trader);
        uint256 g0 = gasleft();
        (bool okP,) = address(router).call{gas: 30_000_000}(data);
        uint256 plain = g0 - gasleft();
        assertTrue(okP);
        uint256 limit = plain + 1_000_000 + 1_500_000;
        vm.revertToState(s0);

        vm.prank(trader);
        (bool okA, bytes memory retA) = address(router).call{gas: limit}(data); // real hook
        assertTrue(okA);
        FOut memory a = _fsnap(m);
        vm.revertToState(s0);

        fGas = 5_000_000;
        fMin = 750_000; // the hook's default rebalanceGasMin
        _demoCfg(address(module));
        vm.prank(trader);
        (bool okB, bytes memory retB) = address(router).call{gas: limit}(data);
        assertTrue(okB, "trade failed with the module under the tight limit");
        FOut memory b = _fsnap(m);
        assertEq(abi.decode(retA, (int256)), abi.decode(retB, (int256)), "trader delta");
        _assertTraderSameF(a, b);
        assertGe(b.recv, a.recv + module.minProfit(), "no rebalance with plain + reserve + 1.5M");
        _assertModuleEmpty(m);
    }

    function test_f63_headroom_AERO_buyYes200() public {
        _headroom(AERO, true, true, 200e6);
    }

    function test_f63_headroom_PUMP_sellNo500() public {
        _headroom(PUMP, false, false, 500e18);
    }

    // ---------------------------------------------------------------- 53: order fill == outside arbitrage

    function test_f53_orderFill_equalsOutsideArbitrage_PUMP() public {
        (PoolKey memory ky, PoolKey memory kn) = _keys(PUMP);
        Ladder memory l = _orders(kn, 1, 10e6);
        address noT = _outcome(PUMP, false);
        address yesT = _outcome(PUMP, true);
        bool down = _saleDownF(kn); // PUMP NO is currency0: the module's NO sale lowers the tick
        assertTrue(down);
        uint256 s0 = vm.snapshotState();

        uint256 amt = 500e6;
        FRun memory b;
        bool below;
        // 500, 1000, 2000 TYD (4000 is past the YES pool's validator bound on the real hook)
        for (uint256 i; i < 3; i++) {
            vm.revertToState(s0);
            b = _fmod(PUMP, true, true, amt);
            if (b.nReb == 1 && _tick(kn) < l.lo[0]) {
                below = true;
                break;
            }
            amt *= 2;
        }
        assertTrue(below, "the module's NO sale never ended below the order range");
        uint256 x = b.evAmount;
        assertTrue(b.evMint);
        assertTrue(_filled(l, 0), "run A: order not filled");
        uint256 makerA = IERC20Like(noT).balanceOf(l.owners[0]);
        assertGt(makerA, 0);
        console.log("trader TYD / module size / maker NO", amt, x, makerA);

        // run B: real hook, same trade, then an outside account mints x and sells both sides exact-in
        vm.revertToState(s0);
        _fbase(PUMP, true, true, amt);
        address arbB = makeAddr("arbB");
        deal(TYD, arbB, x);
        vm.startPrank(arbB);
        IERC20Like(TYD).approve(PUMP, type(uint256).max);
        ITrueoMarket(PUMP).mint(x);
        IERC20Like(yesT).approve(address(router), type(uint256).max);
        IERC20Like(noT).approve(address(router), type(uint256).max);
        bool zy = Currency.unwrap(ky.currency0) == yesT;
        bool zn = Currency.unwrap(kn.currency0) == noT;
        router.swap(
            ky,
            SwapParams(zy, -int256(x * 1e12), zy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        router.swap(
            kn,
            SwapParams(zn, -int256(x * 1e12), zn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        assertTrue(_filled(l, 0), "run B: order not filled");
        assertEq(IERC20Like(noT).balanceOf(l.owners[0]), makerA, "maker NO differs from the outside arbitrage");
    }

    // ---------------------------------------------------------------- 65: order ladders x gas

    function _ordersXGas(uint256 n) internal {
        (PoolKey memory ky,) = _keys(AERO);
        Ladder memory l = _orders(ky, n, 1e6);
        uint256 s0 = vm.snapshotState();
        fGas = 30_000_000;
        (FRun memory r0, FRun memory r1) = _fpair(AERO, false, true, 10e6);
        uint256 ref = _fActed(AERO, r0, r1);
        uint256 nf = _assertOwnersPaid(l);
        console.log("orders / filled at 30M / 30M profit", n, nf, ref);
        uint32[3] memory gases = [uint32(5_000_000), 10_000_000, 15_000_000];
        for (uint256 i; i < 3; i++) {
            vm.revertToState(s0);
            fGas = gases[i];
            (FRun memory a, FRun memory b) = _fpair(AERO, false, true, 10e6);
            _assertTraderSameF(a.o, b.o);
            _assertModuleEmpty(AERO);
            _assertOwnersPaid(l);
            assertGe(b.o.recv, a.o.recv);
            uint256 p = b.o.recv - a.o.recv;
            console.log("rebalanceGas / profit", gases[i], p);
            if (p != 0) assertEq(p, ref, "a rebalance with less gas has a different size");
            else _fIdle(AERO, a, b);
            assertLe(_gasAddedF(a, b), uint256(gases[i]) + CALL_OVERHEAD);
        }
        fGas = 5_000_000;
    }

    function test_f65_orders24_xGas_AERO() public {
        _ordersXGas(24);
    }

    function test_f65_orders48_xGas_AERO() public {
        _ordersXGas(48);
    }

    // ---------------------------------------------------------------- 66: worst-case griefing

    function _grief(address m, uint256 buyNo) internal {
        (PoolKey memory ky, PoolKey memory kn) = _keys(m);
        int24 tN = _postTick(m, false, true, buyNo);
        // the module sells YES (from the current YES tick) and NO (from the post-trade NO tick)
        _dust(ky, _tick(ky), !_saleDownF(ky), 128);
        _dust(kn, tN, !_saleDownF(kn), 128);
        Ladder memory ly = _orders(ky, 40, 1e6);
        Ladder memory ln = _orders(kn, 40, 1e6);
        uint256 s0 = vm.snapshotState();
        uint32[6] memory gases = [uint32(4_000_000), 5_000_000, 8_000_000, 11_000_000, 14_000_000, 30_000_000];
        for (uint256 i; i < 6; i++) {
            vm.revertToState(s0);
            fGas = gases[i];
            (FRun memory a, FRun memory b) = _fpair(m, false, true, buyNo);
            _assertTraderSameF(a.o, b.o);
            _assertModuleEmpty(m);
            _assertOwnersPaid(ly);
            _assertOwnersPaid(ln);
            assertGe(b.o.recv, a.o.recv, "recipient lost");
            console.log("rebalanceGas / profit / gas added", gases[i], b.o.recv - a.o.recv, _gasAddedF(a, b));
            if (gases[i] >= 8_000_000) {
                assertEq(b.nReb, 1, "no rebalance at >= 8M");
                assertGe(b.o.recv - a.o.recv, module.minProfit());
                assertEq(b.evProfit, b.o.recv - a.o.recv);
            }
        }
        fGas = 5_000_000;
    }

    function test_f66_worstCaseGriefing_AERO() public {
        _grief(AERO, 5000e6);
    }

    function test_f66_worstCaseGriefing_PUMP() public {
        _grief(PUMP, 3000e6);
    }
}
