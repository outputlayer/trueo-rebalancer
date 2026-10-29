// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Blind3Base} from "./Blind3Base.sol";
import {MathHarness3} from "./utils/MathHarness3.sol";

/// Test-plan items 50-52: RebalanceMath against real v4 swaps.
contract Blind3ModelTest is Blind3Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint128 internal constant RUNG = 1e14; // real liquidity: 10% of the full-range position per rung

    MathHarness3 internal mh;
    PoolSwapTest internal plain;

    function setUp() public override {
        super.setUp();
        mh = new MathHarness3(poolManager);
        plain = new PoolSwapTest(poolManager);
        tyd.approve(address(plain), type(uint256).max);
        yes.approve(address(plain), type(uint256).max);
        no.approve(address(plain), type(uint256).max);
    }

    /// hookless, fee-0 pool of `outcome` vs TYD at `priceWad` with full-range LIQ, plus `rungs` one-spacing real
    /// positions next to the price in the direction the trade moves it
    function _plainPool(address outcome, uint256 priceWad, bool sale, uint256 rungs)
        internal
        returns (PoolKey memory k, int24 lastBoundary)
    {
        (address c0, address c1) = outcome < TYD ? (outcome, TYD) : (TYD, outcome);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, SPACING, IHooks(address(0)));
        poolManager.initialize(k, _sqrtFor(priceWad, c0 == outcome));
        lpRouter.modifyLiquidity(k, ModifyLiquidityParams(FULL_LO, FULL_HI, int256(uint256(LIQ)), 0), "");
        if (rungs > 0) (, lastBoundary) = _ladder(k, sale, rungs, RUNG, 0);
    }

    function _p(PoolKey memory k, bool outIs0, bool sale, uint24 fee, uint160 limit)
        internal
        pure
        returns (MathHarness3.P memory)
    {
        return MathHarness3.P(k.toId(), k.tickSpacing, outIs0, sale, fee, limit);
    }

    // ---------------------------------------------------------------- 50

    function _modelVsReal(address outcome, uint256 priceWad, bool sale, uint256 rungs, uint256 n) internal {
        (PoolKey memory k, int24 last) = _plainPool(outcome, priceWad, sale, rungs);
        bool outIs0 = Currency.unwrap(k.currency0) == outcome;
        bool zeroForOne = sale == outIs0; // selling currency0 / buying currency1 lowers the price
        int24 t0 = _tick(k);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? t0 - 20_000 : t0 + 20_000);
        MathHarness3.P memory p = _p(k, outIs0, sale, 0, limit);

        assertGe(mh.capacity(p), n, "capacity below the tested size");
        (bool ok, uint256 pay) = mh.payFor(p, n);
        assertTrue(ok, "model rejected a size inside its range");
        (bool wok,, uint160 sModel) = mh.walk(p, n);
        assertTrue(wok);

        BalanceDelta d = plain.swap(
            k,
            SwapParams(zeroForOne, sale ? -int256(n) : int256(n), limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        int128 tydDelta = outIs0 ? d.amount1() : d.amount0();
        int128 outDelta = outIs0 ? d.amount0() : d.amount1();
        (uint160 sReal, int24 t1,,) = poolManager.getSlot0(k.toId());
        // the real swap went past the whole ladder
        if (zeroForOne) assertLt(t1, last, "swap did not cross the ladder");
        else assertGe(t1, last, "swap did not cross the ladder");

        // test plan: conservative side only, 2 wei per crossed initialized boundary + a small constant.
        // A ladder of `rungs` consecutive positions has rungs + 1 boundaries, all crossed (asserted above).
        uint256 tol = 2 * ((rungs + 1) + 3);
        if (sale) {
            assertEq(uint256(int256(-outDelta)), n);
            uint256 real = uint256(int256(tydDelta));
            console.log("sale     model / real", pay, real);
            assertLe(pay, real, "modelled payout above the real one");
            assertLe(real - pay, tol, "modelled payout too far below the real one");
        } else {
            assertEq(uint256(int256(outDelta)), n);
            uint256 real = uint256(int256(-tydDelta));
            console.log("purchase model / real", pay, real);
            assertGe(pay, real, "modelled cost below the real one");
            assertLe(pay - real, tol, "modelled cost too far above the real one");
        }
        // end price within 1e-9 (relative, on the sqrt price)
        assertApproxEqRel(uint256(sModel), uint256(sReal), 1e9, "modelled end price");
    }

    function _both(address outcome, uint256 priceWad, bool sale, uint256 n3, uint256 n10) internal {
        uint256 s0 = vm.snapshotState();
        _modelVsReal(outcome, priceWad, sale, 3, n3);
        vm.revertToState(s0);
        _modelVsReal(outcome, priceWad, sale, 10, n10);
    }

    /// YES is currency0: a sale moves the price down, a purchase up
    function test_m50_sale_outcomeCurrency0_priceDown() public {
        _both(YES, 0.6e18, true, 40e18, 100e18);
    }

    function test_m50_purchase_outcomeCurrency0_priceUp() public {
        _both(YES, 0.6e18, false, 40e18, 100e18);
    }

    /// NO is currency1: a sale moves the tick up, a purchase down
    function test_m50_sale_outcomeCurrency1_tickUp() public {
        _both(NO, 0.4e18, true, 50e18, 130e18);
    }

    function test_m50_purchase_outcomeCurrency1_tickDown() public {
        _both(NO, 0.4e18, false, 50e18, 130e18);
    }

    function testFuzz_m50_modelVsReal(uint256 n, bool sale, bool onYes) public {
        n = bound(n, 120e18, 400e18);
        _modelVsReal(onYes ? YES : NO, onYes ? 0.6e18 : 0.4e18, sale, 10, n);
    }

    // ---------------------------------------------------------------- 51

    function _stopsAtLimit(address outcome, uint256 priceWad, bool sale) internal {
        (PoolKey memory k,) = _plainPool(outcome, priceWad, sale, 3);
        bool outIs0 = Currency.unwrap(k.currency0) == outcome;
        bool zeroForOne = sale == outIs0;
        int24 t0 = _tick(k);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? t0 - 600 : t0 + 600);
        MathHarness3.P memory p = _p(k, outIs0, sale, 0, limit);
        uint256 cap = mh.capacity(p);
        assertGt(cap, 0);
        (bool ok,, uint160 s) = mh.walk(p, cap);
        assertTrue(ok, "largest tradable amount reported as not tradable");
        if (zeroForOne) assertGe(s, limit, "modelled price past the limit");
        else assertLe(s, limit, "modelled price past the limit");
        (bool pok,) = mh.payFor(p, cap);
        assertTrue(pok);

        (bool wok2,,) = mh.walk(p, cap + 1e18);
        assertFalse(wok2, "walk accepts an amount past the limit");
        try mh.payFor(p, cap + 1e18) returns (bool ok2, uint256) {
            assertFalse(ok2, "payFor accepts an amount past the limit");
        } catch {}

        // a real swap to the limit moves at least `cap` (the model is conservative)
        BalanceDelta d = plain.swap(
            k,
            SwapParams(zeroForOne, sale ? -int256(cap + 1e21) : int256(cap + 1e21), limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 sReal,,,) = poolManager.getSlot0(k.toId());
        assertEq(sReal, limit, "real swap did not reach the limit");
        int128 od = outIs0 ? d.amount0() : d.amount1();
        uint256 realOut = od < 0 ? uint256(int256(-od)) : uint256(int256(od));
        console.log("capacity / real amount to the limit", cap, realOut);
        // capacity: at most a few wei more than a real swap can trade before the limit, and not far below it
        assertLe(cap, realOut + 8, "capacity above what the pool can trade before the limit");
        assertApproxEqRel(cap, realOut, 1e12, "capacity far below the real amount");
    }

    function test_m51_stopsAtLimit_sale_c0() public {
        _stopsAtLimit(YES, 0.6e18, true);
    }

    function test_m51_stopsAtLimit_purchase_c0() public {
        _stopsAtLimit(YES, 0.6e18, false);
    }

    function test_m51_stopsAtLimit_sale_c1() public {
        _stopsAtLimit(NO, 0.4e18, true);
    }

    function test_m51_stopsAtLimit_purchase_c1() public {
        _stopsAtLimit(NO, 0.4e18, false);
    }

    // ---------------------------------------------------------------- 52

    function _pairModelVsReal(bool mint, int256 amt) internal {
        uint256 s0 = vm.snapshotState();
        (Run memory a, Run memory b) = _pairMain(true, mint, amt);
        uint256 moduleProfit = _assertActedR(_main(), a, b);
        uint256 x = b.evAmount;
        assertEq(b.evMint, mint);
        vm.revertToState(s0);

        _unplug();
        _tradeMain(kYes, mint, uint256(-amt), _magic());
        // YES is currency0 (sale lowers the tick), NO is currency1 (sale raises it); limits = validator bounds
        MathHarness3.P memory py = _p(
            kYes, true, mint, LP_FEE, TickMath.getSqrtPriceAtTick(mint ? int24(-887160) : int24(-276360))
        );
        MathHarness3.P memory pn = _p(
            kNo, false, mint, LP_FEE, TickMath.getSqrtPriceAtTick(mint ? int24(887220) : int24(276300))
        );
        int256 model = mh.estimateProfit(py, pn, x, 1e12, HOOK_FEE);
        int256 real = mint ? _outsideMintSell(x) : _outsideBuyBurn(x);
        console.log("size / module profit", x, moduleProfit);
        console.logInt(model);
        console.logInt(real);
        assertLe(model, real, "model profit above the real one");
        assertLe(real - model, 8, "model profit more than 8 units below the real one");
        assertGe(model, int256(module.minProfit()), "module acted on a model profit below minProfit");
    }

    function test_m52_pairProfitModelVsReal_mint() public {
        _pairModelVsReal(true, -100e6);
    }

    function test_m52_pairProfitModelVsReal_burn() public {
        _pairModelVsReal(false, -300e18);
    }
}
