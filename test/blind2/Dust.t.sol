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
import {Blind2Base} from "./Blind2Base.sol";
import {MathHarness} from "./utils/MathHarness.sol";

/// Property 6: dust liquidity does not zero the module's earnings; too little gas leaves the trade
/// unchanged; RebalanceMath is conservative against a real swap across dust ticks.
contract Blind2DustTest is Blind2Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant N_DUST = 16;

    struct Res {
        uint256 profit;
        uint256 sum;
    }

    /// dust in the traded pool sits between the pre- and post-trade price (trader and module both cross it); in the
    /// other pool it sits where the module's leg moves the price
    function _addDust(bool mintSide, bool inYes, bool inNo) internal {
        // mint side: trader buys YES (YES pool moves in the "buy" direction), module sells NO
        // burn side: trader sells YES, module buys NO
        if (inYes) _ladder(kYes, !mintSide, N_DUST, 1, 0);
        if (inNo) _ladder(kNo, mintSide, N_DUST, 1, 0);
    }

    function _run(bool mintSide, bool inYes, bool inNo) internal returns (Res memory r) {
        _addDust(mintSide, inYes, inNo);
        _plugWith(address(module), REBALANCE_GAS);
        uint256 r0 = tyd.balanceOf(recipient);
        _tradeMain(kYes, mintSide, mintSide ? 50e6 : 80e18, _magic());
        r.profit = tyd.balanceOf(recipient) - r0;
        r.sum = _sum();
        _assertModuleEmpty();
    }

    function _compare(bool mintSide, bool inYes, bool inNo) internal {
        uint256 s0 = vm.snapshotState();
        Res memory clean = _run(mintSide, false, false);
        vm.revertToState(s0);
        Res memory dusty = _run(mintSide, inYes, inNo);
        console.log("profit clean / dust", clean.profit, dusty.profit);
        console.log("sum    clean / dust", clean.sum, dusty.sum);
        assertGt(clean.profit, 0, "no profit without dust: comparison is vacuous");
        assertGt(dusty.profit, 0, "dust zeroed the profit");
        // < 0.1% profit change
        assertLt(_absDiff(clean.profit, dusty.profit) * 1000, clean.profit, "profit changed by >= 0.1%");
        // post-rebalance YES + NO within 0.0002 of the no-dust run
        assertLt(_absDiff(clean.sum, dusty.sum), 0.0002e18, "YES+NO differs by >= 0.0002");
    }

    function test_p6_dust16_yesPool_mint() public {
        _compare(true, true, false);
    }

    function test_p6_dust16_noPool_mint() public {
        _compare(true, false, true);
    }

    function test_p6_dust16_bothPools_mint() public {
        _compare(true, true, true);
    }

    function test_p6_dust16_yesPool_burn() public {
        _compare(false, true, false);
    }

    function test_p6_dust16_noPool_burn() public {
        _compare(false, false, true);
    }

    function test_p6_dust16_bothPools_burn() public {
        _compare(false, true, true);
    }

    /// With dust in both pools and too little rebalanceGas, the trade equals the deployed hook's and the module
    /// holds nothing (a profitable partial rebalance, if any, only adds to the recipient).
    function test_p6_dust_tooLittleGas_tradeUnchanged() public {
        _addDust(true, true, true);
        uint32[5] memory gases = [uint32(30_000), 100_000, 200_000, 350_000, 600_000];
        uint256 s0 = vm.snapshotState();
        for (uint256 i; i < gases.length; i++) {
            vm.revertToState(s0);
            _installOriginal();
            Out memory a = _tradeMain(kYes, true, 50e6, _magic());
            vm.revertToState(s0);
            _plugWith(address(module), gases[i]);
            Out memory b = _tradeMain(kYes, true, 50e6, _magic());
            _assertTraderSame(a, b);
            _assertModuleEmpty();
            assertTrue(b.recv == a.recv || b.recv >= a.recv + MIN_PROFIT);
            // Trueo's fee is never reduced
            assertGe(b.fYt + b.fYy, a.fYt + a.fYy);
            assertGe(b.fNt + b.fNn, a.fNt + a.fNn);
        }
    }

    // ---------------------------------------------------------------- RebalanceMath vs real swaps

    MathHarness internal mh;
    PoolSwapTest internal plain;

    /// hookless, fee-0 pool of `outcome` vs TYD at `priceWad`, full-range LIQ + 16 dust positions in the
    /// direction a sale (sell = true) or purchase moves it
    function _plainPool(address outcome, uint256 priceWad, bool sell) internal returns (PoolKey memory k) {
        (address c0, address c1) = outcome < TYD ? (outcome, TYD) : (TYD, outcome);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, SPACING, IHooks(address(0)));
        poolManager.initialize(k, _sqrtFor(priceWad, c0 == outcome));
        lpRouter.modifyLiquidity(k, ModifyLiquidityParams(FULL_LO, FULL_HI, int256(uint256(LIQ)), 0), "");
        _ladder(k, sell, N_DUST, 1, 0);
    }

    /// initialized dust boundaries strictly crossed between ticks t0 and t1. The ladder (see _ladder) has its
    /// boundaries at base - i * spacing, i = 0..16 (downward) or base + i * spacing, i = 1..17 (upward).
    function _boundariesBetween(PoolKey memory k, bool sell, int24 t0, int24 t1) internal pure returns (uint256 n) {
        bool outIs0 = Currency.unwrap(k.currency0) != TYD;
        bool down = sell ? outIs0 : !outIs0;
        int24 base = _alignDownP(t0, k.tickSpacing);
        (int24 lo, int24 hi) = t0 < t1 ? (t0, t1) : (t1, t0);
        for (uint256 i; i <= N_DUST; i++) {
            int24 b = down ? base - int24(int256(i)) * k.tickSpacing : base + int24(int256(i + 1)) * k.tickSpacing;
            if (b > lo && b <= hi) n++;
        }
    }

    function _alignDownP(int24 t, int24 s) internal pure returns (int24) {
        int24 r = t / s * s;
        if (t < 0 && r != t) r -= s;
        return r;
    }

    function _modelVsReal(address outcome, uint256 priceWad, bool sale, uint256 n) internal {
        mh = new MathHarness(poolManager);
        plain = new PoolSwapTest(poolManager);
        tyd.approve(address(plain), type(uint256).max);
        yes.approve(address(plain), type(uint256).max);
        no.approve(address(plain), type(uint256).max);
        PoolKey memory k = _plainPool(outcome, priceWad, sale);
        bool outIs0 = Currency.unwrap(k.currency0) == outcome;
        // direction: sale of currency0 or purchase of currency1 lowers the price
        bool zeroForOne = sale ? outIs0 : !outIs0;
        int24 t0 = _tick(k);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? t0 - 20_000 : t0 + 20_000);

        (bool ok, uint256 pay, uint256 cap,) = mh.quote(k.toId(), SPACING, outIs0, sale, 0, limit, n);
        assertTrue(ok, "model rejected a size inside its range");
        assertGe(cap, n, "capacity below the tested size");

        // real swap: sale = exact-in n outcome; purchase = exact-out n outcome
        BalanceDelta d = plain.swap(
            k,
            SwapParams(zeroForOne, sale ? -int256(n) : int256(n), limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        int128 tydDelta = outIs0 ? d.amount1() : d.amount0();
        int128 outDelta = outIs0 ? d.amount0() : d.amount1();
        int24 t1 = _tick(k);
        uint256 crossed = _boundariesBetween(k, sale, t0, t1);
        assertGe(crossed, N_DUST, "the swap did not cross the dust ladder");
        uint256 tol = 2 * crossed + 5;
        if (sale) {
            assertEq(uint256(int256(-outDelta)), n, "sale size");
            uint256 real = uint256(int256(tydDelta));
            console.log("sale     model / real", pay, real);
            assertLe(pay, real, "model payout above the real one (not conservative)");
            assertLe(real - pay, tol, "model payout too far below the real one");
        } else {
            assertEq(uint256(int256(outDelta)), n, "purchase size");
            uint256 real = uint256(int256(-tydDelta));
            console.log("purchase model / real", pay, real);
            assertGe(pay, real, "model cost below the real one (not conservative)");
            assertLe(pay - real, tol, "model cost too far above the real one");
        }
    }

    function test_p6_model_sale_yes_acrossDust() public {
        _modelVsReal(YES, 0.6e18, true, 100e18);
    }

    function test_p6_model_purchase_yes_acrossDust() public {
        _modelVsReal(YES, 0.6e18, false, 100e18);
    }

    function test_p6_model_sale_no_acrossDust() public {
        _modelVsReal(NO, 0.4e18, true, 120e18);
    }

    function test_p6_model_purchase_no_acrossDust() public {
        _modelVsReal(NO, 0.4e18, false, 120e18);
    }

    /// odd sizes (fuzz), same bounds, as long as the swap crosses the whole ladder
    function testFuzz_p6_model_conservative(uint256 n, bool sale, bool onYes) public {
        n = bound(n, 90e18, 300e18);
        _modelVsReal(onYes ? YES : NO, onYes ? 0.6e18 : 0.4e18, sale, n);
    }
}
