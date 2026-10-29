// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind2ForkBase} from "./Blind2ForkBase.sol";
import {MultiSwapRouter} from "../utils/MultiSwapRouter.sol";
import {TwoSwapRouter} from "../../mocks/TwoSwapRouter.sol";
import {GasBurnerRebalancer} from "../../mocks/TestRebalancers.sol";
import {TruthMarketHookDemo} from "../../../src/trueo/hook/TruthMarketHookDemo.sol";
import {IERC20Like} from "../../../src/interfaces/ITrueo.sol";
import {RebalanceFlag} from "../../../src/libraries/RebalanceFlag.sol";

/// Fork case matrix F0-F5 + property 9. Every case: module run vs a module-free baseline on the
/// identical state (snapshot/revert), module empty afterwards, a results row in the console.
/// Run: BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/blind2/fork/*" -vv
contract Blind2ForkCasesTest is Blind2ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant CALL_OVERHEAD = 30_000;
    uint256 internal constant DUMP_YES = 10e18; // trader dumps 10 YES: YES + NO falls to ~0.90-0.94
    uint128 internal constant ORDER_TYD = 1e6; // 1 TYD per limit order

    // ---------------------------------------------------------------- F0: storage on Base (property 5)

    /// installing the demo hook over the real one keeps slots 0-6 exactly as on Base; slot 7 packs
    /// rebalancer | rebalanceGas << 160 | reserve << 192 | rebalanceGasMin << 224 (defaults 1M / 750k); slot 8 empty
    function test_F0_storageSlotsAsOnBase() public {
        bytes32[9] memory before;
        for (uint256 i; i < 9; i++) {
            before[i] = vm.load(REAL_HOOK, bytes32(i));
        }
        assertEq(before[7], bytes32(0), "slot 7 used on Base");
        assertEq(before[8], bytes32(0), "slot 8 used on Base");
        _installDemo(true);
        for (uint256 i; i < 7; i++) {
            assertEq(vm.load(REAL_HOOK, bytes32(i)), before[i], "slot 0-6 changed");
        }
        uint256 want = uint256(uint160(address(module))) | (uint256(REBALANCE_GAS) << 160)
            | (uint256(1_000_000) << 192) | (uint256(750_000) << 224);
        assertEq(uint256(vm.load(REAL_HOOK, bytes32(uint256(7)))), want, "slot 7 packing");
        assertEq(vm.load(REAL_HOOK, bytes32(uint256(8))), bytes32(0), "slot 8");
        assertEq(TruthMarketHookDemo(REAL_HOOK).rebalanceGasReserve(), 1_000_000);
    }

    // ---------------------------------------------------------------- F1: dust on real markets

    function _f1(address m, uint256 n) internal {
        (PoolKey memory ky,) = _keys(m);
        uint256 s0 = vm.snapshotState();
        // no-dust module run (reference profit)
        FOut memory cleanBase = _baseline(m, true, false, DUMP_YES);
        vm.revertToState(s0);
        FOut memory clean = _withModule(m, true, false, DUMP_YES);
        uint256 cleanProfit = clean.recv - cleanBase.recv;
        vm.revertToState(s0);

        // dust: n positions of liquidity 1 from the post-trade YES tick upward (the module buys YES back up)
        int24 tPost = _postTick(m, true, false, DUMP_YES);
        _dust(ky, tPost, true, n);
        uint256 s1 = vm.snapshotState();
        FOut memory a = _baseline(m, true, false, DUMP_YES);
        vm.revertToState(s1);
        _installDemo(true);
        vm.recordLogs();
        vm.getRecordedLogs();
        FOut memory b = _ftrade(m, true, false, DUMP_YES);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertTraderSameF(a, b);
        _assertModuleEmpty(m);
        assertEq(_rebalances(logs), 1, "exactly one rebalance");
        assertGt(b.recv, a.recv, "no profit with dust");
        assertLe(b.gas, a.gas + REBALANCE_GAS + CALL_OVERHEAD, "module gas above rebalanceGas");
        console.log("F1 | market | dust | profit | profit no-dust | module gas | sum before | sum after");
        console.log(
            string.concat(
                "F1 | ",
                vm.toString(m),
                " | ",
                vm.toString(n),
                " | ",
                vm.toString(b.recv - a.recv),
                " | ",
                vm.toString(cleanProfit),
                " | ",
                vm.toString(b.gas - a.gas),
                " | ",
                vm.toString(a.sum),
                " | ",
                vm.toString(b.sum)
            )
        );
        vm.revertToState(s0);
    }

    function test_F1_dust48_AERO() public {
        _f1(AERO, 48);
    }

    function test_F1_dust64_AERO() public {
        _f1(AERO, 64);
    }

    function test_F1_dust128_AERO() public {
        _f1(AERO, 128);
    }

    function test_F1_dust48_PUMP() public {
        _f1(PUMP, 48);
    }

    function test_F1_dust64_PUMP() public {
        _f1(PUMP, 64);
    }

    function test_F1_dust128_PUMP() public {
        _f1(PUMP, 128);
    }

    // ---------------------------------------------------------------- F2: real limit-order ladder

    /// trader buys NO (YES + NO above 1 on both markets after it); the module sells YES into a ladder of real
    /// OrderManager orders that buy YES below the price
    function _f2(address m, uint256 n, uint256 buyNo, bool mustFill) internal {
        _f2(m, n, buyNo, mustFill, true);
    }

    function _f2(address m, uint256 n, uint256 buyNo, bool mustFill, bool mustAct) internal {
        (PoolKey memory ky,) = _keys(m);
        Ladder memory l = _orders(ky, n, ORDER_TYD);
        uint256 omYes0 = _omClaims(_outcome(m, true));
        uint256 sumPre = _sum(m);
        uint256 s0 = vm.snapshotState();
        FOut memory a = _baseline(m, false, true, buyNo);
        vm.revertToState(s0);
        FOut memory b = _withModule(m, false, true, buyNo);

        _assertTraderSameF(a, b);
        _assertModuleEmpty(m);
        uint256 nFilled = _assertOwnersPaid(l);
        assertEq(_omClaims(_outcome(m, true)), omYes0, "payment deferred (OrderManager claims grew)");
        assertGe(b.recv, a.recv);
        assertLe(b.gas, a.gas + REBALANCE_GAS + CALL_OVERHEAD, "module gas above rebalanceGas");
        if (b.sY != a.sY || b.sN != a.sN) assertGt(b.recv, a.recv, "module traded without profit");
        if (mustAct) assertGt(b.recv, a.recv, "no profit: module did not act");
        if (mustFill) assertGt(nFilled, 0, "no order filled by the module: case is vacuous");
        uint256 closed = a.sum > 1e18 && a.sum > b.sum ? (a.sum - b.sum) * 100 / (a.sum - 1e18) : 0;
        console.log("F2 | market | orders | filled | gap closed % | profit | module gas | sum pre / after trade / after module");
        console.log(
            string.concat(
                "F2 | ",
                vm.toString(m),
                " | ",
                vm.toString(n),
                " | ",
                vm.toString(nFilled),
                " | ",
                vm.toString(closed),
                " | ",
                vm.toString(b.recv - a.recv),
                " | ",
                vm.toString(b.gas - a.gas),
                " | ",
                string.concat(vm.toString(sumPre), " / ", vm.toString(a.sum), " / ", vm.toString(b.sum))
            )
        );
    }

    function test_F2_orders24_AERO() public {
        _f2(AERO, 24, 10e6, true);
    }

    function test_F2_orders48_AERO() public {
        _f2(AERO, 48, 10e6, true);
    }

    function test_F2_orders24_PUMP() public {
        _f2(PUMP, 24, 50e6, false, true);
    }

    function test_F2_orders48_PUMP() public {
        _f2(PUMP, 48, 50e6, false, true);
    }

    // ---------------------------------------------------------------- F3: multi-swap without the flag

    function _legs(address m, bool mintSide, bytes memory hd) internal view returns (MultiSwapRouter.Leg[] memory l) {
        (PoolKey memory ky, PoolKey memory kn) = _keys(m);
        l = new MultiSwapRouter.Leg[](3);
        PoolKey[3] memory ks = [ky, kn, ky];
        uint256[3] memory buyAmt = [uint256(10e6), 10e6, 5e6];
        uint256[3] memory sellAmt = [uint256(1e18), 20e18, 0.5e18];
        for (uint256 i; i < 3; i++) {
            bool outIs0 = Currency.unwrap(ks[i].currency0) != TYD;
            bool z = mintSide ? !outIs0 : outIs0;
            l[i] = MultiSwapRouter.Leg(ks[i], z, mintSide ? -int256(buyAmt[i]) : -int256(sellAmt[i]), hd);
        }
    }

    function _f3(address m, bool mintSide) internal {
        (PoolKey memory ky, PoolKey memory kn) = _keys(m);
        MultiSwapRouter msr = new MultiSwapRouter(PM);
        msr.watch(ky, kn, FC);
        deal(TYD, address(msr), 1e12);
        deal(_outcome(m, true), address(msr), 1e22);
        deal(_outcome(m, false), address(msr), 1e22);
        TwoSwapRouter two = new TwoSwapRouter(PM);
        deal(TYD, address(two), 1e12);
        deal(_outcome(m, true), address(two), 1e22);
        deal(_outcome(m, false), address(two), 1e22);
        bytes[3] memory hds = [bytes(""), abi.encode(uint256(1)), abi.encodePacked(RebalanceFlag.MAGIC, uint8(0))];
        MultiSwapRouter.Leg[] memory legs;
        uint256 s0 = vm.snapshotState();
        for (uint256 h; h < 3; h++) {
            legs = _legs(m, mintSide, hds[h]);
            vm.revertToState(s0);
            vm.recordLogs();
            vm.getRecordedLogs();
            MultiSwapRouter.Rec[] memory a = msr.run(legs);
            Vm.Log[] memory la = vm.getRecordedLogs();
            uint256[3] memory ca = [_fcClaim(TYD), _fcClaim(_outcome(m, true)), _fcClaim(_outcome(m, false))];

            vm.revertToState(s0);
            _installDemo(true);
            vm.recordLogs();
            vm.getRecordedLogs();
            MultiSwapRouter.Rec[] memory b = msr.run(legs);
            Vm.Log[] memory lb = vm.getRecordedLogs();
            for (uint256 i; i < 3; i++) {
                assertEq(a[i].a0, b[i].a0, "delta0");
                assertEq(a[i].a1, b[i].a1, "delta1");
                assertEq(a[i].s1, b[i].s1, "YES pool price");
                assertEq(a[i].s2, b[i].s2, "NO pool price");
                assertEq(a[i].f1t, b[i].f1t, "fee YES pool c0");
                assertEq(a[i].f1o, b[i].f1o, "fee YES pool c1");
                assertEq(a[i].f2t, b[i].f2t, "fee NO pool c0");
                assertEq(a[i].f2o, b[i].f2o, "fee NO pool c1");
            }
            assertEq(_fcClaim(TYD), ca[0]);
            assertEq(_fcClaim(_outcome(m, true)), ca[1]);
            assertEq(_fcClaim(_outcome(m, false)), ca[2]);
            _assertLogsEqualF(la, lb);
            _assertModuleEmpty(m);
        }

        // the mock TwoSwapRouter (two swaps, both without the word): deltas and end state identical
        bool yOut0 = Currency.unwrap(ky.currency0) != TYD;
        bool nOut0 = Currency.unwrap(kn.currency0) != TYD;
        bool z1 = mintSide ? !yOut0 : yOut0;
        bool z2 = mintSide ? !nOut0 : nOut0;
        uint256 in1 = mintSide ? 10e6 : 1e18;
        uint256 in2 = mintSide ? 10e6 : 20e18;
        vm.revertToState(s0);
        (BalanceDelta d1, BalanceDelta d2) = two.run(ky, z1, in1, kn, z2, in2, trader);
        FOut memory ea = _fsnap(m);
        vm.revertToState(s0);
        _installDemo(true);
        (BalanceDelta e1, BalanceDelta e2) = two.run(ky, z1, in1, kn, z2, in2, trader);
        FOut memory eb = _fsnap(m);
        assertEq(BalanceDelta.unwrap(d1), BalanceDelta.unwrap(e1));
        assertEq(BalanceDelta.unwrap(d2), BalanceDelta.unwrap(e2));
        assertEq(ea.sY, eb.sY);
        assertEq(ea.sN, eb.sN);
        assertEq(ea.feeY, eb.feeY);
        assertEq(ea.feeN, eb.feeN);
        assertEq(ea.recv, eb.recv);
        _assertModuleEmpty(m);
        console.log(string.concat("F3 | ", vm.toString(m), mintSide ? " | mint" : " | burn", " | identical"));
    }

    function _fcClaim(address token) internal view returns (uint256) {
        return PM.balanceOf(FC, uint256(uint160(token)));
    }

    function _assertLogsEqualF(Vm.Log[] memory a, Vm.Log[] memory b) internal pure {
        assertEq(a.length, b.length, "log count");
        for (uint256 i; i < a.length; i++) {
            assertEq(a[i].emitter, b[i].emitter, "log emitter");
            assertEq(a[i].data, b[i].data, "log data");
            assertEq(a[i].topics.length, b[i].topics.length);
            for (uint256 j; j < a[i].topics.length; j++) {
                assertEq(a[i].topics[j], b[i].topics[j], "log topic");
            }
        }
    }

    function test_F3_noFlag_multiSwap_AERO_mint() public {
        _f3(AERO, true);
    }

    function test_F3_noFlag_multiSwap_AERO_burn() public {
        _f3(AERO, false);
    }

    function test_F3_noFlag_multiSwap_PUMP_mint() public {
        _f3(PUMP, true);
    }

    function test_F3_noFlag_multiSwap_PUMP_burn() public {
        _f3(PUMP, false);
    }

    // ---------------------------------------------------------------- F4: gas sweep with ladders

    function _swapCall(PoolKey memory k, bool zeroForOne, uint256 amt) internal view returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                k,
                SwapParams(
                    zeroForOne, -int256(amt), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                RebalanceFlag.encode()
            )
        );
    }

    function _tryAt(bytes memory data, uint256 g) internal returns (bool ok, int256 d) {
        vm.prank(trader);
        bytes memory ret;
        (ok, ret) = address(router).call{gas: g}(data);
        if (ok) d = abi.decode(ret, (int256));
    }

    /// smallest gas at which `data` succeeds on the demo hook with rebalancer 0 (binary search, state restored)
    function _thresholdDemo(bytes memory data, uint256 s0) internal returns (uint256) {
        uint256 lo = 50_000;
        uint256 hi = 3_000_000;
        while (hi - lo > 100) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(s0);
            _installDemo(false);
            (bool ok,) = _tryAt(data, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function test_F4_gasSweep_AERO_ladders() public {
        address m = AERO;
        (PoolKey memory ky, PoolKey memory kn) = _keys(m);
        _orders(ky, 24, ORDER_TYD);
        _dust(ky, _tick(ky), false, 48);
        // trader buys NO with 10 TYD, opted in
        deal(TYD, trader, 1e12);
        vm.prank(trader);
        IERC20Like(TYD).approve(address(router), type(uint256).max);
        bool z = Currency.unwrap(kn.currency0) == TYD;
        bytes memory data = _swapCall(kn, z, 10e6);
        uint256 s0 = vm.snapshotState();

        // reference: unlimited gas
        _installDemo(true);
        (bool okRef,) = _tryAt(data, 30_000_000);
        assertTrue(okRef);
        FOut memory ref = _fsnap(m);
        vm.revertToState(s0);
        _installDemo(false); // "without the rebalancer" = the same demo hook code, rebalancer 0
        (bool okB0,) = _tryAt(data, 30_000_000);
        assertTrue(okB0);
        FOut memory base0 = _fsnap(m);
        assertGt(ref.recv, base0.recv, "module never rebalances here: sweep is vacuous");
        _assertModuleEmpty(m);

        uint256 g0 = _thresholdDemo(data, s0);
        console.log("F4 | AERO | min trader gas without rebalancer (demo hook)", g0);
        uint256 minFull;
        uint256 partials;
        for (uint256 g = g0 + 5_000; g <= 12_000_000; g += 237_000) {
            vm.revertToState(s0);
            _installDemo(false);
            (bool okA, int256 dA) = _tryAt(data, g);
            FOut memory a = _fsnap(m);
            vm.revertToState(s0);
            _installDemo(true);
            (bool okB, int256 dB) = _tryAt(data, g);
            FOut memory b = _fsnap(m);
            if (!okA) continue;
            assertTrue(okB, "trade fails with the module where it succeeds without");
            assertEq(dA, dB, "trader delta");
            assertEq(a.trT, b.trT);
            assertEq(a.trN, b.trN);
            _assertModuleEmpty(m);
            assertGe(b.recv, a.recv, "module lost money");
            if (b.sY != a.sY || b.sN != a.sN) {
                assertGt(b.recv, a.recv, "module traded without profit");
                if (b.sY == ref.sY && b.sN == ref.sN) {
                    if (minFull == 0) minFull = g;
                } else {
                    partials++;
                }
            }
        }
        assertGt(minFull, 0, "no full rebalance anywhere in the sweep");
        console.log("F4 | AERO | min trader gas for a full rebalance", minFull);
        console.log("F4 | AERO | partial rebalances in sweep", partials);
        console.log("F4 | AERO | full-rebalance profit", ref.recv - base0.recv);
    }

    // ---------------------------------------------------------------- F5 / property 9: pay before sell

    struct F5Run {
        uint256 profit;
        uint256 nFilled;
        uint160 target;
        uint256[] ownerYes;
        bool[] filled;
    }

    /// module case: the PoolManager holds none of the YES token; returns what the owners got
    function _f5ModuleCase(address m, Ladder memory l) internal returns (F5Run memory r) {
        address yesT = _outcome(m, true);
        deal(yesT, address(PM), 0);
        uint256 omYes0 = _omClaims(yesT);
        uint256 s1 = vm.snapshotState();
        FOut memory a = _baseline(m, false, true, 10e6);
        vm.revertToState(s1);
        FOut memory b = _withModule(m, false, true, 10e6);
        _assertTraderSameF(a, b);
        _assertModuleEmpty(m);
        assertGt(b.recv, a.recv, "module did not rebalance");
        r.profit = b.recv - a.recv;
        r.nFilled = _assertOwnersPaid(l); // each filled owner holds exactly its fill
        assertGt(r.nFilled, 0, "no order filled by the module's sale: case is vacuous");
        assertEq(_omClaims(yesT), omYes0, "PaymentDeferred: owner not paid in the same transaction");
        r.ownerYes = new uint256[](l.owners.length);
        r.filled = new bool[](l.owners.length);
        for (uint256 i; i < l.owners.length; i++) {
            r.ownerYes[i] = IERC20Like(yesT).balanceOf(l.owners[i]);
            r.filled[i] = _filled(l, i);
        }
        r.target = b.sY;
    }

    /// outside-arbitrage case: normal balances, real hook, one swap selling YES down to the module's final price
    function _f5ArbCase(address m, Ladder memory l, F5Run memory r) internal returns (uint256 arbFilled) {
        address yesT = _outcome(m, true);
        _baseline(m, false, true, 10e6);
        address arb = makeAddr("arb");
        deal(yesT, arb, 1e24);
        vm.startPrank(arb);
        IERC20Like(yesT).approve(address(router), type(uint256).max);
        bool z = Currency.unwrap(l.k.currency0) == yesT;
        router.swap(l.k, SwapParams(z, -int256(1e24), r.target), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        (uint160 sArb,,,) = PM.getSlot0(l.k.toId());
        assertEq(sArb, r.target, "arbitrage did not reach the module's price");
        // the module's swaps may take a different path to the price than one outside swap, so it may fill MORE
        // orders than the outside swap; every owner the arbitrage pays is paid at least as much
        for (uint256 i; i < l.owners.length; i++) {
            if (_filled(l, i)) {
                arbFilled++;
                assertTrue(r.filled[i], "an order the outside arbitrage fills was not filled by the module");
                assertGe(r.ownerYes[i], IERC20Like(yesT).balanceOf(l.owners[i]), "owner paid less than by arbitrage");
            }
        }
    }

    function test_F5_p9_payBeforeSell_realOrder_AERO() public {
        (PoolKey memory ky,) = _keys(AERO);
        Ladder memory l = _orders(ky, 24, ORDER_TYD);
        uint256 s0 = vm.snapshotState();
        F5Run memory r = _f5ModuleCase(AERO, l);
        vm.revertToState(s0);
        uint256 arbFilled = _f5ArbCase(AERO, l, r);
        assertGe(r.nFilled, arbFilled);
        console.log(
            string.concat(
                "F5 | AERO | orders 24 | filled by module ",
                vm.toString(r.nFilled),
                " | by outside arb ",
                vm.toString(arbFilled),
                " | profit ",
                vm.toString(r.profit),
                " | no deferral"
            )
        );
    }

    // ---------------------------------------------------------------- F6: route, word on the LAST hop (§9.2 rule)

    function _routeTry(address two, bytes memory data, uint256 g) internal returns (bool ok, uint256 used) {
        uint256 before = gasleft();
        (ok,) = two.call{gas: g}(data);
        used = before - gasleft();
    }

    function _demoWith(address r) internal {
        _installDemo(false);
        vm.startPrank(DEPLOYER);
        TruthMarketHookDemo(REAL_HOOK).setRebalancer(r);
        TruthMarketHookDemo(REAL_HOOK).setRebalanceGas(REBALANCE_GAS);
        vm.stopPrank();
    }

    /// Two-hop route on AERO: hop 1 sells YES into real OrderManager orders (fills them, no word), hop 2 buys NO
    /// with the opt-in word (the last Trueo hop). For every gas limit at which the route succeeds without a
    /// rebalancer (same demo hook, rebalancer 0) it also succeeds with a gas-burning rebalancer, and the burner
    /// fires.
    function test_F6_route_wordOnLastHop_firstHopFillsOrders_burnerSweep() public {
        (PoolKey memory ky, PoolKey memory kn) = _keys(AERO);
        Ladder memory l = _orders(ky, 24, ORDER_TYD);
        GasBurnerRebalancer burner = new GasBurnerRebalancer();
        TwoSwapRouter two = new TwoSwapRouter(PM);
        deal(TYD, address(two), 1e12);
        deal(_outcome(AERO, true), address(two), 1e22);
        two.setHookData("", RebalanceFlag.encode());
        bool z1 = Currency.unwrap(ky.currency0) != TYD; // sell YES
        bool z2 = Currency.unwrap(kn.currency0) == TYD; // buy NO
        bytes memory data = abi.encodeCall(TwoSwapRouter.run, (ky, z1, 60e18, kn, z2, 10e6, trader));
        uint256 s0 = vm.snapshotState();

        // guard: hop 1 really fills orders
        _demoWith(address(burner));
        (bool okTop, uint256 usedTop) = _routeTry(address(two), data, 30_000_000);
        assertTrue(okTop);
        uint256 nFilled = _assertOwnersPaid(l);
        assertGt(nFilled, 0, "hop 1 filled no order");
        assertGe(usedTop, REBALANCE_GAS, "burner did not get rebalanceGas with plenty of gas");

        // threshold without the rebalancer
        uint256 lo = 50_000;
        uint256 hi = 6_000_000;
        while (hi - lo > 100) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(s0);
            _demoWith(address(0));
            (bool ok,) = _routeTry(address(two), data, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 g0 = hi;

        uint256 fired;
        for (uint256 g = g0 + 5_000; g <= 9_000_000; g += 173_011) {
            vm.revertToState(s0);
            _demoWith(address(0));
            (bool okBase, uint256 usedBase) = _routeTry(address(two), data, g);
            vm.revertToState(s0);
            _demoWith(address(burner));
            (bool ok, uint256 used) = _routeTry(address(two), data, g);
            if (okBase) assertTrue(ok, "route fails with a gas-burning rebalancer where it succeeds without");
            if (ok && okBase && used >= usedBase + 700_000) fired++; // just under rebalanceGasMin (750k)
        }
        assertGt(fired, 5, "the burner never fired: sweep proves nothing");
        console.log("F6 | AERO | orders filled by hop 1", nFilled);
        console.log("F6 | AERO | min route gas without rebalancer", g0);
        console.log("F6 | AERO | sweep points where the burner fired", fired);
    }
}
