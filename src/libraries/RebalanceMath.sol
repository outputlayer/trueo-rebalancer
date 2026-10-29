// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Sizing for a YES/NO rebalance on two v4 pools. Each pool is read as a piecewise-constant-liquidity
/// curve (initialized ticks walked like Pool.swap does), so the model matches v4 swap math up to rounding.
/// x = payment-token units; n = x * scale outcome units (scale = 10 ** (outcome decimals - payment decimals)).
/// mint (YES + NO > 1): mint x, sell n YES and n NO exact-in. burn (YES + NO < 1): buy n of each exact-out, burn.
library RebalanceMath {
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PIPS = 1e6;
    uint256 internal constant HOOK_FEE_DENOMINATOR = 10_000;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    /// Hard cap on the boundaries (initialized ticks and bitmap-word ends) read per pool, which sizes the curve's
    /// arrays (memory safety). The walk normally ends earlier: at the validator bound or at the stop rule.
    uint256 internal constant MAX_WALK = 128;
    /// an initialized tick whose |liquidityNet| * DUST_DIVISOR <= the liquidity in force is dust: it is applied
    /// to the running liquidity but does not open a new segment (the segment keeps the lowest liquidity seen)
    uint256 internal constant DUST_DIVISOR = 1e6;
    /// payment units Pool.swap may round against the trader at each step boundary the trade crosses: a boundary
    /// merged into a segment (the amounts and the LP fee are rounded at it) or a segment edge (the LP fee is
    /// rounded up at every step, the model rounds it once per pool)
    uint256 internal constant ROUND_PER_STEP = 2;
    uint256 internal constant MAX_STEPS = 64;
    /// bisection stops once the bracket is within 1/256 of its upper end (measured on local ladders at 30M: 1/64
    /// left up to 0.76% of the gap on the table, 1/256 at most 0.19%, for ~15k gas; the rest is the fee floor)
    uint256 internal constant REL_PRECISION = 256;

    struct Curve {
        bool outIs0; // outcome token is currency0
        bool mint; // true: outcome sold exact-in; false: outcome bought exact-out
        uint24 fee; // swap fee in pips
        uint160 limit; // last sqrt price the trade may reach (validator bound, inclusive)
        uint256 count; // segments
        uint160[] edge; // segment i runs from edge[i] to edge[i + 1]
        uint128[] liq; // lowest liquidity in force inside segment i
        uint256[] cumOut; // outcome units (fee-free) moved up to edge[i]
        uint256[] cumPay; // payment units (fee-free) moved up to edge[i]
        uint256[] cumMerged; // merged boundaries (mergedAt entries) before edge[i]
        uint160[] mergedAt; // sqrt prices of the step boundaries merged into segments, in walk order
    }

    /// Where walking further cannot pay: with the other pool at its current price (it only gets worse as the
    /// rebalance trades it), a unit past this pool's boundary price would not be gainful. on = false: walk on.
    struct Stop {
        bool on;
        uint256 otherPrice; // WAD
        uint24 otherFee; // pips
        uint256 hookFee;
        uint256 scale;
    }

    /// @notice Payment token per whole outcome token, WAD. scale = 10**(outcomeDecimals - paymentDecimals).
    function priceWad(uint160 s, bool outIs0, uint256 scale) internal pure returns (uint256) {
        if (outIs0) return FullMath.mulDiv(FullMath.mulDiv(s, s, Q96), scale * WAD, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(Q96, Q96, s), scale * WAD, s);
    }

    /// @notice Reads the pool from the current price toward `limit` the way Pool.swap steps (initialized ticks and
    /// bitmap-word ends), for at most MAX_WALK boundaries. A new segment starts only at an initialized tick whose
    /// liquidityNet is not dust; word ends and dust ticks are merged into the open segment, which then carries the
    /// lowest liquidity seen in it (never more than the pool really has there) and the merged boundaries.
    /// The walk ends at `limit`, at the first boundary past which `stop` says nothing pays, or at MAX_WALK (the
    /// trade never goes past the last boundary read).
    function build(
        IPoolManager pm,
        PoolId id,
        int24 spacing,
        bool outIs0,
        bool mint,
        uint24 fee,
        uint160 limit,
        Stop memory stop
    ) internal view returns (Curve memory c) {
        c.outIs0 = outIs0;
        c.mint = mint;
        c.fee = fee;
        c.limit = limit;
        c.edge = new uint160[](MAX_WALK + 1);
        c.liq = new uint128[](MAX_WALK);
        c.cumOut = new uint256[](MAX_WALK + 1);
        c.cumPay = new uint256[](MAX_WALK + 1);
        c.cumMerged = new uint256[](MAX_WALK + 1);
        c.mergedAt = new uint160[](MAX_WALK);
        bool down = mint == outIs0; // zeroForOne
        (uint160 s, int24 tick,,) = pm.getSlot0(id);
        c.edge[0] = s;
        if (s == 0 || (down ? s <= limit : s >= limit)) return c;
        uint128 liq = pm.getLiquidity(id);
        uint128 segLiq = liq; // lowest liquidity in the open segment
        uint256 merged; // boundaries merged so far (all segments)
        uint160 at = s; // last boundary reached
        for (uint256 w; w < MAX_WALK; ++w) {
            (int24 next, bool initialized) = _nextInitialized(pm, id, tick, spacing, down);
            at = _target(next, limit, down);
            if (at == limit || (stop.on && !_pays(c, stop, at))) {
                _push(c, segLiq, at, merged);
                return c;
            }
            if (initialized) {
                (, int128 net) = pm.getTickLiquidity(id, next);
                uint128 after_ = LiquidityMath.addDelta(liq, down ? -net : net);
                if (_isDust(net, liq)) {
                    if (after_ < segLiq) segLiq = after_;
                    c.mergedAt[merged++] = at;
                } else {
                    _push(c, segLiq, at, merged);
                    segLiq = after_;
                }
                liq = after_;
            } else {
                c.mergedAt[merged++] = at; // a word end: Pool.swap ends a step here, liquidity unchanged
            }
            tick = down ? next - 1 : next;
        }
        // walk cap reached: the open segment ends at the last boundary read
        if (at != c.edge[c.count]) _push(c, segLiq, at, merged);
    }

    /// @notice Largest n the walked range can absorb (validator bound or MAX_WALK boundaries).
    function capacity(Curve memory c) internal pure returns (uint256) {
        uint256 out = c.cumOut[c.count];
        return c.mint ? out * PIPS / (PIPS - c.fee) : out;
    }

    /// @notice Segment and sqrt price after trading n outcome units; ok = false past the walked range.
    function walk(Curve memory c, uint256 n) internal pure returns (bool ok, uint256 seg, uint160 s) {
        uint256 amt = c.mint ? n * (PIPS - c.fee) / PIPS : n;
        if (c.count == 0 || amt > c.cumOut[c.count]) return (false, c.count, c.edge[c.count]);
        // first segment i with amt <= cumOut[i + 1] (cumOut is non-decreasing): binary search
        uint256 lo;
        uint256 hi = c.count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (amt <= c.cumOut[mid + 1]) hi = mid;
            else lo = mid + 1;
        }
        return (true, lo, _within(c, lo, amt - c.cumOut[lo]));
    }

    /// @notice Fee-free payment amount for trading n outcome units (n must be within capacity), made conservative
    /// by ROUND_PER_STEP for every step boundary the trade crosses (merged boundaries and segment edges): a sale
    /// gets less, a purchase costs more. Pool.swap rounds the LP fee up at every step while the model rounds it
    /// once, so without the edges a burn across many initialized ticks could pass the model and revert after its
    /// purchases.
    function payFor(Curve memory c, uint256 n) internal pure returns (bool ok, uint256 pay) {
        (bool w, uint256 i, uint160 s) = walk(c, n);
        if (!w) return (false, 0);
        (, uint256 p) = _amounts(c.outIs0, c.mint, c.edge[i], s, c.liq[i]);
        pay = c.cumPay[i] + p;
        // merged boundaries the trade reaches: all before segment i, and those in it up to s
        uint256 k = c.cumMerged[i];
        bool down = c.mint == c.outIs0;
        while (k < c.cumMerged[i + 1] && (down ? c.mergedAt[k] >= s : c.mergedAt[k] <= s)) ++k;
        // plus the i segment edges crossed (edge[1..i])
        uint256 slack = (k + i) * ROUND_PER_STEP;
        if (!c.mint) return (true, pay + slack);
        return (true, pay > slack ? pay - slack : 0);
    }

    /// @notice True while one more unit at size x still pays: marginal revenue > 1 (mint) or cost < 1 (burn).
    function favorable(Curve memory y, Curve memory no, uint256 x, uint256 scale, uint256 hookFee)
        internal
        pure
        returns (bool)
    {
        uint256 n = x * scale;
        (bool okY,, uint160 sY) = walk(y, n);
        if (!okY) return false;
        (bool okN,, uint160 sN) = walk(no, n);
        if (!okN) return false;
        return gainful(priceWad(sY, y.outIs0, scale), priceWad(sN, no.outIs0, scale), y.fee, no.fee, hookFee, y.mint);
    }

    /// @notice True if one more unit at YES price pY and NO price pN (WAD) pays after LP fees (pips) and the hook fee.
    function gainful(uint256 pY, uint256 pN, uint24 feeY, uint24 feeN, uint256 hookFee, bool mint)
        internal
        pure
        returns (bool)
    {
        if (mint) {
            uint256 net = pY * (PIPS - feeY) / PIPS + pN * (PIPS - feeN) / PIPS;
            return net * (HOOK_FEE_DENOMINATOR - hookFee) / HOOK_FEE_DENOMINATOR > WAD;
        }
        uint256 cost = pY * PIPS / (PIPS - feeY) + pN * PIPS / (PIPS - feeN);
        return cost * (HOOK_FEE_DENOMINATOR + hookFee) / HOOK_FEE_DENOMINATOR < WAD;
    }

    /// @notice Largest x in [0, hi] at which the trade is still favorable.
    function size(Curve memory y, Curve memory no, uint256 hi, uint256 scale, uint256 hookFee)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = capacity(y) < capacity(no) ? capacity(y) : capacity(no);
        if (cap / scale < hi) hi = cap / scale;
        if (hi == 0 || !favorable(y, no, 1, scale, hookFee)) return 0;
        if (favorable(y, no, hi, scale, hookFee)) return hi;
        uint256 lo = 1;
        for (uint256 i; i < MAX_STEPS && hi - lo > 1 && (hi - lo) * REL_PRECISION > hi; ++i) {
            uint256 mid = (lo + hi) / 2;
            if (favorable(y, no, mid, scale, hookFee)) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// @notice Model profit in payment-token units (negative = loss) at size x, after LP and hook fees.
    /// A pre-check only; the executed profit is measured from the swap deltas.
    function estimateProfit(Curve memory y, Curve memory no, uint256 x, uint256 scale, uint256 hookFee)
        internal
        pure
        returns (int256)
    {
        uint256 n = x * scale;
        (bool okY, uint256 payY) = payFor(y, n);
        (bool okN, uint256 payN) = payFor(no, n);
        if (!okY || !okN) return type(int256).min;
        if (y.mint) {
            uint256 out = (payY + payN) * (HOOK_FEE_DENOMINATOR - hookFee) / HOOK_FEE_DENOMINATOR;
            return int256(out) - int256(x);
        }
        uint256 inY = FullMath.mulDivRoundingUp(payY, PIPS, PIPS - y.fee);
        uint256 inN = FullMath.mulDivRoundingUp(payN, PIPS, PIPS - no.fee);
        uint256 cost = FullMath.mulDivRoundingUp(inY + inN, HOOK_FEE_DENOMINATOR + hookFee, HOOK_FEE_DENOMINATOR);
        return int256(x) - int256(cost);
    }

    function _target(int24 next, uint160 limit, bool down) private pure returns (uint160) {
        if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
        uint160 sNext = TickMath.getSqrtPriceAtTick(next);
        if (down) return sNext < limit ? limit : sNext;
        return sNext > limit ? limit : sNext;
    }

    /// closes segment c.count at `target` with liquidity `liq`; `merged` = merged boundaries so far
    function _push(Curve memory c, uint128 liq, uint160 target, uint256 merged) private pure {
        uint256 i = c.count;
        (uint256 o, uint256 p) = _amounts(c.outIs0, c.mint, c.edge[i], target, liq);
        c.liq[i] = liq;
        c.edge[i + 1] = target;
        c.cumOut[i + 1] = c.cumOut[i] + o;
        c.cumPay[i + 1] = c.cumPay[i] + p;
        c.cumMerged[i + 1] = merged;
        c.count = i + 1;
    }

    /// one more unit with this pool at sqrt price s and the other at its current price still pays
    function _pays(Curve memory c, Stop memory stop, uint160 s) private pure returns (bool) {
        uint256 p = priceWad(s, c.outIs0, stop.scale);
        return gainful(p, stop.otherPrice, c.fee, stop.otherFee, stop.hookFee, c.mint);
    }

    /// |net| is at most liq / DUST_DIVISOR (with liq = 0 only net = 0 is dust)
    function _isDust(int128 net, uint128 liq) private pure returns (bool) {
        uint256 a = net < 0 ? uint256(-int256(net)) : uint256(int256(net));
        return a * DUST_DIVISOR <= liq;
    }

    /// outcome and payment amounts (fee-free) moved between sqrt prices a and b at liquidity liq
    function _amounts(bool outIs0, bool mint, uint160 a, uint160 b, uint128 liq)
        private
        pure
        returns (uint256 outcome, uint256 pay)
    {
        if (liq == 0 || a == b) return (0, 0);
        if (outIs0) {
            outcome = SqrtPriceMath.getAmount0Delta(a, b, liq, mint);
            pay = SqrtPriceMath.getAmount1Delta(a, b, liq, !mint);
        } else {
            outcome = SqrtPriceMath.getAmount1Delta(a, b, liq, mint);
            pay = SqrtPriceMath.getAmount0Delta(a, b, liq, !mint);
        }
    }

    /// sqrt price after moving `amt` outcome units inside segment i (constant liquidity), clamped to its end
    function _within(Curve memory c, uint256 i, uint256 amt) private pure returns (uint160) {
        uint160 a = c.edge[i];
        uint160 end = c.edge[i + 1];
        uint128 liq = c.liq[i];
        if (amt == 0 || liq == 0) return a;
        uint256 next;
        bool zeroForOne = c.mint == c.outIs0;
        if (c.mint) next = SqrtPriceMath.getNextSqrtPriceFromInput(a, liq, amt, zeroForOne);
        else next = SqrtPriceMath.getNextSqrtPriceFromOutput(a, liq, amt, zeroForOne);
        if (zeroForOne ? next < end : next > end) return end;
        return uint160(next);
    }

    /// TickBitmap.nextInitializedTickWithinOneWord over the PoolManager's storage
    function _nextInitialized(IPoolManager pm, PoolId id, int24 tick, int24 spacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, spacing);
            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = pm.getTickBitmap(id, wordPos) & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                    : (compressed - int24(uint24(bitPos))) * spacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = pm.getTickBitmap(id, wordPos) & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * spacing;
            }
        }
    }
}
